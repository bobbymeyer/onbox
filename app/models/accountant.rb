# Writes the secretary's periodic accounting. Runs every hour and writes each
# period whose window just closed: hourly, then daily, weekly and monthly,
# each longer one built from the shorter ones inside it plus the log.
module Accountant
  CARD_PERIODS = ENV.fetch("STACK_DIGEST_CARDS", "daily,weekly,monthly").split(",").map(&:strip).freeze
  MORNING = ENV.fetch("STACK_DIGEST_HOUR", 8).to_i
  EVENING = 22

  SYSTEM = <<~PROMPT.freeze
    You are the secretary for The Stack, Bobby's single-user queue of index
    cards. He only ever sees the one card you put in front of him, so you owe
    him a periodic accounting that keeps your judgment legible.

    From the log for the period, write a short digest:
    - What you held and why, and what you put in front on your own judgment.
    - What arrived and what he handled, in aggregate, not card by card.
    - Anything that looks like drift: cards going stale, repeated deferrals of
      the same thing, a pile-up from one source, a high flip rate (fronts that
      weren't enough), standing instructions that may no longer fit.
    Use only the data given. Plain, terse sentences; a few bullets at most.
    Say plainly when nothing needs his attention.

    headline: one line, at most 90 characters, the single most useful thing to know.
    body: the digest itself.
  PROMPT

  SCHEMA = {
    type: "object",
    properties: { headline: { type: "string" }, body: { type: "string" } },
    required: %w[headline body],
    additionalProperties: false
  }.freeze

  LENGTH = { "hourly" => "two or three sentences", "daily" => "under 120 words",
             "weekly" => "under 200 words", "monthly" => "under 250 words" }.freeze

  module_function

  # Writes every period whose last window has no digest yet. Returns the new ones.
  def run(now = Time.current)
    Accounting::PERIODS.keys.filter_map { |period| account(period, now) }
  end

  def account(period, now = Time.current)
    starts, ends = Accounting.window(period, now)
    return if Accounting.exists?(period: period, starts_at: starts)

    stats = Ledger.for(starts...ends)
    children = Accounting.within(period, starts, ends).to_a
    return if skip?(period, stats, children)

    written = write(period, starts, ends, stats, children)
    accounting = Accounting.create!(
      period: period, starts_at: starts, ends_at: ends, stats: stats,
      body: written&.dig("body").presence || plain(stats)
    )
    deliver(accounting, written&.dig("headline"), now) if CARD_PERIODS.include?(period)
    accounting
  rescue ActiveRecord::RecordNotUnique
    nil
  end

  # A quiet hour costs nothing. Longer periods still report while cards wait.
  def skip?(period, stats, children)
    return false if Ledger.active?(stats) || children.any?
    period == "hourly" || stats["live_now"].zero?
  end

  def write(period, starts, ends, stats, children)
    return unless Secretary.enabled?

    Secretary.new.structured(
      system: SYSTEM,
      schema: SCHEMA,
      effort: period == "hourly" ? :low : :medium,
      user: <<~LOG
        Period: #{period}, #{starts.iso8601} to #{ends.iso8601} (#{Time.zone.name}). Length: #{LENGTH[period]}.

        Log:
        #{JSON.pretty_generate(stats)}

        Standing instructions: #{Directive.texts.presence&.join("; ") || "none"}
        #{children.any? ? "\nDigests within this period:\n" + children.map { |c| "- #{c.title}: #{c.body}" }.join("\n") : ""}
      LOG
    )
  end

  # Without the model, the numbers alone.
  def plain(stats)
    lines = []
    lines << "Arrived: #{stats["arrived"].map { |k, v| "#{v} from #{k}" }.join(", ")}." if stats["arrived"].any?
    lines << "Handled #{stats["handled_count"]}#{" (#{stats["handled"].map { |k, v| "#{v} #{k}" }.join(", ")})" if stats["handled"].any?}." if stats["handled_count"].positive?
    stats["secretary"].each { |entry| lines << "I #{entry.sub(/\A(\w)/) { $1.downcase }}" }
    lines << "Holding #{stats["held_now"].size}: #{stats["held_now"].first(5).join("; ")}." if stats["held_now"].any?
    lines << "#{stats["live_now"]} live, #{stats["stale_now"]} older than a day#{"; oldest: #{stats["oldest"]}" if stats["oldest"]}." if stats["live_now"].positive?
    lines << "Flipped #{stats["flips"]} time(s)." if stats["flips"].positive?
    lines.presence&.join("\n") || "Nothing happened and nothing is waiting."
  end

  # Daily and longer digests become a card; overnight ones wait for the morning.
  def deliver(accounting, headline, now)
    card = Card.create!(
      card_type: "digest",
      project: "secretary",
      summary: (headline.presence || accounting.title).truncate(200),
      ask: "acknowledge",
      payload: { "accounting_id" => accounting.id, "title" => accounting.title, "body" => accounting.body },
      digested_at: now
    )
    accounting.update!(card: card)
    unless now.hour.between?(MORNING, EVENING - 1)
      morning = now.change(hour: MORNING)
      card.hold!(until_time: morning > now ? morning : morning + 1.day)
    end
    card
  end
end
