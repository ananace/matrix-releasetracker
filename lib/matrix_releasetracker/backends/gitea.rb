# frozen_string_literal: true

require 'net/http'

module MatrixReleasetracker
  module Backends
    class Gitea < MatrixReleasetracker::Backend
      class Error < MatrixReleasetracker::Backend::Error; end

      def name
        'Gitea'
      end

      protected

      #
      # Inheritance implementation
      #
      def find_group_information(group_name, token: nil, **params)
        instance, group_name = group_name.split(':')
        group_name, instance = instance, group_name if group_name.nil?
        instance ||= params[:instance] if params.key? :instance

        find_rest_group_repositories(group_name, instance: instance, token: token)
      end

      def find_repo_information(repo_name, token: nil, **params)
        instance, repo_name = repo_name.split(':')
        repo_name, instance = instance, repo_name if repo_name.nil?
        instance ||= params[:instance] if params.key? :instance

        find_rest_repository(repo_name, instance: instance, token: token)
      end

      def find_user_information(user_name, token: nil, **params)
        instance, user_name = user_name.split(':')
        user_name, instance = instance, user_name if user_name.nil?
        instance ||= params[:instance] if params.key? :instance

        find_rest_user_repositories(user_name, instance: instance, token: token)
      end

      def find_repo_releases(repo, limit: 1, token: nil, **params)
        instance, repo_name = repo[:slug].split(':')
        repo_name, instance = instance, repo_name if repo_name.nil?
        instance ||= params[:instance] if params.key? :instance

        find_rest_releases(repo_name, limit: limit, instance: instance, token: token)
      end

      private

      def find_rest_group_repositories(group, instance:, token: nil)
        data = find_rest_data("orgs/#{group}/repos", instance: instance, token: token, allow_notfound: true)
        data = find_rest_data("users/#{group}/repos", instance: instance, token: token) if data.is_a? Net::HTTPNotFound

        data.map { |repo| repo[:full_name] }
      end

      def find_rest_repository(repo_name, instance:, token: nil)
        data = find_rest_data("repos/#{repo_name}", instance: instance, token: token)

        data.slice(*%i[name html_url]).merge(
          full_name: "#{instance}:#{data[:full_name]}",

          namespace: data[:full_name].split('/')[0..-2].join('/'),
          avatar_url: data[:avatar_url] || data[:owner][:avatar_url] || 'https://gitea.io/images/gitea.png'
        )
      end

      def find_rest_user_repositories(user, instance:, token: nil)
        data = find_rest_data("users/#{user}/starred", instance: instance, token: token)

        data.map { |repo| repo[:full_name] }
      end

      def find_rest_releases(repo_name, instance:, limit: 1, token: nil)
        data = find_rest_data("repos/#{repo_name}/releases?limit=#{limit}", instance: instance, token: token)

        data.map do |release|
          release.slice(*%i[name tag_name html_url body]).merge(
            published_at: Time.parse(release[:published_at]),
            type: release[:prerelease] ? :prerelease : :release
          )
        end
      end

      def find_rest_data(path, instance:, token: nil, allow_notfound: false)
        headers = { 'content-type' => 'application/json' }
        headers['authorization'] = "Bearer #{token}" if token
        res = with_client(instance) do |http, base_path|
          http.get2 [base_path, path].join('/'), headers
        end

        unless res.is_a? Net::HTTPOK
          return res if allow_notfound

          logger.error "#{res.inspect} - #{res.body}"
          raise Error, res.body
        end

        JSON.parse(res.body, symbolize_names: true)
      end

      def with_client(instance, &block)
        cl = client(instance)

        path = if instance.start_with? 'https://'
                 URI(instance).path
               else
                 '/api/v1'
               end

        block.call(cl, path)
      end

      def client(instance)
        @clients ||= {}
        @clients[instance] ||= begin
          uri = if instance.end_with? '/api/v1'
                  URI(instance)
                else
                  URI("https://#{instance}/api/v1")
                end
          connection = Net::HTTP.new(uri.host, uri.port)
          connection.use_ssl = uri.scheme == 'https'

          connection
        end
      end
    end
  end
end
