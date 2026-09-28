# A standing instruction from Bobby to the secretary ("always defer receipts
# till evening"). Every digest reads them.
class Directive < ApplicationRecord
  validates :text, presence: true

  scope :in_order, -> { order(:created_at) }

  def self.texts
    in_order.pluck(:id, :text).map { |id, text| "[#{id}] #{text}" }
  end
end
