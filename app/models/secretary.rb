# The model that lives inside the stack. Duties come in two tiers, each on
# its own backend:
#   routine (STACK_SECRETARY, default "local"): card fronts, "later",
#     hourly and daily digests. A local model behind an OpenAI-compatible
#     endpoint (STACK_SECRETARY_URL, STACK_SECRETARY_MODEL).
#   deep (STACK_SECRETARY_DEEP, default "claude_code"): the maintenance
#     conversation, decompose, weekly and monthly digests. Claude through the
#     claude CLI on Bobby's Max plan.
# Backends: local, claude_code, off. Beside them, the Judge (OpenJev) answers
# the typed parts of a card's front when STACK_JUDGE_URL is set. Every duty
# degrades to the intake's own front, the deferral parser or the plain
# numbers when its backend is off or fails.
class Secretary
  class Error < StandardError; end

  BACKENDS = {
    "local" => "Secretary::Backends::Local",
    "claude_code" => "Secretary::Backends::ClaudeCode"
  }.freeze
  TIER_DEFAULTS = { routine: [ "STACK_SECRETARY", "local" ], deep: [ "STACK_SECRETARY_DEEP", "claude_code" ] }.freeze

  DIGEST_SYSTEM = <<~PROMPT.freeze
    You are the secretary for The Stack, a single-user queue of index cards.
    Bobby manages loose teams of AI agents and standing processes. His attention
    is single-threaded; he sees one card at a time and must be able to act on
    its front without flipping it over.

    Given one incoming event, write the front of its card:
    - project: the thread it belongs to (repo or folder name, sender, system). Short.
    - summary: one line, at most 90 characters, saying what happened. No preamble.
    - ask: exactly what is needed from Bobby: "decision", "reply", "review", or
      "acknowledge" (nothing to do but note it).
    - proposed_action: the response you would send on his behalf, drafted in his
      voice (terse, direct, no pleasantries), ready for one-tap approval. For an
      agent card this is the next instruction to the agent. Empty string when
      the ask is "acknowledge". For an email card it is the reply body only: no
      subject, no signature, a greeting only if Bobby would plainly use one.
      Newsletters, receipts and automated mail are "acknowledge".
      For a calendar invitation it is one line of advice to Bobby (accept,
      maybe or decline, and why: clashes, who's asking, how much time); he
      answers it in Calendar. For a reminder it is the first concrete step,
      or "" when the reminder says it all.
    - likely_stamps: up to three labels from the available stamps that best fit
      this card, most likely first. Only use labels from the list given.

    - placement: where the card goes. "normal" lets it fall like any new card.
      "front" puts it in front of Bobby now; only for something plainly urgent or
      a standing instruction that says so. "hold" keeps it out of the stack until
      hold_until; only when a standing instruction calls for it.
    - hold_until: ISO 8601 time with offset when placement is "hold", else "".

    Bobby's standing instructions, when given, override your defaults.

    A confident wrong front is worse than a plain one. If the event is unclear,
    say so in the summary and choose "review".
  PROMPT

  DIGEST_SCHEMA = {
    type: "object",
    properties: {
      project: { type: "string" },
      summary: { type: "string" },
      ask: { type: "string", enum: Card::ASKS },
      proposed_action: { type: "string" },
      likely_stamps: { type: "array", items: { type: "string" } },
      placement: { type: "string", enum: %w[normal front hold] },
      hold_until: { type: "string" }
    },
    required: %w[project summary ask proposed_action likely_stamps placement hold_until],
    additionalProperties: false
  }.freeze

  LATER_SCHEMA = {
    type: "object",
    properties: {
      fires_at: { type: [ "string", "null" ], description: "ISO 8601 timestamp with offset, or null" },
      event_key: { type: [ "string", "null" ], description: "One of the known event keys, or null" }
    },
    required: %w[fires_at event_key],
    additionalProperties: false
  }.freeze

  # "local", "claude_code" or "off" for a tier.
  # Tests default to off; an explicit setting still wins.
  def self.backend_name(tier = :routine)
    variable, default = TIER_DEFAULTS.fetch(tier)
    ENV.fetch(variable, Rails.env.test? ? "off" : default).presence_in([ *BACKENDS.keys, "off" ]) || "off"
  end

  def self.enabled?(tier = :routine)
    backend_name(tier) != "off"
  end

  def self.digest(card)
    new.digest(card)
  end

  def self.resolve_later(text, card: nil, now: Time.current)
    new.resolve_later(text, card: card, now: now)
  end

  # The Judge (when set) answers the typed parts first and says which standing
  # instructions apply; the secretary writes the front with those; the
  # Judge's clear answers then stand over the secretary's.
  def digest(card)
    stamp_labels = Stamp.for_card(card).by_use.pluck(:label)
    reading = Judge.front(card, stamps: stamp_labels, directives: Directive.in_order.to_a) if Judge.enabled?
    front = ask_for_front(card, stamp_labels, reading&.dig("directives")) if self.class.enabled?
    front = Judge.overrule(front, reading, card)
    if front
      card.update!(
        project: front["project"].presence || card.project,
        summary: front["summary"].to_s.truncate(200).presence || card.summary,
        ask: front["ask"],
        proposed_action: front["proposed_action"].presence,
        payload: card.payload.merge("likely_stamps" => Array(front["likely_stamps"]) & stamp_labels, "judge" => reading&.dig("answers")).compact,
        digested_at: Time.current
      )
      place(card, front)
    else
      card.update!(digested_at: Time.current)
    end
    card
  end

  # The digest's placement: to the front, or held per a standing instruction.
  def place(card, front)
    return unless card.live?
    case front["placement"]
    when "front"
      card.update!(position: Card.bottom_position)
      card.handlings.create!(verb: "secretary", text: "Put in front on arrival")
    when "hold"
      time = Time.zone.parse(front["hold_until"].to_s) rescue nil
      return unless time&.future?
      card.hold!(until_time: time)
      card.handlings.create!(verb: "secretary", text: "Held on arrival until #{time.to_fs(:short)}")
    end
  end

  # Returns { until_time:, event_key: } or nil when it cannot be resolved.
  def resolve_later(text, card: nil, now: Time.current)
    if (time = DeferralParser.parse(text, now: now))
      return { until_time: time, event_key: nil }
    end
    return unless self.class.enabled?

    known = known_event_keys(card)
    answer = structured(
      system: "Resolve Bobby's deferral into a wake-up trigger. Now is #{now.iso8601} (#{Time.zone.name}). " \
              "Prefer a time. When the deferral names a meeting on his calendar (\"after my 3pm\", \"after standup\"), " \
              "use the end of that meeting. Use an event_key only when the text names something that matches a known key.",
      user: "Deferral: #{text}\nKnown event keys: #{known.join(", ").presence || "none"}\n" \
            "His calendar:\n#{agenda_text(now) || "not connected"}",
      schema: LATER_SCHEMA
    )
    return unless answer

    time = answer["fires_at"].presence && Time.zone.parse(answer["fires_at"])
    key = answer["event_key"].presence_in(known)
    { until_time: time, event_key: key } if time || key
  rescue ArgumentError
    nil
  end

  # One structured call on the tier's backend. Returns the parsed object, or
  # nil when the tier is off or the backend fails (logged).
  def structured(system:, user:, schema:, effort: :low, tier: :routine)
    name = self.class.backend_name(tier)
    return if name == "off"
    BACKENDS.fetch(name).constantize.call(system: system, user: user, schema: schema, effort: effort)
  rescue Error => e
    Rails.logger.warn("[secretary:#{name}] #{e.message}")
    nil
  end

  private
    # Today and tomorrow on Bobby's calendar, for resolving "after my 3pm".
    def agenda_text(now)
      return unless Source.calendar.exists? && MacEventKit.available?
      MacEventKit.events(from: now.beginning_of_day, to: now.end_of_day + 1.day)
        .select { |event| MacCalendar::Sync.going?(event) }
        .map { |event| "- #{Intake::When.describe(event)}: #{event["summary"]}" }.join("\n").presence || "nothing scheduled"
    rescue MacEventKit::Error => e
      Rails.logger.warn("[secretary] calendar: #{e.message}")
      nil
    end

    def ask_for_front(card, stamps, directives = nil)
      directives ||= Directive.in_order
      source = card.source
      structured(
        system: DIGEST_SYSTEM,
        user: <<~EVENT,
          Now: #{Time.current.iso8601} (#{Time.zone.name})
          Standing instructions: #{directives.map { |d| "[#{d.id}] #{d.text}" }.join("; ").presence || "none"}
          Card type: #{card.card_type}
          Source: #{source&.name} (#{source&.kind})
          Intake's draft front: #{{ project: card.project, summary: card.summary, ask: card.ask }.to_json}
          Available stamps: #{stamps.to_json}

          Event payload:
          #{JSON.pretty_generate(card.payload.except(*Card::SECRETARY_KEYS))}
        EVENT
        schema: DIGEST_SCHEMA
      )
    end

    def known_event_keys(card)
      keys = Source.pluck(:name)
      keys << "claude_code:stop:#{card.project}" if card&.project.present?
      if card&.card_type == "email" && (address = (Mail::Address.new(card.payload["from"].to_s).address rescue nil))
        keys << "#{card.source.name}:from:#{address.downcase}"
      end
      keys
    end
end
