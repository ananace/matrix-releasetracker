module MatrixReleasetracker
  module Structs
    class Tracking
      attr_accessor :id, :object, :backend, :room_id, :last_update, :next_update, :extradata

      def initialize(*args)
        if args.count == 1
          args = args[0]
          @id = args[:id]
          @object = args[:object]
          @backend = args[:backend]
          @room_id = args[:room_id]
          @last_update = args[:last_update]
          @next_update = args[:next_update]
          @extradata = args[:extradata]
        else
          id = args[0]
          object = args[1]
          backend = args[2]
          # type = args[3]
          room_id = args[4]
          last_update = args[5]
          next_update = args[6]
          extradata = args[7]
        end
      end

      def self.new_from_state(type:, **state)
        case type
        when 'user'
          klass = User
        when 'group'
          klass = Group
        when 'repository'
          klass = Repository
        end

        raise "Unknown type #{type.inspect}" if klass.nil?

        klass.new(**state)
      end

      def attributes
        {
          id: id,
          object: object,
          backend: backend,
          type: type,
          room_id: room_id,
          last_update: last_update,
          next_update: next_update,
          extradata: extradata
        }.compact
      end

      def type; raise NotImplementedError end

      def reload
        raise 'No backend link' if backend.nil?

        if id
          result = backend.get_tracking_by_id(id)
        else
          result = backend.get_tracking(attributes.slice(:object, :type))
        end
        
        raise 'Object is missing from database' if result.nil?

        result.each do |key, value|
          instance_variable_set("@#{key}", value) if instance_variable? "@#{key}"
        end
        self
      end

      def last_check
        last_update
      end

      def last_check=(check)
        last_update = check
      end

      def repositories
        db = backend.database
        db[:repositories].inner_join(db[:tracked_repositories], repositories_id: :id)
                         .where(db[:tracked_repositories][:tracking_id] => id)
      end
    end

    # Tracking a users stars
    class User < Tracking
      def type; :user end
    end

    # Tracking all repositories in a group/namespace
    class Group < Tracking
      def type; :group end
    end

    # Tracking a loose repository
    class Repository < Tracking
      def type; :repository end
    end

    RateLimit = Struct.new('RateLimit', :backend, :name, :requests, :remaining, :resets_at, :resets_in) do
      def near_limit
        remaining <= requests * 0.05
      end

      def used
        requests - remaining
      end

      def to_s
        "#{backend.name}/#{name}: Used #{used}/#{requests} (#{(used / requests) * 100}%), resets in #{resets_in.to_i} seconds"
      end
    end
  end
end
