require 'json'
require 'matrix_sdk'

module MatrixReleasetracker
  class Client
    ACCOUNT_DATA_KEY = 'com.github.ananace.RequestTracker.data'.freeze
    ACCOUNT_DATA_FILTER = {
      presence: { types: [] },
      account_data: { limit: 1, types: [ACCOUNT_DATA_KEY] },
      room: {
        rooms: [],
        ephemeral: { types: [] },
        state: { types: [] },
        timeline: { types: [] },
        account_data: { limit: 1, types: [ACCOUNT_DATA_KEY] }
      }
    }.freeze

    attr_reader :api, :data

    def initialize(configuration)
      @use_sync = configuration.delete(:use_sync) { false }
      @api = MatrixSdk::Api.new configuration.delete(:hs_url), configuration
      @data = {}

      begin
        @user = api.whoami? # TODO: @api.logged_in?
        reload!

        data[:next_batch] = configuration.delete :next_batch if configuration.key? :next_batch
      rescue MatrixSdk::MatrixRequestError => ex
        raise ex if ex.httpstatus != 401
      end
    end

    def next_batch
      data[:next_batch]
    end

    def next_batch=(batch)
      data[:next_batch] = batch
    end

    def reload!
      if !@use_sync &&
         (api.server_version.name != 'Synapse' ||
          Gem::Version.new(api.server_version.version) >= Gem::Version.new('0.34.1'))
        reload_with_get
      else
        reload_with_sync
      end

      true
    end

    def save!
      api.set_account_data(@user.user_id, ACCOUNT_DATA_KEY, @data)

      true
    end

    private

    def reload_with_sync
      @data = [api.sync(timeout: 5.0, set_presence: :offline, filter: ACCOUNT_DATA_FILTER.to_json)].map do |data|
        data = data[:account_data][:events].find { |ev| ev[:type] == ACCOUNT_DATA_KEY }
        (data[:content] if data) || {}
      end.first
    end

    def reload_with_get
      @data = api.request(:get, :client_r0, "/user/#{@user.user_id}/account_data/#{ACCOUNT_DATA_KEY}")
    rescue MatrixSdk::MatrixRequestError => ex
      return {} if ex.httpstatus == 404
      if ex.httpstatus == 400
        @use_sync = true
        return reload_with_sync
      end
      raise ex
    end
  end
end
