module MatrixReleasetracker
  class Database
    MIGRATE_VERSION = 1
    DEFAULT_MEDIA_TIMEOUT = 48 * 60 * 60

    class Meta < Sequel::Model
    end

    attr_reader :adapter

    def initialize(connection_string)
      @adapter = Sequel.connect(connection_string)

      migrate
    end

    # Pass table accesses through
    def [](key); adapter[key]; end

    def migration_version
      ((adapter[:meta].where(key: 'migration').first || {})[:value] || '0').to_i
    end

    def migrate
      adapter.create_table?(:meta) do
        string :key, null: false, primary_key: true
        string :value, null: true
      end

      if migration_version < 1
        adapter.create_table?(:media) do
          string :original_url, null: false, primary_key: true
          string :mxc_url, null: false

          string :etag, null: true, default: nil
          string :last_modified, null: true, default: nil
          string :sha256, null: true, default: nil

          datetime :timestamp, null: false, default: Sequel::CURRENT_TIMESTAMP
        end

        adapter.create_table?(:releases) do
          string :namespace, null: false
          string :version, null: false
          string :backend, null: false
          primary_key %i[namespace version backend], unique: true

          string :reponame, null: true, default: nil
          string :name, null: false
          string :commit_sha, null: true, default: nil
          datetime :publish_date, null: false
          string :release_notes, null: false
          string :repo_url, null: false
          string :release_url, null: false
          string :avatar_url, null: false
          string :release_type, null: false
        end

        adapter.create_table?(:tracking) do
          string :object, null: false
          string :backend, null: false
          string :type, null: false
          primary_key %i[object backend type], unique: true
          string :room_id, null: true, default: nil

          string :extradata, null: true, default: nil
          datetime :last_update, null: false, default: Sequel::CURRENT_TIMESTAMP
          datetime :next_update, null: true, default: nil
        end
      end

      adapter[:meta].insert_conflict(:update).insert 'migration', MIGRATE_VERSION
    end
  end
end
