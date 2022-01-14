require 'sequel'

module MatrixReleasetracker
  class Database
    DEFAULT_MEDIA_TIMEOUT = 48 * 60 * 60

    attr_reader :adapter

    def initialize(connection_string, debug: false)
      @adapter = Sequel.connect(connection_string)
      adapter.sql_log_level = :debug
      adapter.loggers << Logging.logger[self] if debug

      migrate
    end

    # Pass table accesses through
    def [](key); adapter[key]; end

    def migrate
      Sequel.extension :migration
      Sequel::Migrator.run(adapter, File.join(__dir__, 'migrations'))
    end
  end
end
