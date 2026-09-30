class CreateClaudeRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :claude_runs do |t|
      t.references :card, foreign_key: { on_delete: :nullify }
      t.references :result_card, foreign_key: { to_table: :cards, on_delete: :nullify }
      t.string :session_id
      t.string :cwd, null: false
      t.text :prompt, null: false
      t.integer :pid
      t.string :state, null: false, default: "running"
      t.integer :exit_status
      t.float :cost_usd
      t.text :error
      t.datetime :finished_at
      t.timestamps
    end
    add_index :claude_runs, :state
  end
end
