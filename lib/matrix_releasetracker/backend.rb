module MatrixReleasetracker
  class Backend
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
      @users ||= database[:tracking].where(type: 'user', backend: db_type).map do |t|
        Structs::User.new t.merge(backend: self)
      end
    end

    def add_user(name, **data)
      tracking = database[:tracking]
      u = tracking.insert(type: 'user', backend: db_type, object: name, **data)
      @users = nil

      u
    end

    def update_user(name, **data)
      u = find_tracking(name, type: 'user').update(**data)
      @users = nil

      u
    end

    def remove_user(name)
      find_tracking(name, type: 'user').delete
      @users = nil
    end


    def get_tracking(object:, type:, **attributes)
      database[:tracking].where(object: object, type: type.to_s, **attributes).first
    end

    def get_tracking_by_id(id)
      database[:tracking].where(id: id, backend: db_type).first
    end


    def get_all_tracked_by_type(type, room_id: nil)
      res = if room_id
              database[:tracking].where(type: type.to_s, backend: db_type, room_id: room_id)
            else
              database[:tracking].where(type: type.to_s, backend: db_type)
            end

      res.map { |obj| Structs::Tracking.new_from_state(**obj) }
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

    def find_repository(name, **filters)
      database[:repositories].where(filters.merge(slug: name, backend: db_type))
    end

    def find_tracking(name, **filters)
      raise 'Using old :type param' if filters[:type] == 'repository'

      database[:tracking].where(filters.merge(object: name, backend: db_type))
    end

    def find_releases(**filters)
      database[:releases].where(filters)
    end
  end
end
