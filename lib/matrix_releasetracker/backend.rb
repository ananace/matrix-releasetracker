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

    def users
      @users ||= m_client.users.tap do |arr|
        arr.concat(config[:users].each { |u| u[:backend] = name.downcase }) unless config[:users].empty?
        config[:users].clear
      end.select { |u| u[:backend] == name.downcase }
    end

    def last_releases(_user)
      raise NotImplementedException
    end

    protected

    attr_reader :config, :m_client

    def persistent_repos
      (config[:tracked] ||= {})[:repos] ||= {}
    end

    def persistent_repo(reponame)
      persistent_repos[reponame] ||= {}
    end

    def ephemeral_repos
      @ephemeral_repos ||= begin
        file = File.join(ephemeral_storage, 'ephemeral_repos.yml')
        ret = Psych.load(File.read(file)) if File.exist? file
        ret ||= {}
        ret
      end
    end

    def ephemeral_repo(reponame)
      ephemeral_repos[reponame] ||= {}
    end

    def persistent_user(username)
      m_client.room_data(users.find { |u| u.name == username }[:room])
    end

    def ephemeral_users
      @ephemeral_users ||= begin
        file = File.join(ephemeral_storage, 'ephemeral_users.yml')
        ret = Psych.load(File.read(file)) if File.exist? file
        ret ||= {}
        ret
      end
    end

    def ephemeral_user(username)
      ephemeral_users[username] ||= {}
    end

    def ephemeral_storage
      @ephemeral_storage ||= begin
        ret = nil
        [ENV['XDG_CACHE_HOME'], File.join(ENV['HOME'], '.cache')].each do |dir|
          break if ret

          ret = dir if dir && (stat = File.stat(dir)) && stat.directory? && stat.writable?
        end
        ret ||= Dir.tmpdir

        File.join(ret, 'matrix-releasetracker') # Return tmpdir if everything fails
      end
    end
  end
end
