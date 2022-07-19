# frozen_string_literal: true

module MatrixReleasetracker
  module Backends
    class Gitlab < MatrixReleasetracker::Backend
      class Error < MatrixReleasetracker::Backend::Error; end
      class GQLError < Error; end

      def name
        'GitLab'
      end

      protected

      # Inheritance implementation
      # def find_group_information(group_name)
      #   instance, group_name = group_name.split(':')
      #   group_name, instance = instance, group_name if group_name.nil?
      #   instance ||= params[:instance] if params.key? :instance

      #   []
      # end

      def find_repo_information(repo_name, **params)
        instance, repo_name = repo_name.split(':')
        repo_name, instance = instance, repo_name if repo_name.nil?
        instance ||= params[:instance] if params.key? :instance

        find_gql_repository(repo_name, instance: instance, token: params[:token])
      end

      # def find_user_information(user_name)
      #   instance, user_name = user_name.split(':')
      #   user_name, instance = instance, user_name if user_name.nil?
      #   instance ||= params[:instance] if params.key? :instance

      #   []
      # end

      def find_repo_releases(repo, limit: 1, **params)
        instance, repo_name = repo[:slug].split(':')
        repo_name, instance = instance, repo_name if repo_name.nil?
        instance ||= params[:instance] if params.key? :instance

        find_gql_releases(repo_name, limit: limit, instance: instance, token: params[:token])
      end

      # Main GraphQL queries
      def find_gql_group_repositories(group, instance: nil, token: nil)
        graphql = <<~GQL
          query groupList($fullPath: ID!) {
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
          query userList($username: String!) {
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

      # Low-level communication
      def get_gql(graphql, variables: {}, instance: nil, token: nil, sensitive: false)
        instance ||= 'gitlab.com'

        headers = { 'content-type' => 'application/json' }
        token ||= config.dig(:instances, instance, :token)
        headers['authorization'] = "Bearer #{token}" if token

        raise Error, 'Need a token in order to do user/starred queries for GitLab' if sensitive && token.nil?

        logger.debug "< #{graphql.inspect}"
        res = with_client(instance) do |http, path|
          http.post path, { query: graphql, variables: variables }.to_json, headers
        end

        if res.is_a? Net::HTTPOK
          logger.debug "> #{res.body.inspect}"
          data = JSON.parse(res.body, symbolize_names: true)
          raise GQLError, data[:errors].map { |err| "#{err[:path].join('.')}: #{err[:message]}" }.join("\n") if data.key? :errors

          data
        else
          headers = res.to_hash.map { |k, v| "#{k}: #{v.join(', ')}" }.join("\n")
          logger.error "#{res.inspect}\n#{headers}\n#{res.body}"
          raise Error, res.body
        end
      end

      def with_client(instance, &block)
        cl = client(instance)

        path = if instance&.start_with? 'https://'
                 URI(instance).path
               else
                 '/api/graphql'
               end

        block.call(cl, path)
      end

      def client(instance)
        @clients ||= {}
        @clients[instance] ||= begin
          uri = if instance.end_with? '/api/graphql'
                  URI(instance)
                else
                  URI("https://#{instance}/api/graphql")
                end
          connection = Net::HTTP.new(uri.host, uri.port)
          connection.use_ssl = uri.scheme == 'https'

          connection
        end
      end
    end
  end
end
