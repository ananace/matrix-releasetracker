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
        }
      end

      def type; raise NotImplementedError end

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
  end
end
