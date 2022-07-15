# frozen_string_literal: true

require 'net/http'

module MatrixReleasetracker::Backends
  class Gitea < MatrixReleasetracker::Backend
    def name
      'Gitea'
    end

    protected

    #
    # Inheritance implementation
    #
    # def find_group_information(group_name)
    #   instance, group_name = group_name.split(':')
    #   group_name, instance = instance, group_name if group_name.nil?

    #   []
    # end

    def find_repo_information(repo_name)
      instance, repo_name = repo_name.split(':')
      repo_name, instance = instance, repo_name if repo_name.nil?

      find_rest_repository(repo_name, instance: instance)
    end

    # def find_user_information(user_name)
    #   instance, user_name = user_name.split(':')
    #   user_name, instance = instance, user_name if user_name.nil?

    #   []
    # end

    def find_repo_releases(repo, limit: 1)
      instance, repo_name = repo[:slug].split(':')
      repo_name, instance = instance, repo_name if repo_name.nil?

      find_rest_releases(repo_name, limit: limit, instance: instance)
    end

    private

    def find_rest_repository(repo_name, instance:)
      res = with_client(instance) { |http, path|
        http.get2 "#{path}/repos/#{repo_name}", { 'content-type' => 'application/json' }
      }

      if !res.is_a? Net::HTTPOK
        headers = res.to_hash.map { |k, v| "#{k}: #{v.join(', ')}" }.join("\n")
        logger.error "#{res.inspect}\n#{headers}\n#{res.body}"
        raise res.body
      end

      data = JSON.parse(res.body, symbolize_names: true)

      data.slice(*%i[name html_url]).merge(
        full_name: "#{instance}:#{data[:full_name]}",

        namespace: data[:full_name].split('/')[0..-2].join('/'),
        avatar_url: data[:avatar_url] || data[:owner][:avatar_url] || 'https://gitea.io/images/gitea.png',
      )
    end

    def find_rest_releases(repo_name, instance:, limit: 1)
      res = with_client(instance) { |http, path|
        http.get2 "#{path}/repos/#{repo_name}/releases?limit=#{limit}", { 'content-type' => 'application/json' }
      }

      if !res.is_a? Net::HTTPOK
        headers = res.to_hash.map { |k, v| "#{k}: #{v.join(', ')}" }.join("\n")
        logger.error "#{res.inspect}\n#{headers}\n#{res.body}"
        raise res.body
      end

      data = JSON.parse(res.body, symbolize_names: true)

      data.map do |release|
        release.slice(*%i[name tag_name html_url body]).merge(
          published_at: Time.parse(release[:published_at]),
          type: release[:prerelease] ? :prerelease : :release
        )
      end
    end

    def with_client(instance, &block)
      cl = client(instance)

      if instance.start_with? 'https://'
        path = URI(instance).path
      else
        path = '/api/v1'
      end

      block.call(cl, path)
    end

    def client(instance)
      @clients ||= {}
      @clients[instance] ||= begin
        if instance.end_with? '/api/v1'
          uri = URI(instance)
        else
          uri = URI("https://#{instance}/api/v1")
        end
        connection = Net::HTTP.new(uri.host, uri.port)
        connection.use_ssl = uri.scheme == 'https'

        connection
      end
    end
  end
end
