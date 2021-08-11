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
      string :namespace, null: false
      string :version, null: false
      string :backend, null: false
      primary_key %i[namespace version backend], unique: true

      string :name, null: false
      string :commit_sha, null: true, default: nil
      datetime :publish_date, null: false
      string :release_notes, null: true
      string :url, null: false
      string :type, null: false

      # JSON
      string :extradata, null: true, default: nil
    end

    create_table(:tracking) do
      string :object, null: false
      string :backend, null: false
      string :type, null: false
      primary_key %i[object backend type], unique: true
      string :room_id, null: true, default: nil

      string :name, null: true, default: nil
      string :url, null: true, default: nil
      string :avatar, null: true, default: nil

      # JSON
      string :extradata, null: true, default: nil

      datetime :last_metadata_update, null: false, default: Sequel::CURRENT_TIMESTAMP
      datetime :next_metadata_update, null: true, default: nil
      datetime :last_update, null: false, default: Sequel::CURRENT_TIMESTAMP
      datetime :next_update, null: true, default: nil
    end
  end
end
