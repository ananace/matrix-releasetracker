module MatrixReleasetracker
  module Structs
    User = Struct.new(:name, :room, :backend, :persistent_data) do
      def last_check
        return nil if persistent_data.nil? || persistent_data.dig(:last_check).nil?
        return persistent_data[:last_check] if persistent_data[:last_check].is_a? Time
        persistent_data[:last_check] = Time.parse(persistent_data[:last_check])
      end

      def last_check=(check)
        persistent_data[:last_check] = check
      end
    end
  end
end
