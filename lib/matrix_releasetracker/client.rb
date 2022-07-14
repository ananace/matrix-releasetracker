# frozen_string_literal: true

require 'base64'
require 'json'
require 'zlib'
require 'matrix_sdk'
require 'matrix_sdk/errors'

module MatrixReleasetracker
  class Client
    ACCOUNT_DATA_KEY = 'com.github.ananace.RequestTracker.data'
    ROOM_STATE_KEY = 'dev.ananace.ReleaseTracker'
    ACCOUNT_DATA_FILTER = {
      presence: { types: [] },
      account_data: { limit: 1, types: [ACCOUNT_DATA_KEY] },
      room: {
        rooms: [],
        ephemeral: { types: [] },
        state: { types: [ROOM_STATE_KEY] },
        timeline: { types: [] },
        account_data: { limit: 1, types: [ACCOUNT_DATA_KEY] }
      }
    }.freeze

    attr_reader :client, :config, :api, :data, :room_data

    def initialize(config:, **configuration)
      @config = config
      @use_sync = configuration.delete(:use_sync) { false }
      @client = MatrixSdk::Client.new configuration.delete(:hs_url), configuration
      @api = client.api
      @data = {}
      @room_data = {}

      client.on_state_event.add_handler(ROOM_STATE_KEY) do |state|
        set_room_data(state[:room_id], state[:content])
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

    def reload!
      @user ||= client.mxid

      if @use_sync
        reload_with_sync
      else
        reload_with_get
      end

      @data.delete :users

      client.rooms.each do |room|
        begin
          new_room_data = api.get_room_state(room.id, ROOM_STATE_KEY)
          set_room_data(room, new_room_data)
        rescue MatrixSdk::MatrixRequestError => e
          raise e unless e.code == 'M_NOT_FOUND'
        end
      end

      true
    end

    def set_room_data(room_id, data)
      room_id = room_id.id.to_s if room_id.is_a? MatrixSdk::Room
      room_id = room_id.to_s if room_id.is_a? MatrixSdk::MXID

      # {
      #   "tracking": [
      #     {
      #       "backend": "github",
      #       "type": "user", # stars
      #       "object": "username"
      #     },
      #     {
      #       "backend": "github",
      #       "type": "repository", # single repo
      #       "object": "repository"
      #     },
      #     {
      #       "backend": "github",
      #       "type": "group", # repos under a namespace
      #       "object": "organization/user"
      #     }
      #   ]
      # }
      
      logger.debug "Updating room #{room_id} data with #{data.inspect}"
      tracked = data[:tracking].map { |object|
        if (%[backend type object] - object.keys).any?
          logger.warn "Tracking object #{object} is missing required keys"
          next
        end

        backend = config.backends[object[:backend].to_sym]
        if backend
          object.delete :backend
          Structs::Tracking.new_from_state(room_id: room_id, backend: backend, object: object[:object])
        else
          logger.warn "Unknown backend #{backend.inspect} for #{object} in room #{room_id}"
        end
      }

      # TODO: Update backends

      @room_data[room_id] = tracked
    rescue StandardError => ex
      logger.error "Failed to store room data for #{room_id}, #{ex.class}: #{ex}"
    end

    def save!
      attempts = 0
      loop do
        to_save = @data
        api.set_account_data(@user.user_id, ACCOUNT_DATA_KEY, to_save)

        @room_data.each do |room_id, data|
          next if data.nil? || data.empty?

          api.set_room_account_data(@user.user_id, room_id, ACCOUNT_DATA_KEY, data)
        end

        return true
      rescue StandardError => e
        raise if attempts >= 5
        attempts += 1

        logger.error "#{e.class} when storing account data: #{e}. Retrying in 1s"
        sleep 1
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
      @data = api.request(:get, :client_r0, "/user/#{@user}/account_data/#{ACCOUNT_DATA_KEY}")
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
