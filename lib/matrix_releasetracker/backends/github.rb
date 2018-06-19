require 'octokit'
require 'faraday-http-cache'
require 'set'

module MatrixReleasetracker::Backends
  class Github < MatrixReleasetracker::Backend
    STAR_EXPIRY = 1 * 24 * 60 * 60
    RELEASE_EXPIRY = 1 * 60 * 60
    NIL_RELEASE_EXPIRY = 1 * 24 * 60 * 60
    REPODATA_EXPIRY = 2 * 24 * 60 * 60

    def logger
      Logging.logger[self.class.name]
    end

    def name
      'GitHub'
    end

    def rate_limit
      limit = client.rate_limit

      Struct.new(:backend, :requests, :remaining, :resets_at, :resets_in) do
        def near_limit
          remaining <= requests * 0.05
        end
      end.new(self, limit.limit, limit.remaining, limit.resets_at, limit.resets_in)
    end

    def all_stars(data = {})
      users.each do |u|
        stars(u, data).each do |repo|
          # refresh_repo(repo)
        end
      end

      tracked_repos.values
    end

    def stars(user, data = {})
      user = user.name unless user.is_a? String
      tuser = tracked_user(user)

      return tuser[:repos] if (tuser[:next_check] || Time.new(0)) > Time.now
      logger.debug "Timeout (#{tuser[:next_check]}) reached on `stars`, refreshing data for user #{user}."

      tracked = paginate { client.starred(user, data) }
      tuser[:repos] = tracked.map(&:full_name)
      tuser[:next_check] = Time.now + with_stagger(STAR_EXPIRY)

      tuser[:repos]
    end

    def refresh_repo(repo, data = {})
      if repo.is_a? String
        trepo = tracked_repo(repo)
        repo = client.repository(repo, data)
      end

      logger.debug "Forced refresh of stored data for repository #{repo.full_name}"

      trepo ||= tracked_repo(repo.full_name)

      trepo.merge!(
        avatar_url: repo.owner.avatar_url,
        full_name: repo.full_name,
        name: repo.name,
        html_url: repo.html_url,
        next_data_sync: Time.now + with_stagger(REPODATA_EXPIRY)
      )

      true
    end

    def latest_release(repo, data = {})
      repo = repo.full_name unless repo.is_a? String
      trepo = tracked_repo(repo)

      refresh_repo(repo, data) if (trepo[:next_data_sync] || Time.new(0)) < Time.now
      refresh_repo(repo, data) unless (trepo.keys & %i[full_name name html_url]).count == 3

      return trepo[:latest] if (trepo[:next_check] || Time.new(0)) > Time.now
      logger.debug "Timeout (#{trepo[:next_check]}) reached on `latest_release`, refreshing data for repository #{repo}"

      allow = trepo.fetch(:allow, :releases)

      if allow == :tags
        logger.debug "Reading tags for repository #{repo}"
        refs = client.refs(repo, 'tags', data)

        # GitHub sorts refs lexicographically, not by date
        ref_name = Net::HTTP.get(URI("https://github.com/#{repo}/tags"))[/tag-name">(.*)<\/span>/, 1]
        ref = refs.find { |r| r.ref.end_with? ref_name } || refs.last

        tag = ref.object.rels[:self].get.data if ref && ref.object.type == 'tag'
        commit = ref.object.rels[:self].get.data if ref && ref.object.type == 'commit'

        if tag
          release = Struct.new(:tag_name, :published_at, :html_url, :body) do
            def name
              tag_name
            end
          end.new(tag.tag, tag.tagger.date, "https://github.com/#{repo}/releases/tag/#{tag.tag}", tag.message.strip)
        elsif commit
          tag_name = ref.ref.sub('refs/tags/', '')
          release = Struct.new(:tag_name, :published_at, :html_url, :body) do
            def name
              tag_name
            end
          end.new(tag_name, commit.committer.date, "https://github.com/#{repo}/releases/tag/#{tag_name}", nil)
        end
      elsif allow == :prereleases
        logger.debug "Reading pre-releases for repository #{repo}"
        release = per_page(5) { client.releases(repo, data) }.first
      else
        release = client.latest_release(repo, data) rescue nil
      end

      trepo[:next_check] = Time.now + with_stagger(trepo[:latest] ? RELEASE_EXPIRY : NIL_RELEASE_EXPIRY)
      if release.nil?
        trepo[:latest] = nil
        if trepo[:allow].nil?
          logger.debug "No latest release for repository #{repo}, checking for tags..."
          refs = per_page(1) { client.refs(repo, 'tags', data) } rescue nil

          unless refs.nil? || refs.empty?
            trepo[:allow] = :tags
            trepo[:next_check] = Time.now
          end
        end
        return
      end

      relbody = release.body

      trepo[:latest] = [release].compact.map do |rel|
        {
          name: rel.name,
          tag_name: rel.tag_name,
          published_at: rel.published_at,
          html_url: rel.html_url
        }
      end.first

      trepo[:latest].dup.merge(body: relbody)
    end

    def last_releases(user = config[:user])
      ret = { releases: {} }
      data = { headers: {} }

      stars(user).each do |star|
        latest = latest_release(star, data)
        next if latest.nil?

        repo = tracked_repo(star)
        ret[:releases][star] = [latest].compact.map do |rel|
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
          end
        end.first
      end

      ret[:last_check] = config[:last_check] if config.key? :last_check
      config[:last_check] = Time.now

      ret
    end

    private

    def with_stagger(value)
      value + (Random.rand - 0.5) * (value / 2.0)
    end

    def tracked_repos
      (config[:tracked] ||= {})[:repos] ||= {}
    end

    def tracked_repo(reponame)
      tracked_repos[reponame] ||= {}
    end

    def tracked_users
      (config[:tracked] ||= {})[:users] ||= {}
    end

    def tracked_user(username)
      tracked_users[username] ||= {}
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
