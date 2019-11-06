module MatrixReleasetracker
  module Structs
    User = Struct.new(:name, :room, :backend, :last_update, :extradata) do
      def last_check
        last_update
      end

      def last_check=(check)
        last_update = check
      end
    end
  end
end
