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

    InternalRelease = Struct.new(:tag_name, :name, :date, :url, :description, :type)

    def post_load
      super

      return unless config.key? :tracked

      # Clean up old configuration junk
      config[:tracked][:users].each { |_k, u| %i[last_check next_check].each { |v| u.delete v } }
      config[:tracked][:users].delete_if { |_k, u| u.empty? }
      config[:tracked].delete :users if config[:tracked][:users].empty?

      config[:tracked][:repos].each { |_k, r| %i[latest next_data_sync next_check full_name name html_url avatar_url].each { |v| r.delete v } }
      config[:tracked][:repos].each { |_k, r| r.delete :allow if r[:allow].is_a? Symbol }
      config[:tracked][:repos].delete_if { |_k, r| r.empty? }
      config[:tracked].delete :repos if config[:tracked][:repos].empty?

      config.delete :tracked if config[:tracked].empty?
    end

    def post_update
      super

      # Remove empty repos from tracked config
      config[:tracked].delete :repos if config[:tracked][:repos].empty?
    end

    def name
      'GitHub'
    end

    def rate_limit
      limit = client.rate_limit

      RateLimit.new(self, limit.limit, limit.remaining, limit.resets_at, limit.resets_in)
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
        RateLimit.new(self, 'REST', rest_limit.limit, rest_limit.remaining, rest_limit.resets_at, rest_limit.resets_in),
        RateLimit.new(self, 'GraphQL', graphql_limit.limit, graphql_limit.remaining, Time.parse(graphql_limit.resetAt), Time.parse(graphql_limit.resetAt) - Time.now)
      ]
    end

    def all_stars(data = {})
      raise NotImplementedException
      users.each do |u|
        stars(u, data).each do |repo|
          # refresh_repo(repo)
        end
      end

      # persistent_repos.values
    end

    def stars(user, data = {})
      user = user.name unless user.is_a? String
      puser = persistent_user(user)
      euser = ephemeral_user(user)

      next_check = puser[:next_check]
      next_check = Time.parse(next_check.to_s) unless next_check.is_a? Time
      return puser[:repos] if puser[:repos] && (next_check || Time.new(0)) > Time.now
      logger.debug "Timeout (#{puser[:next_check]}) reached on `stars`, refreshing data for user #{user}."

      tracked = paginate { client.starred(user, data) }
      puser[:repos] = tracked.map(&:full_name)
      puser[:next_check] = Time.now + with_stagger(STAR_EXPIRY)

      puser[:repos]
    end

    def refresh_repo(repo, data = {})
      if repo.is_a? String
        prepo = persistent_repo(repo)
        erepo = ephemeral_repo(repo)
        repo = client.repository(repo, data)
      end

      logger.debug "Forced refresh of stored data for repository #{repo.full_name}"

      prepo ||= persistent_repo(repo.full_name)
      erepo ||= ephemeral_repo(repo.full_name)

      erepo.merge!(
        avatar_url: repo.owner.avatar_url,
        full_name: repo.full_name,
        name: repo.name,
        html_url: repo.html_url
      )
      erepo.merge!(
        next_data_sync: Time.now + with_stagger(REPODATA_EXPIRY)
      )

      true
    end

    def latest_release(repo, data = {})
      repo = repo.full_name unless repo.is_a? String
      prepo = persistent_repo(repo)
      erepo = ephemeral_repo(repo)

      logger.debug "Checking latest release for #{repo}"

      refresh_repo(repo, data) unless (erepo.keys & %i[full_name name html_url]).count == 3
      refresh_repo(repo, data) if (erepo[:next_data_sync] ||= Time.now) < Time.now

      return erepo[:latest] if (erepo[:next_check] || Time.new(0)) > Time.now
      logger.debug "Timeout (#{erepo[:next_check]}) reached on `latest_release`, refreshing data for repository #{repo}"

      erepo[:last_check] = Time.now
      erepo[:next_check] = Time.now + with_stagger(erepo[:latest] ? RELEASE_EXPIRY : NIL_RELEASE_EXPIRY)

      allow = prepo.fetch(:allow, nil)
      allow = [:lightweight_tag, :tag, :release] unless allow.is_a? Array

      if gql_available?
        erepo[:latest] = find_gql_releases(repo, prepo, erepo).select { |r| allow.include? r.type }.last
      elsif allow.include? :release
        erepo[:latest] = find_rest_releases(repo, prepo, erepo).last
      end
    rescue Octokit::NotFound
      nil
    end

    def find_gql_releases(repo, prepo, ereop)
      graphql = <<~GQL
        query {
          repository(owner:"#{repo.split('/').first}", name:"#{repo.split('/').last}") {

            releases(first: 5, orderBy: { field: CREATED_AT, direction: DESC }) {
              nodes {
                tagName
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
        InternalRelease.new(release.tagName, release.name, Time.parse(release.createdAt), release.url, release.description, type)
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
        releases[tag.name] = InternalRelease.new(tag.name, tag.name, time, url, tag.target.message, type)
      end

      releases = releases.values.sort { |a, b| a.date <=> b.date }
      releases.map do |rel|
        {
          name: rel.name,
          tag_name: rel.tag_name,
          published_at: rel.date,
          html_url: rel.url,
          body: rel.description,
          type: rel.type
        }
      end
    end

    def find_rest_releases(repo, prepo, erepo)
      releases = per_page(5) { client.releases(repo) }.reject { |r| r.published_at.nil? }

      releases.sort { |a, b| a.published_at <=> b.published_at }
      releases.map do |rel|
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

    def last_releases(user = config[:user])
      update_data = lambda do |stars|
        data = { headers: {} }
        ret = {}

        stars.each do |star|
          latest = latest_release(star, data)
          next if latest.nil?

          repo = ephemeral_repo(star)
          ret[star] = [latest].compact.map do |rel|
            MatrixReleasetracker::Release.new.tap do |store|
              store.namespace = repo[:full_name].split('/')[0..-2].join '/'
              store.name = repo[:name]
              store.version = rel[:tag_name]
              store.version_name = rel[:name]
              store.publish_date = rel[:published_at]
              store.release_notes = rel[:body]
              store.repo_url = repo[:html_url]
              store.release_url = rel[:html_url]
              store.avatar_url = repo[:avatar_url] ? repo[:avatar_url] + '&s=32' : 'https://avatars1.githubusercontent.com/u/9919?s=32&v=4'
              store.release_type = rel[:type]
            end
          end.first
        end

        ret
      end

      thread_count = config[:threads] || 1
      user_stars = stars(user)
      repo_information = user_stars.map do |repo|
        erepo = ephemeral_repo(repo)
        {
          repo: repo,
          last_check: erepo[:last_check],
          next_check: erepo[:next_check],
          has_release: !erepo[:latest].nil?,
          uses_tags: erepo[:allow] == :tags
        }
      end
      repo_information.sort_by! { |r| r[:last_check] || Time.new(0) }

      ret = if thread_count > 1
              per_batch = user_stars.count / thread_count
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
      config[:last_check] = Time.now

      ret
    end

    private

    def with_stagger(value)
      value + (Random.rand - 0.5) * (value / 2.0)
    end

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
                                  Octokit::Client.new access_token: config[:access_token]
                                elsif config.key?(:login) && config.key?(:password)
                                  Octokit::Client.new login: config[:login], password: config[:password]
                                else
                                  raise ArgumentError, 'GraphQL access on the GitHub API requires account access'
                                end)
    end

    def client
      @client ||= use_stack(if config.key?(:client_id) && config.key?(:client_secret)
                              Octokit::Client.new client_id: config[:client_id], client_secret: config[:client_secret]
                            elsif config.key?(:access_token)
                              Octokit::Client.new access_token: config[:access_token]
                            elsif config.key?(:login) && config.key?(:password)
                              Octokit::Client.new login: config[:login], password: config[:password]
                            else
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
