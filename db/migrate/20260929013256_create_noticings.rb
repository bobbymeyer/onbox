class CreateNoticings < ActiveRecord::Migration[8.1]
  def change
    create_table :noticings do |t|
      t.string :card_type, null: false
      t.string :phrase, null: false
      t.text :example, null: false
      t.integer :count, null: false
      t.references :card, foreign_key: { on_delete: :nullify }
      t.references :stamp, foreign_key: { on_delete: :nullify }

      t.timestamps
    end
    add_index :noticings, [ :card_type, :phrase ], unique: true
  end
end
