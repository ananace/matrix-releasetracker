# frozen_string_literal: true

# rubocop:disable Metrics/BlockLength
Sequel.migration do
  change do
    create_table(:meta) do
      String :key, null: false, primary_key: true
      String :value, null: true
    end

    create_table(:media) do
      String :original_url, null: false, primary_key: true
      String :mxc_url, null: false

      String :etag, null: true, default: nil
      String :last_modified, null: true, default: nil
      String :sha256, null: true, default: nil

      Time :timestamp, null: false, default: Sequel::CURRENT_TIMESTAMP
    end

    create_table(:repositories) do
      primary_key :id
      String :slug, null: false
      String :backend, null: false
      index %i[slug backend], unique: true

      String :name, null: true, default: nil
      String :url, null: true, default: nil
      String :avatar, null: true, default: nil

      Time :last_metadata_update, null: false, default: Sequel::CURRENT_TIMESTAMP
      Time :next_metadata_update, null: true, default: nil
      Time :last_update, null: false, default: Sequel::CURRENT_TIMESTAMP
      Time :next_update, null: true, default: nil

      # JSON
      String :extradata, null: true, default: nil
    end

    create_table(:releases) do
      primary_key :id
      String :version, null: false
      foreign_key :repositories_id, :repositories, on_delete: :cascade, on_update: :cascade
      index %i[version repositories_id], unique: true

      String :name, null: false
      String :commit_sha, null: true, default: nil
      Time :publish_date, null: false
      String :release_notes, null: true, text: true
      String :url, null: false
      String :type, null: false

      # JSON
      String :extradata, null: true, default: nil
    end

    create_table(:tracking) do
      primary_key :id

      String :object, null: false
      String :backend, null: false
      String :type, null: false
      String :room_id, null: false
      index %i[object backend type room_id], unique: true

      Time :last_update, null: false, default: Sequel::CURRENT_TIMESTAMP
      Time :next_update, null: true, default: nil

      # JSON
      String :extradata, null: true, default: nil
    end

    create_table(:tracked_repositories) do
      foreign_key :tracking_id, :tracking, on_delete: :cascade, on_update: :cascade
      foreign_key :repositories_id, :repositories, on_delete: :cascade, on_update: :cascade
      index %i[tracking_id repositories_id], unique: true
    end

    create_table(:latest_releases) do
      foreign_key :tracking_id, :tracking, on_delete: :cascade, on_update: :cascade
      foreign_key :repositories_id, :repositories, on_delete: :cascade, on_update: :cascade
      index %i[tracking_id repositories_id], unique: true

      foreign_key :releases_id, :releases, on_delete: :cascade, on_update: :cascade
    end
  end
end
# rubocop:enable Metrics/BlockLength
