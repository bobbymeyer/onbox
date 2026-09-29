class CreateCredentials < ActiveRecord::Migration[8.1]
  def change
    create_table :credentials do |t|
      t.string :name, null: false
      t.text :secret, null: false

      t.timestamps
    end
    add_index :credentials, :name, unique: true
  end
end
