require 'octokit'
require 'faraday-http-cache'
require 'set'
require 'time'
require 'tmpdir'

module MatrixReleasetracker::Backends
  class Github < MatrixReleasetracker::Backend
    STAR_EXPIRY = 1 * 24 * 60 * 60
    RELEASE_EXPIRY = 1 * 60 * 60
    TAGS_RELEASE_EXPIRY = 2 * 60 * 60
    NIL_RELEASE_EXPIRY = 1 * 24 * 60 * 60
    REPODATA_EXPIRY = 2 * 24 * 60 * 60

    InternalRelease = Struct.new(:sha, :tag_name, :name, :date, :url, :description, :type)

    def name
      'GitHub'
    end

    def rate_limit
      limit = client.rate_limit

      Structs::RateLimit.new(self, 'REST', limit.limit, limit.remaining, limit.resets_at, limit.resets_in)
    end

    def rate_limits
      rest_limit = client.rate_limit
      graphql = <<~GQL
        query {
          rateLimit { limit remaining resetAt }
        }
      GQL

      result = gql_client.post '/graphql', { query: graphql }.to_json
      graphql_limit = result.data.rateLimit

      [
        Structs::RateLimit.new(self, 'REST', rest_limit.limit, rest_limit.remaining, rest_limit.resets_at, rest_limit.resets_in),
        Structs::RateLimit.new(self, 'GraphQL', graphql_limit.limit, graphql_limit.remaining, Time.parse(graphql_limit.resetAt), Time.parse(graphql_limit.resetAt) - Time.now)
      ]
    end

    def all_stars(data = {})
      raise NotImplementedException

      users.each do |u|
        stars(u, data).each do |repo|
          # refresh_repo(repo)
        end
      end
    end

    def stars(user_name, data = {})
      user_name = user_name.name unless user_name.is_a? String

      db = find_tracking(user_name, type: 'user')
      raise 'Unknown user' unless db

      user = db.first
      if user.nil? || (user[:next_update] || Time.new(0)) < Time.now
        refresh_user(user_name)
        user = db.first
      end

      raise 'Failed to discover user' if user.nil?

      user_id = user[:id]

      tracked = database[:repositories].where(id: database[:tracked_repositories].where(tracking_id: user_id).select(:repositories_id)).map { |repo| repo[:slug] }

      if tracked.empty? || (user[:next_update] || Time.new(0)) < Time.now
        logger.debug "Timeout reached on `stars`, refreshing data for user #{user} (#{user_id})."
        current = tracked.to_a
        tracked = paginate { client.starred(user, data) }.map(&:full_name)

        to_add = (tracked - current)
        to_add = to_add.map do |repo_name|
          if repo_name.nil?
            logger.debug "Discovered null repo in stars refresh for #{user} as part of adding #{to_add.count} repositories"
            next
          end

          repo = find_repository(repo_name).select(:id, :slug)
          refresh_repo(repo_name) if repo.empty?

          repo = repo.first

          logger.debug "Adding tracking of repo #{repo[:slug]} (#{repo[:id]}) to user #{user}"
          repo[:id]
        end.compact
        to_remove = (current - tracked)
        to_remove = to_remove.map do |repo_name|
          if repo_name.nil?
            logger.debug "Discovered null repo in stars refresh for #{user} as part of removing #{to_remove.count} repositories"
            next
          end

          repo = find_repository(repo_name).select(:id, :slug)
          refresh_repo(repo_name) if repo.empty?

          repo = repo.first

          logger.debug "Removing tracking of repo #{repo[:slug]} (#{repo[:id]}) for user #{user}"
          repo[:id]
        end.compact

        database.adapter.transaction do
          to_add.each { |rid| database[:tracked_repositories].insert_conflict(:ignore).insert(tracking_id: user_id, repositories_id: rid) }
          to_remove.each { |rid| database[:tracked_repositories].where(tracking_id: user_id, repositories_id: rid).delete() }

          db.update(
            extradata: { }.to_json,
            last_update: Time.now,
            next_update: Time.now + with_stagger(STAR_EXPIRY)
          )
        end

        return tracked
      end

      tracked = database[:repositories].where(id: database[:tracked_repositories].where(tracking_id: user_id).select(:repositories_id)).select(:slug).map { |repo| repo[:slug] }
    end

    def refresh_repo(repo, data = {})
      repo = client.repository(repo, data) if repo.is_a? String

      logger.debug "Refreshed metadata for repository #{repo.full_name}"

      db = find_repository(repo.full_name).select(:id)
      if db.empty?
        db.insert(
          slug: repo.full_name,
          backend: db_type,

          name: repo.name,
          url: repo.html_url,
          avatar: repo.avatar_url || repo.owner.avatar_url,
          last_metadata_update: Time.now,
          next_metadata_update: Time.now + with_stagger(REPODATA_EXPIRY)
        )
      else
        db.update(
          name: repo.name,
          url: repo.html_url,
          avatar: repo.avatar_url || repo.owner.avatar_url,
          last_metadata_update: Time.now,
          next_metadata_update: Time.now + with_stagger(REPODATA_EXPIRY)
        )
      end

      true
    end

    def refresh_user(user)
      # logger.debug "Refreshing metadata for user #{user}"

      true
    end

    def latest_release(repo_name, data = {})
      repo_name = repo_name.full_name unless repo_name.is_a? String

      db = find_repository(repo_name)
      repo = db.select(:id, :slug, :next_metadata_update, :next_update, :extradata).first
      if repo.nil? || (repo[:next_metadata_update] || Time.new(0)) < Time.now
        refresh_repo(repo_name, data)

        raise 'Failed to find repo data' if db.empty?
      end

      repo = db.select(:id, :slug, :next_metadata_update, :next_update, :extradata).first if repo.nil?
      latest_db = find_releases(repositories_id: repo[:id]).order_by(Sequel.desc(:publish_date))

      if (repo[:next_update] || Time.new(0)) > Time.now
        return latest_db.first
      end

      logger.debug "Checking latest release for #{repo_name}"

      extradata = JSON.parse(repo[:extradata] || '{}')
      allow = extradata.fetch('allow', nil)
      unless allow
        allow = [:lightweight_tag, :tag, :release]
        extradata['allow'] = allow 
      end

      if gql_available?
        latest = find_gql_releases(repo[:slug]).select { |r| allow.include? r[:type] }.last
      elsif allow.include? :release
        latest = find_rest_releases(repo[:slug]).last
      end

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
        next_update: Time.now + with_stagger(latest ? RELEASE_EXPIRY : NIL_RELEASE_EXPIRY)
      )

      latest_db.first
    rescue Octokit::NotFound
      nil
    end

    def find_gql_releases(repo)
      graphql = <<~GQL
        query {
          repository(owner:"#{repo.split('/').first}", name:"#{repo.split('/').last}") {

            releases(first: 5, orderBy: { field: CREATED_AT, direction: DESC }) {
              nodes {
                tagName
                tag {
                  target {
                    oid
                  }
                }
                name
                createdAt
                url
                description
                isPrerelease
              }
            }

            refs(first: 5, refPrefix: "refs/tags/", orderBy: { field: TAG_COMMIT_DATE, direction: DESC }) {
              nodes {
                name
                target {
                  __typename
                  oid
                  ... on Commit {
                    committedDate
                    pushedDate
                    message
                  }
                  ... on Tag {
                    tagger {
                      date
                    }
                    message
                  }
                }
              }
            }
          }
        }
      GQL

      result = gql_client.post '/graphql', { query: graphql }.to_json

      releases = result.data.repository.releases.nodes.map do |release|
        type = release.isPrerelease ? :prerelease : :release
        InternalRelease.new(release.tag&.target&.oid, release.tagName, release.name, Time.parse(release.createdAt), release.url, release.description, type)
      end.group_by(&:tag_name)

      result.data.repository.refs.nodes.each do |tag|
        next if releases.key? tag.name

        if tag.target.__typename == 'Commit'
          time = Time.parse(tag.target.pushedDate || tag.target.committedDate)
          type = :lightweight_tag
        else
          time = tag.target.tagger.date
          type = :tag
        end

        # TODO Check the GraphQL API more thoroughly, if this really can't be retrieved instead of calculated
        url = "https://github.com/#{repo}/releases/tag/#{tag.name}"
        releases[tag.name] = InternalRelease.new(tag.target&.oid, tag.name, tag.name, time, url, tag.target.message, type)
      end

      releases.values
              .map { |v| v.is_a?(Array) ? v.first : v }
              .sort { |a, b| a.date <=> b.date }
              .map do |rel|
        {
          sha: rel.sha,
          name: rel.name,
          tag_name: rel.tag_name,
          published_at: rel.date,
          html_url: rel.url,
          body: rel.description,
          type: rel.type.to_s.to_sym
        }
      end
    end

    def find_rest_releases(repo)
      releases = per_page(5) { client.releases(repo) }.reject { |r| r.published_at.nil? }

      releases.sort { |a, b| a.published_at <=> b.published_at }
              .map do |rel|
        {
          name: rel.name,
          tag_name: rel.tag_name,
          published_at: rel.published_at,
          html_url: rel.html_url,
          body: rel.body,
          type: :release
        }
      end
    end

    def last_releases(tracked)
      # TODO: Support the other tracking types
      last_user_releases(tracked)
    end

    def last_user_releases(user)
      update_data = lambda do |stars|
        data = { headers: {} }
        ret = {}

        stars.each do |star|
          latest = latest_release(star, data)
          next if latest.nil?

          repo = find_repository(star).select(:id, :slug, :name, :url, :avatar).first
          ret[star] = [latest].compact.map do |rel|
            MatrixReleasetracker::Release.new.tap do |store|
              store.repositories_id = repo[:id]
              store.release_id = latest[:id]

              store.namespace = repo[:slug].split('/')[0..-2].join '/'
              store.name = repo[:name]
              store.repo_url = repo[:url]
              store.avatar_url = repo[:avatar] ? repo[:avatar] + '&s=32' : 'https://avatars1.githubusercontent.com/u/9919?s=32'

              store.version = rel[:version]
              store.version_name = rel[:name]
              store.commit_sha = rel[:commit_sha]
              store.publish_date = rel[:publish_date]
              store.release_notes = rel[:release_notes]
              store.release_url = rel[:url]
              store.release_type = rel[:type]
            end
          end.first
        end

        ret
      end

      thread_count = config[:threads] || 1
      user_stars = stars(user)

      ret = if thread_count > 1
              per_batch = (user_stars.count / thread_count).to_i
              per_batch = user_stars.count if per_batch.zero?
              threads = []
              user_stars.each_slice(per_batch) do |stars|
                threads << Thread.new { update_data.call(stars) }
              end

              { releases: threads.map(&:value).reduce({}, :merge) }
            else
              { releases: update_data.call(user_stars) }
            end

      ret[:last_check] = config[:last_check] if config.key? :last_check
      #config[:last_check] = Time.now

      ret
    end

    private

    def paginate(&_block)
      client.auto_paginate = true

      yield
    ensure
      client.auto_paginate = false
    end

    def per_page(count, &_block)
      client.auto_paginate = false
      opp = client.per_page
      client.per_page = count

      yield
    ensure
      client.per_page = opp
    end

    def gql_available?
      gql_client
      true
    rescue ArgumentError
      false
    end

    def gql_client
      @gql_client ||= use_stack(if config.key?(:access_token)
                                  logger.debug "GQL: Using access token"
                                  Octokit::Client.new access_token: config[:access_token]
                                elsif config.key?(:login) && config.key?(:password)
                                  logger.debug "GQL: Using login"
                                  Octokit::Client.new login: config[:login], password: config[:password]
                                else
                                  raise ArgumentError, 'GraphQL access on the GitHub API requires account access'
                                end)
    end

    def client
      @client ||= use_stack(if config.key?(:client_id) && config.key?(:client_secret)
                              logger.debug "REST: Using OAuth"
                              Octokit::Client.new client_id: config[:client_id], client_secret: config[:client_secret]
                            elsif config.key?(:access_token)
                              logger.debug "REST: Using access token"
                              Octokit::Client.new access_token: config[:access_token]
                            elsif config.key?(:login) && config.key?(:password)
                              logger.debug "REST: Using login"
                              Octokit::Client.new login: config[:login], password: config[:password]
                            else
                              logger.debug "REST: Using no authorization"
                              Octokit::Client.new
                            end)
    end

    def use_stack(client)
      stack = Faraday::RackBuilder.new do |build|
        build.use Faraday::HttpCache, serializer: Marshal, shared_cache: false
        build.use Octokit::Response::RaiseError
        build.adapter Faraday.default_adapter
      end
      client.middleware = stack
      client
    end
  end
end
