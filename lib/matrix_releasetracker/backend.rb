# frozen_string_literal: true

require 'pp'

module MatrixReleasetracker
  class Backend
    class Error < MatrixReleasetracker::Error; end

    include PP::ObjectMixin

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
        Structs::Tracking.new_from_state(**t.merge(backend: self))
      end
    end

    def tracking?(id: nil, object: nil, type: nil)
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

      { releases: rel.compact }
    rescue NotImplementedError
      logger.error "Tried to read tracking information for #{tracked.type}, which is not implemented, ignoring."
      { releases: [] }
    end

    def pretty_print_instance_variables
      instance_variables.sort.reject { |n| %i[@config].include? n }
    end

    def pretty_print(pp)
      pp.pp_object(self)
    end

    alias inspect pretty_print_inspect

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
    def find_group_repositories(group_name, **params)
      raise NotImplementedError
    end

    def find_user_repositories(group_name, **params)
      raise NotImplementedError
    end

    def find_repo_information(repo_name, **params)
      raise NotImplementedError
    end

    def find_repo_releases(repo, **params)
      raise NotImplementedError
    end

    #
    # Utility methods
    #
    def with_stagger(value, randomness = 0.5)
      value + ((Random.rand - 0.5) * value * randomness)
    end

    def find_repository(name, **filters)
      database[:repositories].where(filters.merge(slug: name, backend: db_type))
    end

    def find_repository_by_id(id, **filters)
      database[:repositories].where(filters.merge(id: id, backend: db_type))
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
      repo_name = repo&.[](:slug) || tracking.object

      params = tracking.extradata || {}
      params[:__tracking] = tracking
      grab_repository(repo_name, **params)
    end

    def last_user_releases(user)
      grab_all_repositories(user)
    end

    #
    # Release helpers
    #
    def grab_repository_info(repo_name, **params)
      db = find_repository(repo_name)

      info = find_repo_information(repo_name, **params)
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
    end

    def grab_repository_releases(repo, **params)
      db = find_repository_by_id repo[:id]

      expiry = NIL_RELEASE_EXPIRY
      find_repo_releases(repo, **params).each do |latest|
        logger.debug "For #{latest.inspect}"
        next if latest.empty?

        expiry = TAGS_RELEASE_EXPIRY if expiry == NIL_RELEASE_EXPIRY
        expiry = RELEASE_EXPIRY if latest[:type] == :release && expiry != RELEASE_EXPIRY

        database[:releases].insert_conflict.insert(
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
        next_update: Time.now + with_stagger(expiry)
      )
    end

    def grab_repository(repo_name, **params)
      tracking = params.delete :__tracking
      db = find_repository(repo_name)

      repo = db.first
      if repo.nil? || (repo[:next_metadata_update] || Time.new(0)) < Time.now
        logger.debug "Timeout reached for repository #{repo_name} metadata, updating..."

        grab_repository_info(repo_name, **params)

        repo = db.first
      end

      raise "Unable to discover repository #{repo_name}" if repo.nil?

      if (repo[:next_update] || Time.new(0)) < Time.now
        logger.debug "Timeout reached for repository #{repo[:slug]} releases, updating..."

        grab_repository_releases(repo, **params)

        repo = db.first
      end

      latest_db = find_releases(repositories_id: repo[:id]).order_by(Sequel.desc(:publish_date))
      latest = latest_db.first
      return if latest.nil?

      MatrixReleasetracker::Release.new(
        for_tracked: tracking,

        repositories_id: repo[:id],
        release_id: latest[:id],

        namespace: repo[:namespace] || repo[:slug].split('/')[0..-2].join('/'),
        name: repo[:name],
        repo_url: repo[:url],
        avatar_url: repo[:avatar],

        version: latest[:version],
        version_name: latest[:name],
        commit_sha: latest[:commit_sha],
        publish_date: latest[:publish_date],
        release_notes: latest[:release_notes],
        release_url: latest[:url],
        release_type: latest[:type]
      )
    end

    def grab_all_repositories(tracking)
      params = tracking.extradata || {}
      params[:__tracking] = tracking

      update_data = lambda do |repos|
        ret = {}

        repos.each do |repo|
          latest = grab_repository(repo[:slug], **params)
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

      params = JSON.parse(group[:extradata] || '{}', symbolize_names: true)
      to_track = find_group_repositories(group_name, **params)
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

      params = JSON.parse(user[:extradata] || '{}', symbolize_names: true)
      to_track = find_user_repositories(user_name, **params)
      return if to_track.nil?

      update_tracking_repositories(user, to_track)
      true
    end

    def update_tracking_repositories(tracking, to_track)
      params = JSON.parse(tracking[:extradata] || '{}', symbolize_names: true)

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
        grab_repository_info(repo_name, **params) if repo.empty?

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
        grab_repository_info(repo_name, **params) if repo.empty?

        repo = repo.first

        logger.debug "Removing tracking of repo #{repo[:slug]} (#{repo[:id]}) for #{tracking}"
        repo[:id]
      end.compact

      database.adapter.transaction do
        to_add.each { |rid| database[:tracked_repositories].insert_conflict.insert(tracking_id: tracking[:id], repositories_id: rid) }
        to_remove.each { |rid| database[:tracked_repositories].where(tracking_id: tracking[:id], repositories_id: rid).delete }

        db = database[:tracking].where(id: tracking[:id], backend: db_type)
        db.update(
          last_update: Time.now,
          next_update: Time.now + with_stagger(STAR_EXPIRY)
        )
      end
    end
  end
end
