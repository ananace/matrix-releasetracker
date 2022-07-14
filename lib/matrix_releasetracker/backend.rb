module MatrixReleasetracker
  class Backend
    def initialize(config)
      @config = config
    end

    #
    # Backend information
    #
    def rate_limit; end

    def rate_limits
      [rate_limit].compact
    end

    def name
      self.class.name.split(':').last
    end

    #
    # Tracking information
    #
    def tracking
      @tracking ||= database[:tracking].where(backend: db_type).map do |t|
        Structs::Tracking.new_from_state t.merge(backend: self)
      end
    end

    def is_tracking?(id: nil, object: nil, type: nil)
      if id
        database[:tracking].where(id: id, backend: db_type).any?
      else
        raise ArgumentError, "missing keywords: #{(%i[object type] - { object: object, type: type }.compact.keys).join ', '}" if object.nil? || type.nil?

        database[:tracking].where(object: object.to_s, type: type.to_s, backend: db_type).any?
      end
    end

    def get_tracking(object:, type:, **attributes)
      attributes.delete :object
      attributes.delete :type
      attributes.delete :backend
      database[:tracking].where(object: object, type: type.to_s, backend: db_type, **attributes).first
    end

    def get_tracking_by_id(id)
      database[:tracking].where(id: id, backend: db_type).first
    end

    def add_tracking(type:, object:, **attributes)
      attributes.delete :id
      attributes.delete :object
      attributes.delete :type
      attributes.delete :backend

      logger.debug "Adding tracking information for #{attributes.merge(type: type, object: object)}"

      result = database[:tracking].insert(type: type.to_s, object: object.to_s, backend: db_type, **attributes)
      @tracking = nil

      result
    end

    def update_tracking(id: nil, type: nil, object: nil, **attributes)
      attributes.delete :id
      attributes.delete :object
      attributes.delete :type
      attributes.delete :backend

      logger.debug "Updating tracking information for #{attributes.merge(id: id, type: type, object: object).compact}"

      if id
        result = database[:tracking].where(id: id, backend: db_type).update(**attributes)
      else
        raise ArgumentError, "missing keywords: #{(%i[object type] - { object: object, type: type }.compact.keys).join ', '}" if object.nil? || type.nil?

        result = database[:tracking].where(object: object.to_s, type: type.to_s, backend: db_type).update(**attributes)
      end
      @tracking = nil

      result
    end

    def remove_tracking(id: nil, type: nil, object: nil)
      attributes = { id: id, type: type, object: object }
      logger.debug "Removing tracking information for #{attributes.compact}"

      if id
        result = database[:tracking].where(id: id, backend: db_type).delete
      else
        raise ArgumentError, "missing keywords: #{(%i[object type] - { object: object, type: type }.compact.keys).join ', '}" if object.nil? || type.nil?

        result = database[:tracking].where(object: object.to_s, type: type.to_s, backend: db_type).delete
      end
      @tracking = nil

      result
    end

    #
    # Extended tracking information
    #
    def get_all_repositories_for(tracking)
      raise ArgumentError, 'Not a tracked object' unless tracking.is_a? MatrixReleasetracker::Structs::Tracking
      raise ArgumentError, 'Tracked object is not attached to database' unless tracking.id

      database[:repositories].where(
        id: database[:tracked_repositories].where(
          tracking_id: tracking.id
        ).select(:repositories_id)
      ).map { |repo| repo[:slug] }
    end

    #
    # Main queries
    #
    def last_releases(tracked)
      raise 'Invalid tracked object' if tracked.backend != self

      if (tracked.next_update || Time.new(0)) < Time.now
        refresh_tracked(tracked)
        tracked.reload!
      end

      rel = case tracked
            when MatrixReleasetracker::Structs::Group
              last_group_releases(tracked)
            when MatrixReleasetracker::Structs::Repository
              [last_repo_release(tracked)]
            when MatrixReleasetracker::Structs::User
              last_user_releases(tracked)
            else
              raise "Unknown tracking type #{tracked.inspect}"
            end

      { releases: rel }
    end

    protected

    attr_reader :config

    def database
      config[:database]
    end

    def logger
      Logging.logger[self]
    end

    def db_type
      name.downcase
    end

    #
    # To be implemented by backends
    #
    def find_group_repositories(group_name)
      raise NotImplementedError
    end

    def find_user_repositories(group_name)
      raise NotImplementedError
    end

    def find_repo_information(repo_name)
      raise NotImplementedError
    end

    def find_repo_releases(repo)
      raise NotImplementedError
    end

    #
    # Utility methods
    #
    def with_stagger(value)
      value + (Random.rand - 0.5) * (value / 2.0)
    end

    def find_repository(name, **filters)
      database[:repositories].where(filters.merge(slug: name, backend: db_type))
    end

    def find_tracking(name, **filters)
      database[:tracking].where(filters.merge(object: name, backend: db_type))
    end

    def find_releases(**filters)
      database[:releases].where(filters)
    end

    private

    REPODATA_EXPIRY = 2 * 24 * 60 * 60
    STAR_EXPIRY = 1 * 24 * 60 * 60
    RELEASE_EXPIRY = 1 * 60 * 60
    TAGS_RELEASE_EXPIRY = 2 * 60 * 60
    NIL_RELEASE_EXPIRY = 1 * 24 * 60 * 60

    #
    # Main release queries
    #
    def last_group_releases(group)
      grab_all_repositories(group)
    end

    def last_repo_release(tracking)
      repo = database[:repositories].where(
        id: database[:tracked_repositories].where(
          tracking_id: tracking.id
        ).select(:repositories_id)
      ).first
      if repo.nil?
        repo_name = tracking.object
      else
        repo_name = repo[:slug]
      end

      grab_repository(repo_name)
    end

    def last_user_releases(user)
      grab_all_repositories(user)
    end

    #
    # Release helpers
    #
    def grab_repository(repo_name)
      db = find_repository(repo_name)

      repo = db.first
      if repo.nil? || (repo[:next_metadata_update] || Time.new(0)) < Time.now
        logger.debug "Timeout reached for repository #{repo_name} metadata, updating..."

        info = find_repo_information(repo_name)
        if db.empty?
          db.insert(
            slug: info[:full_name],
            backend: db_type,

            name: info[:name],
            namespace: info[:namespace],
            url: info[:html_url],
            avatar: info[:avatar_url],
            last_metadata_update: Time.now,
            next_metadata_update: Time.now + with_stagger(REPODATA_EXPIRY)
          )
        else
          db.update(
            name: info[:name],
            namespace: info[:namespace],
            url: info[:html_url],
            avatar: info[:avatar_url],
            last_metadata_update: Time.now,
            next_metadata_update: Time.now + with_stagger(REPODATA_EXPIRY)
          )
        end

        repo = db.first
      end

      raise "Unable to discover repository #{repo_name}" if repo.nil?

      if (repo[:next_update] || Time.new(0)) < Time.now
        logger.debug "Timeout reached for repository #{repo[:slug]} releases, updating..."

        latest = find_repo_releases(repo).last
        if latest
          database[:releases].insert_conflict(:ignore).insert(
            version: latest[:tag_name],
            repositories_id: repo[:id],

            name: latest[:name] || latest[:tag_name] || latest[:sha],
            commit_sha: latest[:sha],
            publish_date: latest[:published_at],
            release_notes: latest[:body] || '',
            url: latest[:html_url],
            type: latest[:type].to_s
          )
        end

        db.update(
          last_update: Time.now,
          next_update: Time.now + with_stagger(latest ? (%i[prerelease release].include?(latest[:type]) ? RELEASE_EXPIRY : TAGS_RELEASE_EXPIRY) : NIL_RELEASE_EXPIRY)
        )

        repo = db.first
      end

      latest_db = find_releases(repositories_id: repo[:id]).order_by(Sequel.desc(:publish_date))
      latest = latest_db.first
      return if latest.nil?

      MatrixReleasetracker::Release.new.tap do |store|
        store.repositories_id = repo[:id]
        store.release_id = latest[:id]

        store.namespace = repo[:namespace] || repo[:slug].split('/')[0..-2].join('/')
        store.name = repo[:name]
        store.repo_url = repo[:url]
        store.avatar_url = repo[:avatar]

        store.version = latest[:version]
        store.version_name = latest[:name]
        store.commit_sha = latest[:commit_sha]
        store.publish_date = latest[:publish_date]
        store.release_notes = latest[:release_notes]
        store.release_url = latest[:url]
        store.release_type = latest[:type]
      end
    end

    def grab_all_repositories(tracking)
      update_data = lambda do |repos|
        ret = {}

        repos.each do |repo|
          latest = grab_repository(repo[:slug])
          next if latest.nil?

          ret[repo] = latest
        end

        ret
      end

      thread_count = config[:threads] || 1
      repositories = database[:repositories].where(
        id: database[:tracked_repositories].where(
          tracking_id: tracking.id
        ).select(:repositories_id)
      ).all

      if thread_count > 1
        per_batch = (repositories.count / thread_count).to_i
        per_batch = repositories.count if per_batch.zero?
        threads = []
        repositores.each_slice(per_batch) do |stars|
          threads << Thread.new { update_data.call(stars) }
        end

        threads.map(&:value).reduce({}, :merge).values
      else
        update_data.call(repositories).values
      end
    end

    #
    # Repository discovery helpers
    #
    def refresh_tracked(tracked)
      case tracked
      when MatrixReleasetracker::Structs::Group
        refresh_group(tracked.object)
      when MatrixReleasetracker::Structs::Repository
        refresh_repo(tracked.object)
      when MatrixReleasetracker::Structs::User
        refresh_user(tracked.object)
      else
        raise "Unknown tracking type #{tracked.inspect}"
      end
    end

    def refresh_group(group_name)
      db = find_tracking(group_name, type: 'group')

      group = db.first
      raise "Missing tracking information for group #{group_name}" unless group
      return if (group[:next_update] || Time.new(0)) > Time.now

      logger.debug "Timeout reached for group #{group_name}, updating tracking information..."

      to_track = find_group_repositories(group_name)
      return if to_track.nil?

      update_tracking_repositories(group, to_track)
      true
    end

    def refresh_repo(repo_name)
      db = find_tracking(repo_name, type: 'repository')

      repo = db.first
      raise "Missing tracking information for repo #{repo_name}" unless repo
      return if (repo[:next_update] || Time.new(0)) > Time.now

      logger.debug "Timeout reached for repo #{repo_name}, updating tracking information..."

      update_tracking_repositories(repo, [repo_name])
      true
    end

    def refresh_user(user_name)
      db = find_tracking(user_name, type: 'user')

      user = db.first
      raise "Missing tracking information for user #{user_name}" unless user
      return if (user[:next_update] || Time.new(0)) > Time.now

      logger.debug "Timeout reached for user #{user_name}, updating tracking information..."

      to_track = find_user_repositories(user_name)
      return if to_track.nil?

      update_tracking_repositories(user, to_track)
      true
    end

    def update_tracking_repositories(tracking, to_track)
      currently_tracked = database[:repositories].where(
        id: database[:tracked_repositories].where(
          tracking_id: tracking[:id]
        ).select(:repositories_id)
      ).map { |repo| repo[:slug] }

      to_add = (to_track - currently_tracked).map do |repo_name|
        if repo_name.nil?
          logger.debug "Discovered null repo in refresh for #{tracking} as part of adding #{to_add.count} repositories"
          next
        end

        repo = find_repository(repo_name).select(:id, :slug)
        refresh_repo(repo_name) if repo.empty?

        repo = repo.first

        logger.debug "Adding tracking of repo #{repo[:slug]} (#{repo[:id]}) to #{tracking}"
        repo[:id]
      end.compact

      to_remove = (currently_tracked - to_track).map do |repo_name|
        if repo_name.nil?
          logger.debug "Discovered null repo in refresh for #{tracking} as part of removing #{to_remove.count} repositories"
          next
        end

        repo = find_repository(repo_name).select(:id, :slug)
        refresh_repo(repo_name) if repo.empty?

        repo = repo.first

        logger.debug "Removing tracking of repo #{repo[:slug]} (#{repo[:id]}) for #{tracking}"
        repo[:id]
      end.compact

      database.adapter.transaction do
        to_add.each { |rid| database[:tracked_repositories].insert_conflict(:ignore).insert(tracking_id: tracking[:id], repositories_id: rid) }
        to_remove.each { |rid| database[:tracked_repositories].where(tracking_id: tracking[:id], repositories_id: rid).delete() }

        db = database[:tracking].where(id: tracking[:id], backend: db_type)
        db.update(
          last_update: Time.now,
          next_update: Time.now + with_stagger(STAR_EXPIRY)
        )
      end
    end
  end
end
