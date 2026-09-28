class CreateTriggers < ActiveRecord::Migration[8.1]
  def change
    create_table :triggers do |t|
      t.references :card, null: false, foreign_key: true
      t.string :kind, null: false, default: "time"
      t.datetime :fires_at
      t.string :event_key
      t.datetime :fired_at

      t.timestamps
    end
    add_index :triggers, [ :kind, :fired_at, :fires_at ]
    add_index :triggers, :event_key
  end
end
