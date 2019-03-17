module MatrixReleasetracker
  module Structs
    User = Struct.new(:name, :room, :backend, :persistent_data) do
      def last_check
        return nil unless persistent_data && persistent_data.key?(:last_check)
        Time.parse((persistent_data || {})[:last_check])
      end

      def last_check=(check)
        (persistent_data || {})[:last_check] = check
      end
    end
  end
end
