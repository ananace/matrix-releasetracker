# frozen_string_literal: true

require 'base64'
require 'cgi'
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
      @client = MatrixSdk::Client.new configuration.delete(:hs_url), **configuration.merge(client_cache: :some)
      @api = client.api
      @data = {}
      @room_data = {}

      client.on_invite_event.add_handler do |ev|
        logger.info "Invited to #{ev[:room_id]}."
        if config.backends.map { |_k, b| b.tracking.map(&:room_id) }.flatten.uniq.count > 50
          logger.info 'But tracking more than 50 object already, so ignoring.'
          break
        end
        client.join_room(ev[:room_id])
      end

      client.on_event.add_handler('m.room.message') do |ev|
        room_id = ev.room_id.to_s
        message = ev

        break unless message[:content][:body].start_with? '!github '
        break unless config.backends.keys.include? :github

        logger.info "#{message[:sender]} in #{room_id}: #{message[:content][:body]}"

        users = api.get_room_members(room_id)[:chunk].select { |c| c[:content][:membership] == 'join' }
        if users.count > 2
          api.send_notice(room_id.to_s, 'Not a 1:1 room, ignoring request.')
          break
        end

        if config.client.room_data.key? room_id
          api.send_notice(room_id.to_s, 'This room uses state tracking object, ignoring request.')
          break
        end

        backend = config.backends[:github]
        existing = backend.tracking.find { |u| u.room_id == room_id.to_s }

        gh_name = message[:content][:body][8..].downcase
        break if existing && existing.object == gh_name && existing.type == :user

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

    def post_release(obj, rel, msgtype: 'm.notice')
      api.send_message_event(
        obj.room_id,
        'm.room.message',
        {
          msgtype: msgtype,
          body: rel.to_s(:plain, max_lines: 0),
          formatted_body: rel.to_s(:html),
          format: 'org.matrix.custom.html',

          'org.matrix.msc1767.message': [
            {
              mimetype: 'text/plain',
              body: rel.to_s(:plain, max_lines: 0)
            },
            {
              mimetype: 'text/markdown',
              body: rel.to_s(:markdown, max_lines: rel.max_lines / 2)
            },
            {
              mimetype: 'text/html',
              body: rel.to_s(:html)
            }
          ]
        },
        txn_id: Digest::SHA2.hexdigest("#{obj.room_id}#{rel.stable_hash}")
      )
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
    #     "github:r/group/repo?allow=tag",
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
    def set_room_data(room_id, data)
      room_id = room_id.id.to_s if room_id.is_a? MatrixSdk::Room
      room_id = room_id.to_s if room_id.is_a? MatrixSdk::MXID

      errors = []

      msgtype = data[:type]

      def_config = data[:config]
      logger.debug "Using #{def_config} as default values in #{room_id}" if def_config
      def_config ||= {}

      logger.debug "Setting messagetype to #{msgtype} in room #{room_id}" if msgtype
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
            room_id: room_id,
            backend: backend,
            object: object[:object],
            type: object[:type],
            extradata: def_config.merge(object[:data] || {})
          )
        else
          errors << "Unknown backend #{object[:backend].to_sym.inspect} for #{object}"
        end
      end

      if errors.any?
        client.ensure_room(room_id).send_notice("Errors were found during parsing of state object;\n- #{errors.join("\n- ")}")
        logger.warn "Errors parsing new tracking state in room #{room_id};\n  - #{errors.join("\n  - ")}"
        return
      end

      data = @room_data[room_id] ||= {}
      apply_tracked(room_id, tracked)

      data[:tracked] = tracked
      if msgtype
        data[:type] = msgtype
      else
        data.delete :type
      end

      logger.info "Successfully updated tracking information for room #{room_id}"
    rescue StandardError => e
      client.ensure_room(room_id).send_notice("#{e.class} occured when applying new state; #{e}")

      err = "#{e.class}: #{e}\n#{e.backtrace.join("\n")}"
      logger.error "Failed to store room data for #{room_id}, #{err}"
    end

    def apply_tracked(room_id, tracked)
      tracked.each do |obj|
        if obj.tracked?
          obj.update_track
        else
          obj.add_track
        end
      end

      return unless @room_data.key? room_id

      existing = @room_data[room_id][:tracked] || []
      existing.each do |tracking|
        next if tracked.any? { |obj| obj.attributes.slice(:object, :backend, :type) == tracking.attributes.slice(:object, :backend, :type) }

        tracking.remove_track
      end
    end

    def save!
      attempts = 5
      loop do
        to_save = @data
        api.set_account_data(@user, ACCOUNT_DATA_KEY, to_save)

        return true
      rescue StandardError => e
        raise if attempts <= 0

        attempts -= 1

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

    def parse_tracking_object(object)
      if object.is_a? Hash
        return object, [] unless object.key? :uri

        data, err = parse_tracking_object(object.delete(:uri))
        data[:data].merge!(object.delete(:data)) if object.key? :data

        return data.merge(object), err
      end

      type_map = { 'g' => :group, 'r' => :repository, 'u' => :user }

      errors = []
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
                 path, query = path.split('?')

                 token, path = path.split('@')
                 path, token = token, path if path.nil?
                 path = path.split('/')
                 token = token.split(':').last if token&.include? ':'
               end
               type = type_map[path.shift]

               errors << "#{object} is not of a known type (g/r/u)" if type.nil?

               path = path.join('/')
               path = "#{u.host}:#{path}" if u.host

               data = {}
               data[:token] = token if token
               if query || u.query
                 query_params = CGI.parse(query || u.query)
                 data[:allow] = query_params['allow'] if query_params.key? 'allow'
                 data[:allow].each do |allow|
                   errors << "#{allow} is not a known type (lightweight_tag/tag/release)" unless %w[lightweight_tag tag release].include?(allow)
                 end
               end
               data.compact!
               data = nil if data.empty?

               {
                 backend: u.scheme.to_sym,
                 type: type,
                 object: path,
                 data: data
               }.compact
             end

      errors ||= []
      logger.debug "Parsed #{object.inspect} into #{data.inspect}"
      [data, errors]
    end

    def reload_with_sync
      api.sync(timeout: 5.0, set_presence: :offline, filter: ACCOUNT_DATA_FILTER.to_json).tap do |data|
        data = data[:account_data][:events].find { |ev| ev[:type] == ACCOUNT_DATA_KEY }

        @data = (data[:content] if data) || {}
      end
    end

    def reload_with_get
      @data = api.request(:get, :client_r0, "/user/#{@user}/account_data/#{ACCOUNT_DATA_KEY}")
    rescue MatrixSdk::MatrixNotFoundError
      # No account data stored
    rescue MatrixSdk::MatrixRequestError => e
      if e.httpstatus == 400
        @use_sync = true
        return reload_with_sync
      end

      logger.error "#{e.class} occurred when reading account data: #{e}"

      raise e
    end
  end
end
