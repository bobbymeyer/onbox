class CreateDirectives < ActiveRecord::Migration[8.1]
  def change
    create_table :directives do |t|
      t.text :text, null: false

      t.timestamps
    end
  end
end
