class CreateCards < ActiveRecord::Migration[8.1]
  def change
    create_table :cards do |t|
      t.references :source, foreign_key: true
      t.string :key
      t.string :card_type, null: false, default: "generic"
      t.string :project
      t.string :summary
      t.string :ask, null: false, default: "acknowledge"
      t.text :proposed_action
      t.json :payload, null: false, default: {}
      t.string :state, null: false, default: "live"
      t.integer :position, null: false, default: 0
      t.datetime :hold_until
      t.string :hold_event
      t.references :parent_card, foreign_key: { to_table: :cards }
      t.references :blocked_by, foreign_key: { to_table: :cards }
      t.datetime :handled_at
      t.string :handled_with
      t.datetime :digested_at
      t.integer :flip_count, null: false, default: 0

      t.timestamps
    end
    add_index :cards, [ :state, :position ]
    add_index :cards, :key
  end
end
