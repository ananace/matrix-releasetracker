require 'base64'
require 'json'
require 'zlib'
require 'matrix_sdk'

module MatrixReleasetracker
  class Client
    ACCOUNT_DATA_KEY = 'com.github.ananace.RequestTracker.data'.freeze
    ACCOUNT_MEDIA_KEY = 'com.github.ananace.RequestTracker.media'.freeze
    ACCOUNT_DATA_FILTER = {
      presence: { types: [] },
      account_data: { limit: 1, types: [ACCOUNT_DATA_KEY, ACCOUNT_MEDIA_KEY] },
      room: {
        rooms: [],
        ephemeral: { types: [] },
        state: { types: [] },
        timeline: { types: [] },
        account_data: { limit: 1, types: [ACCOUNT_DATA_KEY, ACCOUNT_MEDIA_KEY] }
      }
    }.freeze

    attr_reader :api, :data
    attr_accessor :media

    def initialize(configuration)
      @use_sync = configuration.delete(:use_sync) { false }
      @api = MatrixSdk::Api.new configuration.delete(:hs_url), configuration
      @data = {}
      @raw_media = nil
      @media = {}
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
    rescue MatrixSdk::MatrixRequestError => e
      raise e unless e.code == 'M_NOT_FOUND'

      @room_data[room_id] ||= {}
    end

    def reload!
      reload_with_get

      decompress_media
      @media = @data.delete(:media) if @data.key? :media

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
      compress_media
      api.set_account_data(@user.user_id, ACCOUNT_DATA_KEY, to_save)
      api.set_account_data(@user.user_id, ACCOUNT_MEDIA_KEY, data: @raw_media)

      @room_data.each do |room_id, data|
        api.set_room_account_data(@user.user_id, room_id, ACCOUNT_DATA_KEY, data)
      end

      true
    end

    private

    def compress_media
      @raw_media = Base64.strict_encode64(Zlib::Deflate.deflate(@media.to_json, Zlib::BEST_COMPRESSION))
    end

    def decompress_media
      @media = JSON.parse(Zlib::Inflate.inflate(Base64.strict_decode64(@raw_media)), symbolize_names: true) if @raw_media
      @raw_media = nil
    end

    def reload_with_sync
      api.sync(timeout: 5.0, set_presence: :offline, filter: ACCOUNT_DATA_FILTER.to_json).tap do |data|
        data = data[:account_data][:events].find { |ev| ev[:type] == ACCOUNT_DATA_KEY }
        media = data[:account_data][:events].find { |ev| ev[:type] == ACCOUNT_MEDIA_KEY }

        @data = (data[:content] if data) || {}
        @raw_media = (media[:content][:data] if media)
      end
    end

    def reload_with_get
      @data = api.request(:get, :client_r0, "/user/#{@user.user_id}/account_data/#{ACCOUNT_DATA_KEY}")
      @raw_media = api.request(:get, :client_r0, "/user/#{@user.user_id}/account_data/#{ACCOUNT_MEDIA_KEY}")[:data]
    rescue MatrixSdk::MatrixNotFoundError # rubocop:disable Lint/HandleExceptions
      # Not an error
    rescue MatrixSdk::MatrixRequestError => e
      if e.httpstatus == 400
        @use_sync = true
        return reload_with_sync
      end

      raise e
    end
  end
end
