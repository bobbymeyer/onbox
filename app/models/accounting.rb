# One periodic accounting (shown as a "digest"): what the secretary held and
# why, what it put in front, what came and went. Bobby only ever sees the one
# card it chose, so its judgment has to stay legible.
class Accounting < ApplicationRecord
  PERIODS = {
    "hourly" => { step: 1.hour, beginning: :beginning_of_hour, rolls_up: nil },
    "daily" => { step: 1.day, beginning: :beginning_of_day, rolls_up: "hourly" },
    "weekly" => { step: 1.week, beginning: :beginning_of_week, rolls_up: "daily" },
    "monthly" => { step: 1.month, beginning: :beginning_of_month, rolls_up: "weekly" }
  }.freeze

  belongs_to :card, optional: true

  validates :period, inclusion: { in: PERIODS.keys }
  validates :body, presence: true

  scope :newest_first, -> { order(ends_at: :desc, id: :desc) }

  # The last completed window for a period, in Time.zone: [starts, ends).
  def self.window(period, now = Time.current)
    config = PERIODS.fetch(period)
    ends = now.public_send(config[:beginning])
    [ (ends - config[:step]).public_send(config[:beginning]), ends ]
  end

  # The shorter digests this one is built from.
  def self.within(period, starts, ends)
    child = PERIODS.fetch(period)[:rolls_up]
    child ? where(period: child, starts_at: starts...ends).order(:starts_at) : none
  end

  def title
    label =
      case period
      when "hourly" then "#{starts_at.strftime("%a %-d %b, %H:%M")}–#{ends_at.strftime("%H:%M")}"
      when "daily" then starts_at.strftime("%a %-d %b")
      when "weekly" then "week of #{starts_at.strftime("%-d %b")}"
      when "monthly" then starts_at.strftime("%B %Y")
      end
    "#{period.capitalize} digest · #{label}"
  end
end
