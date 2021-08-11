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

      post_load
    end

    def rate_limit; end

    def rate_limits
      [rate_limit].compact
    end

    def name
      self.class.name.split(':').last
    end

    def users
      return @users if @users

      tracking = database[:tracking]
      @users = tracking.where(type: 'user', backend: db_type).map do |t|
        Structs::User.new t[:object], t[:room_id], self, t[:last_update], t[:extradata]
      end

      # @repos = tracking.where(type: 'repo').map do |t|
      #   Structs::Repo.new t[:object], t[:room_id], t[:backend], t[:last_update], t[:extradata]
      # end

      @users
    end

    def add_user(name, **data)
      tracking = database[:tracking]
      u = tracking.insert(type: 'user', backend: db_type, object: name, **data)
      @users = tracking.where(type: 'user', backend: db_type).map do |t|
        Structs::User.new t[:object], t[:room_id], self, t[:last_update], t[:extradata]
      end
      u
    end

    def update_user(name, **data)
      tracking = database[:tracking]
      u = tracking.where(type: 'user', backend: db_type, object: name).update(data)
      @users = tracking.where(type: 'user', backend: db_type).map do |t|
        Structs::User.new t[:object], t[:room_id], self, t[:last_update], t[:extradata]
      end
      u
    end

    def last_releases(_user)
      raise NotImplementedException
    end

    protected

    attr_reader :config, :m_client

    def database
      config[:database]
    end

    def logger
      Logging.logger[self]
    end

    def db_type
      name.downcase
    end

    def post_load; end

    # def post_update
    #   # Cache ephemeral data between starts
    #   Dir.mkdir ephemeral_storage unless Dir.exist? ephemeral_storage
    #   File.write(File.join(ephemeral_storage, 'ephemeral_repos.yml'), @ephemeral_repos.to_yaml)
    #   File.write(File.join(ephemeral_storage, 'ephemeral_users.yml'), @ephemeral_users.to_yaml)
    # end

    def with_stagger(value)
      value + (Random.rand - 0.5) * (value / 2.0)
    end

    def find_tracking(name, **filters)
      database[:tracking].where(filters.merge(object: name, backend: db_type))
    end

    def find_releases(**filters)
      database[:releases].where(filters.merge(backend: db_type))
    end

    def old_persistent_repos
      puts "old_persistent_repos called by #{caller_locations(1,1)[0]}"
      (config[:tracked] ||= {})[:repos] ||= {}
    end

    def persistent_repo(reponame)
      database[:repository][reponame] ||= {}
    end

    def old_ephemeral_repos
      puts "old_ephemeral_repos called by #{caller_locations(1,1)[0]}"
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
      user&.extradata
    end

    def old_ephemeral_users
      puts "old_ephemeral_users called by #{caller_locations(1,1)[0]}"
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
