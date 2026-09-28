class RemovePositionDefaultFromCards < ActiveRecord::Migration[8.1]
  def change
    change_column_default :cards, :position, from: 0, to: nil
  end
end
