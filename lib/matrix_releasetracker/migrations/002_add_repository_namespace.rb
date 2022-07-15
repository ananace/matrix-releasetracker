# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:repositories) do
      add_column :namespace, :string, null: true, default: nil
    end
  end
end
