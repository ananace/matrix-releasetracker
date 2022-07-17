# frozen_string_literal: true

require 'faraday-http-cache'
require 'octokit'
require 'time'

module MatrixReleasetracker
  module Backends
    class Github < MatrixReleasetracker::Backend
      InternalRelease = Struct.new(:sha, :tag_name, :name, :date, :url, :description, :type)

      def name
        'GitHub'
      end

      def rate_limit
        limit = client.rate_limit

        MatrixReleasetracker::Structs::RateLimit.new(self, 'REST', limit.limit, limit.remaining, limit.resets_at, limit.resets_in)
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
          MatrixReleasetracker::Structs::RateLimit.new(
            self, 'REST',
            rest_limit.limit, rest_limit.remaining,
            rest_limit.resets_at, rest_limit.resets_in
          ),
          MatrixReleasetracker::Structs::RateLimit.new(
            self, 'GraphQL',
            graphql_limit.limit, graphql_limit.remaining,
            Time.parse(graphql_limit.resetAt), Time.parse(graphql_limit.resetAt) - Time.now
          )
        ]
      end

      protected

      # Backend implementations
      def find_group_repositories(group_name, **_)
        paginate { client.list_repos(group_name) }.map(&:full_name).sort
      end

      def find_user_repositories(user_name, **_)
        paginate { client.starred(user_name) }.map(&:full_name).sort
      end

      def find_repo_information(repo_name, **_)
        repo = client.repository(repo_name)

        avatar = URI(repo.avatar_url || repo.owner.avatar_url || 'https://avatars1.githubusercontent.com/u/9919')
        avatar.query += '&s=32'
        avatar.query.gsub!(/^&/, '')

        {
          full_name: repo.full_name,
          name: repo.name,
          namespace: repo.namespace,
          html_url: repo.html_url,
          avatar_url: avatar.to_s
        }
      end

      def find_repo_releases(repo, allow: nil, **_)
        allow ||= %i[lightweight_tag tag release]

        if gql_available?
          find_gql_releases(repo[:slug]).select { |r| allow.include? r[:type] }
        elsif allow.include? :release
          find_rest_releases(repo[:slug])
        end
      rescue Octokit::NotFound
        nil
      end

      private

      #
      # Internal queries
      #
      # rubocop:disable Metrics/MethodLength
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

          # TODO: Check the GraphQL API more thoroughly, if this really can't be retrieved instead of calculated
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
      # rubocop:enable Metrics/MethodLength

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

      # Low-level query methods
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
                                    logger.debug 'GQL: Using access token'
                                    Octokit::Client.new access_token: config[:access_token]
                                  elsif config.key?(:login) && config.key?(:password)
                                    logger.debug 'GQL: Using login'
                                    Octokit::Client.new login: config[:login], password: config[:password]
                                  else
                                    raise ArgumentError, 'GraphQL access on the GitHub API requires account access'
                                  end)
      end

      def client
        @client ||= use_stack(if config.key?(:client_id) && config.key?(:client_secret)
                                logger.debug 'REST: Using OAuth'
                                Octokit::Client.new client_id: config[:client_id], client_secret: config[:client_secret]
                              elsif config.key?(:access_token)
                                logger.debug 'REST: Using access token'
                                Octokit::Client.new access_token: config[:access_token]
                              elsif config.key?(:login) && config.key?(:password)
                                logger.debug 'REST: Using login'
                                Octokit::Client.new login: config[:login], password: config[:password]
                              else
                                logger.debug 'REST: Using no authorization'
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
end
