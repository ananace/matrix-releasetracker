require 'base64'
require 'json'
require 'zlib'
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
      rescue MatrixSdk::MatrixRequestError => ex
        raise ex if ex.httpstatus != 401
      end
    end

    def logger
      Logging.logger[self]
    end

    def next_batch
      data[:next_batch]
    end

    def next_batch=(batch)
      data[:next_batch] = batch
    end

    def clear_room_data(room_id)
      # TODO
    end

    def room_data(room_id)
      @room_data[room_id] ||= api.get_room_account_data(@user.user_id, room_id, ACCOUNT_DATA_KEY)
    rescue MatrixSdk::MatrixRequestError => e
      raise e unless e.code == 'M_NOT_FOUND'

      @room_data[room_id] ||= {}
    end

    def reload!
      if @use_sync
        reload_with_sync
      else
        reload_with_get
      end

      @data.delete :users

      api.get_joined_rooms.joined_rooms.each do |room_id|
        begin
          @room_data[room_id] = api.get_room_account_data(@user.user_id, room_id, ACCOUNT_DATA_KEY)
        rescue MatrixSdk::MatrixRequestError => e
          raise e unless e.code == 'M_NOT_FOUND'
        end
      end

      true
    end

    def save!
      attempts = 0
      loop do
        to_save = @data
        logger.debug 'Saving account data'
        api.set_account_data(@user.user_id, ACCOUNT_DATA_KEY, to_save)

        logger.debug "Saving room account data for #{@room_data.size} rooms..."
        @room_data.each do |room_id, data|
          next if data.nil? || data.empty?

          logger.debug "- Saving room account data for room #{room_id}"
          api.set_room_account_data(@user.user_id, room_id, ACCOUNT_DATA_KEY, data)
        end

        logger.debug 'Saved all account data'

        return true
      rescue StandardError => e
        raise if attempts >= 5
        attempts += 1

        logger.error "#{e.class} when storing account data: #{e}. Retrying in 10s"
        sleep 10
      end
    end

    private

    def reload_with_sync
      api.sync(timeout: 5.0, set_presence: :offline, filter: ACCOUNT_DATA_FILTER.to_json).tap do |data|
        data = data[:account_data][:events].find { |ev| ev[:type] == ACCOUNT_DATA_KEY }

        @data = (data[:content] if data) || {}
      end
    end

    def reload_with_get
      @data = api.request(:get, :client_r0, "/user/#{@user.user_id}/account_data/#{ACCOUNT_DATA_KEY}")
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
