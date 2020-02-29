module MatrixReleasetracker
  class Backend
    RateLimit = Struct.new('RateLimit', :backend, :name, :requests, :remaining, :resets_at, :resets_in) do
      def near_limit
        remaining <= requests * 0.05
      end

      def to_s
        "#{backend.name}/#{name}: Used #{requests - remaining}/#{requests} (#{(remaining / requests) * 100}%), resets in #{resets_in.to_i} seconds"
      end
    end

    def initialize(config, client)
      @config = config
      @m_client = client

      db = config.database

      post_load
    end

    def logger
      Logging.logger[self]
    end

    def rate_limit; end

    def rate_limits
      [rate_limit].compact
    end

    def post_load; end

    def post_update
      # Cache ephemeral data between starts
      Dir.mkdir ephemeral_storage unless Dir.exist? ephemeral_storage
      File.write(File.join(ephemeral_storage, 'ephemeral_repos.yml'), @ephemeral_repos.to_yaml)
      File.write(File.join(ephemeral_storage, 'ephemeral_users.yml'), @ephemeral_users.to_yaml)
    end

    def name
      self.class.name.split(':').last
    end

    def db_type
      name.downcase.to_sym
    end

    def users
      return @users if @users

      legacy_users ||= m_client.users.tap do |arr|
        arr.concat(config[:users].each { |u| u[:backend] = name.downcase }) unless config[:users].empty?
        config[:users].clear
      end.select { |u| u[:backend] == name.downcase }
      tracking = config.database[:tracking].where(backend: :github)

      if legacy_users.any?
        legacy_users.each do |u|
          tracking.insert_conflict(:update).insert(
            object: u.name,
            backend: u.backend,
            type: :user,

            room_id: u.room,
            last_update: u.last_check
          )
        end
        m_client.users.clear
      end
      
      @users = tracking.where(type: :user).map do |t|
        Structs::User.new t[:object], t[:room_id], t[:backend], t[:last_update], t[:extradata]
      end

      # @repos = tracking.where(type: 'repo').map do |t|
      #   Structs::Repo.new t[:object], t[:room_id], t[:backend], t[:last_update], t[:extradata]
      # end

      @users
    end

    def last_releases(_user)
      raise NotImplementedException
    end

    protected

    attr_reader :config, :m_client

    def database
      config.database
    end

    def find_tracking(name, type:)
      database[:tracking][object: name, backend: db_type, type: type]
    end

    def old_persistent_repos
      (config[:tracked] ||= {})[:repos] ||= {}
    end

    def persistent_repo(reponame)
      config.database[:repository][reponame] ||= {}
    end

    def old_ephemeral_repos
      @ephemeral_repos ||= begin
        file = File.join(ephemeral_storage, 'ephemeral_repos.yml')
        ret = Psych.load(File.read(file)) if File.exist? file
        ret ||= {}
        ret
      end
    end

    def ephemeral_repo(reponame)
      old_ephemeral_repos[reponame] ||= {}
    end

    def persistent_user(username)
      user = users.find { |u| u.name == username }

      legacy = m_client.room_data(user.room)
      if legacy.any?
        user.extradata.merge! legacy
        m_client.clear_room_data user.room
      end

      return user.extradata if user
    end

    def old_ephemeral_users
      @ephemeral_users ||= begin
        file = File.join(ephemeral_storage, 'ephemeral_users.yml')
        ret = Psych.load(File.read(file)) if File.exist? file
        ret ||= {}
        ret
      end
    end

    def ephemeral_user(username)
      old_ephemeral_users[username] ||= {}
    end

    def ephemeral_storage
      @ephemeral_storage ||= begin
        ret = nil
        [ENV['XDG_CACHE_HOME'], File.join(ENV['HOME'], '.cache')].each do |dir|
          break if ret

          ret = dir if dir && (stat = File.stat(dir)) && stat.directory? && stat.writable?
        end
        ret ||= Dir.tmpdir

        File.join(ret, 'matrix-releasetracker')
      end
    end
  end
end
