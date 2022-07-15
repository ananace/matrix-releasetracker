# frozen_string_literal: true

module MatrixReleasetracker::Backends
  class Gitlab < MatrixReleasetracker::Backend

    def name
      'GitLab'
    end

    protected

    # Inheritance implementation
    # def find_group_information(group_name)
    #   instance, group_name = group_name.split(':')
    #   group_name, instance = instance, group_name if group_name.nil?

    #   []
    # end

    def find_repo_information(repo_name)
      instance, repo_name = repo_name.split(':')
      repo_name, instance = instance, repo_name if repo_name.nil?
      
      find_gql_repository(repo_name, instance: instance)
    end

    # def find_user_information(user_name)
    #   instance, user_name = user_name.split(':')
    #   user_name, instance = instance, user_name if user_name.nil?

    #   []
    # end

    def find_repo_releases(repo, limit: 1)
      instance, repo_name = repo[:slug].split(':')
      repo_name, instance = instance, repo_name if repo_name.nil?
      
      find_gql_releases(repo_name, limit: limit, instance: instance)
    end

    # Main GraphQL queries
    def find_gql_repository(repo, instance: nil)
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

      data = get_gql(graphql, instance: instance, variables: { fullPath: repo })

      {
        full_name: "#{instance}:#{data.dig('data', 'project', 'fullPath')}".gsub(/^:/, ''),

        name: data.dig('data', 'project', 'name'),
        namespace: data.dig('data', 'project', 'namespace', 'fullPath') ||
          data.dig('data', 'project', 'group', 'fullPath'),
        html_url: data.dig('data', 'project', 'webUrl'),
        avatar_url: data.dig('data', 'project', 'avatarUrl') ||
          data.dig('data', 'project', 'group', 'avatarUrl'),
      }
    end

    def find_gql_releases(repo, limit: 1, instance: nil)
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

      data = get_gql(graphql, instance: instance, variables: { fullPath: repo, limit: limit })

      data.dig('data', 'project', 'releases', 'nodes').map do |node|
        {
          sha: node.dig('commit', 'sha'),
          name: node['name'],
          tag_name: node['tagName'],
          published_at: Time.parse(node['releasedAt']),
          html_url: node.dig('links', 'selfUrl'),
          body: node['description'],
          type: node['upcomingRelease'] ? :prerelease : :release
        }
      end
    end

    # Low-level communication
    def get_gql(graphql, variables: {}, instance: nil)
      res = with_client(instance) { |http, path|
        http.post path, { query: graphql, variables: variables }.to_json, { 'content-type' => 'application/json' }
      }

      if res.is_a? Net::HTTPOK
        JSON.load(res.body, symbolize_keys: true)
      else
        headers = res.to_hash.map { |k, v| "#{k}: #{v.join(', ')}" }.join("\n")
        logger.error "#{res.inspect}\n#{headers}\n#{res.body}"
        raise res.body
      end
    end

    def with_client(instance, &block)
      cl = client(instance)

      if instance&.start_with? 'https://'
        path = URI(instance).path
      else
        path = '/api/graphql'
      end

      block.call(cl, path)
    end

    def client(instance)
      instance ||= 'gitlab.com'

      @clients ||= {}
      @clients[instance] ||= begin
        if instance.end_with? '/api/graphql'
          uri = URI(instance) 
        else
          uri = URI("https://#{instance}/api/graphql") 
        end
        connection = Net::HTTP.new(uri.host, uri.port)
        connection.use_ssl = uri.scheme == 'https'

        connection
      end
    end
  end
end

