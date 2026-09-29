class CreateAccountings < ActiveRecord::Migration[8.1]
  def change
    create_table :accountings do |t|
      t.string :period, null: false
      t.datetime :starts_at, null: false
      t.datetime :ends_at, null: false
      t.text :body, null: false
      t.json :stats, null: false, default: {}
      t.references :card, foreign_key: { on_delete: :nullify }

      t.timestamps
    end
    add_index :accountings, [ :period, :starts_at ], unique: true
  end
end
