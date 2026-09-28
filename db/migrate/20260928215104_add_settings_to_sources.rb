class AddSettingsToSources < ActiveRecord::Migration[8.1]
  def change
    add_column :sources, :settings, :json, null: false, default: {}
    add_column :sources, :secret, :text
  end
end
