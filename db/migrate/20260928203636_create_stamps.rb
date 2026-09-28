class CreateStamps < ActiveRecord::Migration[8.1]
  def change
    create_table :stamps do |t|
      t.string :label, null: false
      t.string :card_type, null: false, default: "any"
      t.json :action, null: false, default: {}
      t.text :template
      t.json :successors, null: false, default: []
      t.integer :use_count, null: false, default: 0
      t.boolean :requires_flip, null: false, default: false

      t.timestamps
    end
    add_index :stamps, :card_type
  end
end
