class CreateSecretaryMessages < ActiveRecord::Migration[8.1]
  def change
    create_table :secretary_messages do |t|
      t.string :role, null: false
      t.text :body, null: false
      t.json :operations, null: false, default: []

      t.timestamps
    end
  end
end
