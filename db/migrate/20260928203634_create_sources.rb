class CreateSources < ActiveRecord::Migration[8.1]
  def change
    create_table :sources do |t|
      t.string :name, null: false
      t.string :kind, null: false, default: "generic"
      t.string :token, null: false
      t.string :card_type, null: false

      t.timestamps
    end
    add_index :sources, :token, unique: true
    add_index :sources, :name, unique: true
  end
end
