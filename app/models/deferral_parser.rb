# The cheap, deterministic half of resolving "later": common phrases map to a
# time without an LLM round trip. Anything it cannot read goes to the secretary.
module DeferralParser
  MORNING = 9
  AFTERNOON = 14
  EVENING = 18
  WEEKDAYS = %w[sunday monday tuesday wednesday thursday friday saturday].freeze
  UNITS = { "m" => :minutes, "min" => :minutes, "mins" => :minutes, "minute" => :minutes, "minutes" => :minutes,
            "h" => :hours, "hr" => :hours, "hrs" => :hours, "hour" => :hours, "hours" => :hours,
            "d" => :days, "day" => :days, "days" => :days,
            "w" => :weeks, "week" => :weeks, "weeks" => :weeks }.freeze

  module_function

  def parse(text, now: Time.current)
    s = text.to_s.downcase.strip.sub(/\A(in|after|until|till|at)\s+/, "")
    return if s.empty?

    if (m = s.match(/\A(an?|\d+)\s*(#{UNITS.keys.join("|")})\z/))
      n = m[1].start_with?("a") ? 1 : m[1].to_i
      return now + n.public_send(UNITS[m[2]])
    end

    case s
    when "later", "later today" then now + 3.hours
    when "this afternoon", "afternoon" then at(now, AFTERNOON)
    when "tonight", "this evening", "evening" then now.hour >= EVENING ? now + 2.hours : now.change(hour: EVENING)
    when "tomorrow", "tomorrow morning" then (now + 1.day).change(hour: MORNING)
    when "tomorrow afternoon" then (now + 1.day).change(hour: AFTERNOON)
    when "tomorrow evening", "tomorrow night" then (now + 1.day).change(hour: EVENING)
    when "next week" then (now.next_week(:monday)).change(hour: MORNING)
    when "weekend", "this weekend" then next_weekday(now, "saturday").change(hour: MORNING)
    when *WEEKDAYS then next_weekday(now, s).change(hour: MORNING)
    end
  end

  # Today at the hour if it is still ahead, otherwise tomorrow at that hour.
  def at(now, hour)
    t = now.change(hour: hour)
    t > now ? t : t + 1.day
  end

  def next_weekday(now, name)
    days = (WEEKDAYS.index(name) - now.wday) % 7
    now + (days.zero? ? 7 : days).days
  end
end
