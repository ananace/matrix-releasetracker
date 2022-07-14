# frozen_string_literal: true

require 'base64'
require 'json'
require 'pp'
require 'zlib'
require 'matrix_sdk'
require 'matrix_sdk/errors'

module MatrixReleasetracker
  class Client
    include PP::ObjectMixin
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
      @use_sync = false
      @client = MatrixSdk::Client.new configuration.delete(:hs_url), configuration.merge(client_cache: :some)
      @api = client.api
      @data = {}
      @room_data = {}

      client.on_invite_event.add_handler do |ev|
        logger.info "Invited to #{ev[:room_id]}."
        if config.backends.map { |_k, b| b.tracking.map { |u| u.room_id } }.flatten.uniq.count > 50
          logger.info "But tracking more than 50 object already, so ignoring."
          return
        end
        client.join_room(ev[:room_id])
      end

      client.on_event.add_handler('m.room.message') do |ev|
        room_id = ev.room_id.to_s
        message = ev

        return unless message[:content][:body].start_with? '!github '
        return unless config.backends.keys.include? :github

        logger.info "#{message[:sender]} in #{room_id}: #{message[:content][:body]}"

        users = api.get_room_members(room_id)[:chunk].select { |c| c[:content][:membership] == 'join' }
        if users.count > 2
          api.send_notice(room_id.to_s, 'Not a 1:1 room, ignoring request.')
          return
        end

        if config.client.room_data.key? room_id
          api.send_notice(room_id.to_s, 'This room uses state tracking object, ignoring request.')
          return
        end

        backend = config.backends[:github]
        existing = backend.tracking.find { |u| u.room_id == room_id.to_s }

        gh_name = message[:content][:body][8..-1].downcase
        return if existing && existing.object == gh_name && existing.type == :user

        if existing
          backend.update_tracking(existing.id, type: :user, object: gh_name)
        else
          backend.add_tracking(type: :user, object: gh_name, room_id: room_id.to_s)
        end

        logger.info "Now tracking GitHub user '#{gh_name}' in #{room_id}"
        api.send_notice(room_id.to_s, "Now tracking GitHub user '#{gh_name}'")
      end

      client.on_state_event.add_handler(ROOM_STATE_KEY) do |state|
        logger.info "Received new room state for room #{state[:room_id]}"
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
      #     },
      #     {
      #       "backend": "gitlab",
      #       "type": "repository",
      #       "object": "repository" # on gitlab.com
      #     },
      #     {
      #       "backend": "gitlab",
      #       "type": "repository",
      #       "object": "repository",
      #       "data": {
      #         "instance": "gitlab.example.com"
      #       }
      #     }
      #   ]
      # }
      
      tracked = data[:tracking].map { |object|
        if (%i[backend type object] - object.keys).any?
          logger.warn "Tracking object #{object} is missing required keys"
          next
        end

        backend = config.backends[object[:backend].to_sym]
        if backend
          object.delete :backend
          Structs::Tracking.new_from_state(
            room_id: room_id,
            backend: backend,
            object: object[:object],
            type: object[:type],
            extradata: object[:data]
          )
        else
          logger.warn "Unknown backend #{backend.inspect} for #{object} in room #{room_id}"
        end
      }

      tracked.each do |obj|
        if obj.tracked?
          obj.update_track
        else
          obj.add_track
        end
      end

      if @room_data.key? room_id
        existing = @room_data[room_id].map { |obj| obj.attributes.slice(:object, :backend, :type) }
        to_remove = existing - tracked.map { |obj| obj.attributes.slice(:object, :backend, :type) }

        to_remove.each do |obj|
          obj.remove_track
        end
      end

      @room_data[room_id] = tracked
    rescue StandardError => ex
      puts "#{ex.class}: #{ex}\n#{ex.backtrace.join("\n")}"
      logger.error "Failed to store room data for #{room_id}, #{ex.class}: #{ex}"
    end

    def save!
      attempts = 0
      loop do
        to_save = @data
        api.set_account_data(@user, ACCOUNT_DATA_KEY, to_save)

        return true
      rescue StandardError => e
        raise if attempts >= 5
        attempts += 1

        logger.error "#{e.class} when storing account data: #{e}. Retrying in 1s"
        sleep 1
      end
    end

    def pretty_print_instance_variables
      instance_variables.sort.reject { |n| %i[@client @config @api].include? n }
    end

    def pretty_print(pp)
      pp.pp_object(self)
    end

    alias inspect pretty_print_inspect

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
