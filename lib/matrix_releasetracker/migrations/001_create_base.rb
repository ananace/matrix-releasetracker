# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:meta) do
      string :key, null: false, primary_key: true
      string :value, null: true
    end

    create_table(:media) do
      string :original_url, null: false, primary_key: true
      string :mxc_url, null: false

      string :etag, null: true, default: nil
      string :last_modified, null: true, default: nil
      string :sha256, null: true, default: nil

      datetime :timestamp, null: false, default: Sequel::CURRENT_TIMESTAMP
    end

    create_table(:releases) do
      primary_key :id
      string :version, null: false
      foreign_key :repositories_id, :repositories, on_delete: :cascade, on_update: :cascade
      index %i[version repositories_id], unique: true

      string :name, null: false
      string :commit_sha, null: true, default: nil
      datetime :publish_date, null: false
      string :release_notes, null: true
      string :url, null: false
      string :type, null: false

      # JSON
      string :extradata, null: true, default: nil
    end

    create_table(:repositories) do
      primary_key :id
      string :slug, null: false
      string :backend, null: false
      index %i[slug backend], unique: true

      string :name, null: true, default: nil
      string :url, null: true, default: nil
      string :avatar, null: true, default: nil

      datetime :last_metadata_update, null: false, default: Sequel::CURRENT_TIMESTAMP
      datetime :next_metadata_update, null: true, default: nil
      datetime :last_update, null: false, default: Sequel::CURRENT_TIMESTAMP
      datetime :next_update, null: true, default: nil

      # JSON
      string :extradata, null: true, default: nil
    end

    create_table(:tracking) do
      primary_key :id

      string :object, null: false
      string :backend, null: false
      string :type, null: false
      string :room_id, null: false
      index %i[object backend type room_id], unique: true

      datetime :last_update, null: false, default: Sequel::CURRENT_TIMESTAMP
      datetime :next_update, null: true, default: nil

      # JSON
      string :extradata, null: true, default: nil
    end

    create_table(:tracked_repositories) do
      foreign_key :tracking_id, :tracking, on_delete: :cascade, on_update: :cascade
      foreign_key :repositories_id, :repositories, on_delete: :cascade, on_update: :cascade
      index %i[tracking_id repositories_id], primary_key: true, unique: true
    end

    create_table(:latest_releases) do
      foreign_key :tracking_id, :tracking, on_delete: :cascade, on_update: :cascade
      foreign_key :repositories_id, :repositories, on_delete: :cascade, on_update: :cascade
      index %i[tracking_id repositories_id], unique: true

      foreign_key :releases_id, :releases, on_delete: :cascade, on_update: :cascade
    end
  end
end
