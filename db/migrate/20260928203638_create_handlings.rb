class CreateHandlings < ActiveRecord::Migration[8.1]
  def change
    create_table :handlings do |t|
      t.references :card, null: false, foreign_key: true
      t.references :stamp, foreign_key: true
      t.string :verb, null: false
      t.text :text

      t.timestamps
    end
    add_index :handlings, :verb
  end
end
