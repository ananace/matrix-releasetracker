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
      @room_data = {}

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

    def users
      data[:users]
    end

    def room_data(room_id)
      @room_data[room_id] ||= api.get_room_account_data(@user.user_id, room_id, ACCOUNT_DATA_KEY)
    rescue MatrixSdk::MatrixRequestError => err
      raise err unless err.code == 'M_NOT_FOUND'
      @room_data[room_id] ||= {}
    end

    def reload!
      if !@use_sync &&
         (api.server_version.name != 'Synapse' ||
          Gem::Version.new(api.server_version.version) >= Gem::Version.new('0.34.1'))
        reload_with_get
      else
        reload_with_sync
      end

      @data[:users] = (@data[:users] || []).map do |u|
        Structs::User.new u[:name], u[:room], u[:backend], last_check: u.dig(:persistent_data, :last_check)
      end

      @room_data.each_key do |room_id|
        @room_data[room_id] = api.get_room_account_data(@user.user_id, room_id, ACCOUNT_DATA_KEY)
      end

      true
    end

    def save!
      to_save = @data.dup.tap do |d|
        d[:users] = d[:users].map(&:to_h)
      end
      api.set_account_data(@user.user_id, ACCOUNT_DATA_KEY, to_save)

      @room_data.each do |room_id, data|
        api.set_room_account_data(@user.user_id, room_id, ACCOUNT_DATA_KEY, data)
      end

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
