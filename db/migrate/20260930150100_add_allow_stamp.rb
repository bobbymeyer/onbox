# Permission cards (a Claude run asking to use a tool) are answered with
# the Allow stamp; anything else denies.
class AddAllowStamp < ActiveRecord::Migration[8.1]
  def up
    return if select_value("SELECT 1 FROM stamps WHERE label = 'Allow' AND card_type = 'permission'")
    now = connection.quote(Time.current)
    execute <<~SQL
      INSERT INTO stamps (label, card_type, action, successors, use_count, requires_flip, created_at, updated_at)
      VALUES ('Allow', 'permission', '{"kind":"allow"}', '[]', 0, 0, #{now}, #{now})
    SQL
  end

  def down
    execute "DELETE FROM stamps WHERE label = 'Allow' AND card_type = 'permission'"
  end
end
