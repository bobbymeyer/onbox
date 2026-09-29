module Intake
  # "Thu 2 Oct, 15:00–16:00", "Fri 3 Oct (all day)".
  module When
    def self.describe(payload)
      starts = Time.zone.parse(payload["start"].to_s) or return
      ends = Time.zone.parse(payload["end"].to_s)
      day = starts.strftime("%a %-d %b")
      text = payload["all_day"] ? "#{day} (all day)" : "#{day}, #{starts.strftime("%H:%M")}#{"–#{ends.strftime("%H:%M")}" if ends}"
      was = Time.zone.parse(payload["was"].to_s) if payload["was"]
      was ? "#{text} (was #{was.strftime("%a %-d %b, %H:%M")})" : text
    end
  end
end
