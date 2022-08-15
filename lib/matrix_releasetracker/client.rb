# frozen_string_literal: true

require 'base64'
require 'json'
require 'pp'
require 'zlib'
require 'matrix_sdk'
require 'matrix_sdk/bot/base'
require 'matrix_sdk/errors'

module MatrixReleasetracker
  class Client < MatrixSdk::Bot::Base
    ACCOUNT_DATA_KEY = 'com.github.ananace.RequestTracker.data'
    ROOM_STATE_KEY = 'dev.ananace.ReleaseTracker'
    ACCOUNT_DATA_FILTER = {
      presence: { types: [] },
      account_data: { limit: 1, types: [ACCOUNT_DATA_KEY] },
      room: {
        rooms: [],
        ephemeral: { types: [] },
        state: { types: [ROOM_STATE_KEY] },
        timeline: { types: ['m.room.message'] },
        account_data: { limit: 1, types: [ACCOUNT_DATA_KEY] }
      }
    }.freeze

    attr_reader :room_data

    disable :accept_invites
    enable :store_sync_token

    enable :legacy_commands

    set :sync_filter, ACCOUNT_DATA_FILTER

    command 'github', desc: '(Legacy) Track GitHub user stars', only: [:dm, -> { settings.legacy_commands? }, -> { config.backends.keys.include? :github }] do |user|
      raise ArgumentError, 'Needs to specify a user' unless user

      if config.client.room_data.key? room_id
        api.send_notice(room_id.to_s, 'This room uses state tracking object, ignoring request.')
        return
      end

      backend = config.backends[:github]
      existing = backend.tracking.find { |u| u.room_id == room.id }

      return if existing && existing.object == user && existing.type == :user

      if existing
        backend.update_tracking(existing.id, type: :user, object: user)
      else
        backend.add_tracking(type: :user, object: user, room_id: room.id)
      end

      logger.info "Now tracking GitHub user '#{user}' in #{room_id}"
      room.send_notice("Now tracking GitHub user '#{gh_name}'")
    end

    command 'list', desc: 'List all currently tracked objects' do
      legacy = false
      begin
        client.api.get_room_state(room.id, ROOM_STATE_KEY)
      rescue MatrixSdk::NotFoundError
        legacy = true
      end

      tracked = \
        config
        .backends
        .map { |_, b| [b, b.send(:database)[:tracking].where(backend: b.send(:db_type), room_id: room.id.to_s)] }
        .map { |b, data| data.map { |t| Structs::Tracking.new_from_state(**t.merge(backend: b)) } }
        .flatten
        .map { |t| "#{t.backend.name} #{t.type} #{t.object}" }

      if tracked.empty?
        msg = 'Not currently tracking anything'
      else
        msg = 'Currently Tracking:'
        msg += ' (Legacy)' if legacy
        msg += "\n- #{tracked.join("\n- ")}"
      end

      room.send_notice msg
    end

    command 'track', desc: 'Add a tracking URI', only: -> { room.user_can_send?(client.mxid, ROOM_STATE_KEY, state: true) } do |uri|
      raise ArgumentError, 'Need to specify a tracking URI' unless uri

      tracking, errors = parse_tracking_object(uri)
      raise ArgumentErrors, errors.join("\n") if errors.any?

      backend = config.backends[tracking[:backend].to_sym]
      raise ArgumentError, "Missing backend '#{tracking[:backend]}'" unless backend

      current = {}
      begin
        current = client.api.get_room_state(room.id, ROOM_STATE_KEY)
      rescue MatrixSdk::NotFoundError
        # Acceptable
      end

      tracking = (current[:tracking] ||= [])
      tracking << uri

      client.api.send_state_event(room.id, ROOM_STATE_KEY, current)
    end

    command :untrack, desc: 'Removes a tracking URI', only: -> { room.user_can_send?(client.mxid, ROOM_STATE_KEY, state: true) } do |uri|
      raise ArgumentError, 'Need to specify a tracking URI' unless uri

      current = {}
      begin
        current = client.api.get_room_state(room.id, ROOM_STATE_KEY)
      rescue MatrixSdk::NotFoundError
        return
      end

      tracking = (current[:tracking] ||= [])
      before = tracking.dup

      tracking.remove_if do |obj|
        obj == uri.to_s || (obj.is_a?(Hash) && obj[:uri] == uri)
      end

      if tracking == before
        tracking, errors = parse_tracking_object(uri)
        raise ArgumentErrors, errors.join("\n") if errors.any?

        tracking.remove_if do |obj|
          obj[:object] == tracking[:object] &&
            obj[:backend].to_sym == tracking[:backend].to_sym &&
            obj[:type].to_sym == tracking[:type].to_sym
        end
      end

      return if tracking == before

      client.api.send_state_event(room.id, ROOM_STATE_KEY, current)
    end

    event ROOM_STATE_KEY do
      logger.info "Received new room state for room #{room.state}"
      set_room_data(room, event[:content])
    end

    client do |cl|
      cl.on_invite_event.add_handler do |ev|
        logger.info "Invited to #{ev[:room_id]}."
        if config.backends.map { |_k, b| b.tracking.map(&:room_id) }.flatten.uniq.count > 50
          logger.info 'But tracking more than 50 object already, so ignoring.'
          break
        end
        client.join_room(ev[:room_id])
      end
    end

    def initialize(client, **settings)
      super client, **settings

      @room_data = {}
    end

    def api
      client.api
    end

    def config
      settings.config
    end

    def reload!
      @user ||= client.mxid

      client.rooms.each do |room|
        new_room_data = api.get_room_state(room.id, ROOM_STATE_KEY)
        set_room_data(room, new_room_data)
      rescue MatrixSdk::MatrixRequestError => e
        raise e unless e.code == 'M_NOT_FOUND'
      end

      true
    end

    # {
    #   "type": "m.text",
    #   // TODO
    #   "config": {
    #     "max_lines": -1,
    #     "max_chars": -1
    #   },
    #   "tracking": [
    #     "github:u/user",
    #     "github:g/group",
    #     "github:r/group/repo",
    #     "gitlab:u/user",
    #     "gitlab:g/group",
    #     "gitlab:r/group/repo",
    #     "gitlab://gitlab.example.com/u/user",
    #     "gitlab://gitlab.example.com/g/group",
    #     "gitlab://gitlab.example.com/r/group/repo",
    #     "gitea://token@gitea.example.com/u/user",
    #     "gitea://gitea.example.com/g/group",
    #     "gitea://gitea.example.com/r/group/repo",
    #
    #     "git+https://git.example.com/full/path/to/repo",
    #     "git+ssh://git@git.example.com/full/path/to/repo",
    #     "git://git.example.com/full/path/to/repo",
    #
    #     {
    #       "backend": "github",
    #       "type": "user", # stars
    #       "object": "<username>"
    #     },
    #     {
    #       "backend": "github",
    #       "type": "repository", # single repo
    #       "object": "<group>/<repository>"
    #     },
    #     {
    #       "backend": "github",
    #       "type": "group", # repos under a namespace
    #       "object": "<group>"
    #     },
    #     {
    #       "backend": "gitlab",
    #       "type": "repository",
    #       "object": "<group>/<repository>" # on gitlab.com
    #     },
    #     {
    #       "backend": "gitlab",
    #       "type": "repository",
    #       "object": "gitlab.example.com:<group>/<repository>",
    #       # TODO:
    #       "data": {
    #         "instance": "https://gitlab.internal.example.com/non-standard/path/api/graphql",
    #         "token": "token"
    #       }
    #     }
    #   ]
    # }
    def set_room_data(room, data)
      errors = []

      msgtype = data[:type]

      def_config = data[:config]
      logger.debug "Using #{def_config} as default values in #{room}" if def_config
      def_config ||= {}

      logger.debug "Setting messagetype to #{msgtype} in room #{room}" if msgtype
      errors << "Invalid message type #{msgtype.inspect}, must be m.text/m.notice" if msgtype && !%w[m.text m.notice].include?(msgtype)

      tracked = data[:tracking].map do |object|
        object, errs = parse_tracking_object(object)
        errors += errs
        next if errs.any?

        missing_keys = (%i[backend type object] - object.keys)
        if missing_keys.any?
          errors << "Tracking object #{object} is missing required keys: #{missing_keys.join ', '}"
          next
        end

        backend = config.backends[object[:backend].to_sym]
        if backend
          errors << "#{object} does not seem to be a valid git repo" if backend.is_a?(MatrixReleasetracker::Backends::Git) && !backend.valid?(object[:object])

          object.delete :backend
          Structs::Tracking.new_from_state(
            room_id: room.id.to_s,
            backend: backend,
            object: object[:object],
            type: object[:type],
            extradata: def_config.merge(JSON.parse(object[:data] || '{}', symbolize_names: true))
          )
        else
          errors << "Unknown backend #{object[:backend].to_sym.inspect} for #{object}"
        end
      end

      if errors.any?
        room.send_notice("Errors were found during parsing of state object;\n- #{errors.join("\n- ")}")
        logger.warn "Errors parsing new tracking state in room #{room};\n  - #{errors.join("\n  - ")}"
        return
      end

      data = @room_data[room.id.to_s] ||= {}
      apply_tracked(room, tracked)

      data[:tracked] = tracked
      if msgtype
        data[:type] = msgtype
      else
        data.delete :type
      end

      logger.info "Successfully updated tracking information for room #{room}"
    rescue StandardError => e
      room.send_notice("#{e.class} occured when applying new state; #{e}")

      err = "#{e.class}: #{e}\n#{e.backtrace.join("\n")}"
      logger.error "Failed to store room data for #{room}, #{err}"
    end

    def apply_tracked(room, tracked)
      tracked.each do |obj|
        if obj.tracked?
          obj.update_track
        else
          obj.add_track
        end
      end

      return unless @room_data.key? room.id.to_s

      existing = @room_data[room.id.to_s][:tracked] || []
      existing.each do |tracking|
        next if tracked.any? { |obj| obj.attributes.slice(:object, :backend, :type) == tracking.attributes.slice(:object, :backend, :type) }

        tracking.remove_track
      end
    end

    private

    def parse_tracking_object(object)
      if object.is_a? Hash
        return object, [] unless object.key? :uri

        data, err = parse_tracking_object(object.delete(:uri))
        data[:data].merge!(object.delete(:data)) if object.key? :data

        return data.merge(object), err
      end

      type_map = { 'g' => :group, 'r' => :repository, 'u' => :user }

      u = URI(object)
      data = if u.scheme =~ /^git(\+(https?|ssh))?$/
               {
                 backend: :git,
                 type: :repository,
                 object: u.to_s
               }.compact
             else
               if u.host
                 path = u.path[1..].split('/')
                 token = u.password || u.user
               else
                 path = u.opaque || u.path
                 token, path = path.split('@')
                 path, token = token, path if path.nil?
                 path = path.split('/')
                 token = token.split(':').last if token&.include? ':'
               end
               type = type_map[path.shift]

               errors = ["#{object} is not of a known type (g/r/u)"] if type.nil?

               path = path.join('/')
               path = "#{u.host}:#{path}" if u.host

               auth = {
                 token: token
               }.compact
               auth = nil if auth.empty?

               {
                 backend: u.scheme.to_sym,
                 type: type,
                 object: path,
                 data: auth
               }.compact
             end

      errors ||= []
      logger.debug "Parsed #{object.inspect} into #{data.inspect}"
      [data, errors]
    end
  end
end
