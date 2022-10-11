# frozen_string_literal: true

module MatrixReleasetracker
  module Backends
    class Gitlab < MatrixReleasetracker::Backend
      class Error < MatrixReleasetracker::Backend::Error; end
      class GQLError < Error; end
      class RESTError < Error; end

      def name
        'GitLab'
      end

      protected

      #
      # Inheritance implementation
      #
      def find_group_repositories(group_name, token: nil, **params)
        instance, group_name = group_name.split(':')
        group_name, instance = instance, group_name if group_name.nil?
        instance ||= params[:instance] if params.key? :instance

        find_gql_group_repositories(group_name, instance: instance, token: token)
      end

      def find_repo_information(repo_name, token: nil, **params)
        instance, repo_name = repo_name.split(':')
        repo_name, instance = instance, repo_name if repo_name.nil?
        instance ||= params[:instance] if params.key? :instance

        find_gql_repository(repo_name, instance: instance, token: token)
      end

      def find_user_repositories(user_name, token: nil, **params)
        instance, user_name = user_name.split(':')
        user_name, instance = instance, user_name if user_name.nil?
        instance ||= params[:instance] if params.key? :instance

        find_gql_user_repositories(user_name, instance: instance, token: token)
      end

      def find_repo_releases(repo, limit: 1, allow: nil, token: nil, **params)
        instance, repo_name = repo[:slug].split(':')
        repo_name, instance = instance, repo_name if repo_name.nil?
        instance ||= params[:instance] if params.key? :instance
        allow ||= %w[release]

        releases = []
        releases += find_gql_releases(repo_name, limit: limit, instance: instance, token: token) if allow.include? 'release'
        releases += get_rest_tags(repo_name, limit: limit, instance: instance, token: token, allow: allow) if allow.include?('tag') || allow.include?('lightweight_tag')
        releases
      end

      private

      # Main GraphQL queries
      def find_gql_group_repositories(group, instance: nil, token: nil)
        graphql = <<~GQL
          query groupRepoList($fullPath: ID!) {
            namespace(fullPath: $fullPath) {
              projects {
                nodes {
                  fullPath
                }
              }
            }
          }
        GQL

        data = get_gql(graphql, instance: instance, variables: { fullPath: group }, token: token)
        (data.dig(:data, :namespace, :projects, :nodes) || []).map { |n| n[:fullPath] }.sort
      end

      def find_gql_user_repositories(user, instance: nil, token: nil)
        graphql = <<~GQL
          query userRepoList($username: String!) {
            user(username: $username) {
              starredProjects {
                nodes {
                  fullPath
                }
              }
            }
          }
        GQL

        data = get_gql(graphql, instance: instance, variables: { username: user }, token: token, sensitive: true)
        (data.dig(:data, :user, :starredProjects, :nodes) || []).map { |n| n[:fullPath] }.sort
      end

      def find_gql_repository(repo, instance: nil, token: nil)
        graphql = <<~GQL
          query repoInformation($fullPath: ID!) {
            project(fullPath: $fullPath) {
              fullPath
              group {
                fullPath
                avatarUrl
              }
              namespace {
                fullPath
              }
              name
              avatarUrl
              webUrl
            }
          }
        GQL

        data = get_gql(graphql, instance: instance, variables: { fullPath: repo }, token: token)

        {
          full_name: "#{instance}:#{data.dig(:data, :project, :fullPath)}".gsub(/^:/, ''),

          name: data.dig(:data, :project, :name),
          namespace: data.dig(:data, :project, :namespace, :fullPath) ||
            data.dig(:data, :project, :group, :fullPath),
          html_url: data.dig(:data, :project, :webUrl),
          avatar_url: data.dig(:data, :project, :avatarUrl) ||
            data.dig(:data, :project, :group, :avatarUrl)
        }
      end

      def find_gql_releases(repo, limit: 1, instance: nil, token: nil)
        graphql = <<~GQL
          query latestRelease($fullPath: ID!, $limit: Int) {
            project(fullPath: $fullPath) {
              releases(last: $limit, sort: RELEASED_AT_ASC) {
                nodes {
                  tagName
                  commit {
                    sha
                  }
                  name
                  releasedAt
                  links {
                    selfUrl
                  }
                  description
                  upcomingRelease
                }
              }
            }
          }
        GQL

        data = get_gql(graphql, instance: instance, variables: { fullPath: repo, limit: limit }, token: token)

        data.dig(:data, :project, :releases, :nodes).map do |node|
          {
            sha: node.dig(:commit, :sha),
            name: node[:name],
            tag_name: node[:tagName],
            published_at: Time.parse(node[:releasedAt]),
            html_url: node.dig(:links, :selfUrl),
            body: node[:description],
            type: node[:upcomingRelease] ? :prerelease : :release
          }
        end
      end

      def get_rest_tags(repo, limit: 1, allow: nil, instance: nil, token: nil)
        allow ||= %w[tag lightweight_tag]

        data = get_rest("/projects/#{CGI.escape(repo)}/repository/tags", instance: instance, token: token)
        data.map do |node|
          {
            sha: node.dig(:commit, :id),
            name: node[:name],
            tag_name: node[:name],
            published_at: Time.parse(node.dig(:commit, :created_at)),
            html_url: node.dig(:commit, :web_url).gsub(%r{-/commit/.*}, "-/tags/#{node[:name]}"),
            body: node[:message],
            type: node[:message].nil? || node[:message].empty? ? :lightweight_tag : :tag
          }
        end
            .select { |r| allow.include? r[:type].to_s }
            .take(limit)
      end

      # Low-level communication
      def get_gql(graphql, variables: {}, instance: nil, token: nil, sensitive: false)
        instance ||= 'gitlab.com'

        logger.debug "Running GQL #{graphql.split("\n").first[0..-2].strip} on #{instance}"

        headers = { 'content-type' => 'application/json' }
        token ||= config.dig(:instances, instance, :token)
        headers['authorization'] = "Bearer #{token}" if token

        raise Error, 'Need a token in order to do user/starred queries for GitLab' if sensitive && token.nil?

        res = with_client(instance) do |http, path|
          http.post path, { query: graphql, variables: variables }.to_json, headers
        end

        if res.is_a? Net::HTTPOK
          data = JSON.parse(res.body, symbolize_names: true)
          raise GQLError, data[:errors].map { |err| "#{err[:path].join('.')}: #{err[:message]}" }.join("\n") if data.key? :errors

          data
        else
          logger.error "#{res.inspect}\n#{res.body.strip}"
          raise Error, res.body.strip
        end
      end

      def get_rest(path, instance: nil, token: nil)
        instance ||= 'gitlab.com'

        logger.debug "Executing REST GET #{path} on #{instance}"

        headers = { 'content-type' => 'application/json' }
        token ||= config.dig(:instances, instance, :token)
        headers['authorization'] = "Bearer #{token}" if token

        res = with_client(instance, api: :v4) do |http, basepath|
          http.get File.join(basepath, path), headers
        end

        if res.is_a? Net::HTTPOK
          JSON.parse(res.body, symbolize_names: true)
        else
          data = JSON.parse(res.body, symbolize_names: true) rescue {}
          raise RESTError, data[:message] if data.key? :message

          logger.error "#{res.inspect}\n#{res.body.strip}"
          raise Error, res.body.strip
        end
      end

      def with_client(instance, api: :graphql, &block)
        cl = client(instance)

        path = if instance&.start_with? 'https://'
                 URI(instance).path
               else
                 "/api/#{api}"
               end

        block.call(cl, path)
      end

      def client(instance, api: :graphql)
        @clients ||= {}
        @clients[instance] ||= begin
          uri = if instance.end_with? "/api/#{api}"
                  URI(instance)
                else
                  URI("https://#{instance}/api/#{api}")
                end
          connection = Net::HTTP.new(uri.host, uri.port)
          connection.use_ssl = uri.scheme == 'https'

          connection
        end
      end
    end
  end
end
