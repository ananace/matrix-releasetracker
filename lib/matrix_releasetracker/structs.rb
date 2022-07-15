require 'pp'

module MatrixReleasetracker
  module Structs
    class Tracking
      include PP::ObjectMixin

      attr_accessor :id, :object, :backend, :room_id, :last_update, :next_update
      attr_reader :extradata

      def initialize(*args)
        if args.count == 1
          args = args[0]
          @id = args[:id]
          @object = args[:object]
          @backend = args[:backend]
          @room_id = args[:room_id]
          @last_update = args[:last_update]
          @next_update = args[:next_update]
          self.extradata = args[:extradata]
        else
          id = args[0]
          object = args[1]
          backend = args[2]
          # type = args[3]
          room_id = args[4]
          last_update = args[5]
          next_update = args[6]
          self.extradata = args[7]
        end
      end


      def self.new_from_state(type:, **state)
        case type.to_s
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
          extradata: extradata&.to_json
        }.compact
      end

      def attributes=(**data)
        data.each do |key, value|
          next if key.to_s == 'backend'

          self.send("#{key}=".to_sym, value) if instance_variables.include? "@#{key}".to_sym
        end
      end

      def type; raise NotImplementedError end

      def tracked?
        return false if backend.nil?
        return false unless backend.is_tracking? **attributes.slice(:id, :object, :type)
        true
      end

      def reload!
        raise 'No backend link' if backend.nil?
        raise 'Object is not tracked' unless tracked?

        if id
          result = backend.get_tracking_by_id(id)
        else
          result = backend.get_tracking(attributes.slice(:object, :type))
        end

        raise 'Tracking object not found in database' if result.nil?

        self.attributes = result

        self
      end

      
      def add_track
        raise 'Missing backend link' if backend.nil?
        raise 'Already tracked' if tracked?

        backend.add_tracking(**attributes)
      end

      def update_track
        raise 'Missing backend link' if backend.nil?
        raise 'Not tracked' unless tracked?

        backend.update_tracking(**attributes)
        reload!
      end

      def remove_track
        raise 'Missing backend link' if backend.nil?
        raise 'Not tracked' unless tracked?

        backend.remove_tracking(**attributes.slice(:id, :type, :object))
      end


      def last_check
        last_update
      end

      def last_check=(check)
        last_update = check
      end

      def extradata=(data)
        @extradata = JSON.load(data, symbolize_keys: true)
      end

      def repositories
        db = backend.database
        db[:repositories].inner_join(db[:tracked_repositories], repositories_id: :id)
                         .where(db[:tracked_repositories][:tracking_id] => id)
      end

      def to_s
        "#{type} #{object}"
      end

      def pretty_print_instance_variables
        instance_variables.sort.reject { |n| %i[@backend].include? n }
      end

      def pretty_print(pp)
        pp.pp_object(self)
      end

      alias inspect pretty_print_inspect
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
