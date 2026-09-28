# The LLM that lives inside the stack. v0 duties: digest each incoming event
# into a clean, self-sufficient front, and resolve "later" into a trigger.
# Every duty degrades to the intake's own front (or the deterministic
# deferral parser) when the model is unavailable or declines.
class Secretary
  MODEL = ENV.fetch("STACK_SECRETARY_MODEL", "claude-opus-5-5")
  BETAS = [ "server-side-fallback-2026-07-01" ].freeze

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

  def self.enabled?
    ENV["STACK_SECRETARY"] != "off" && !Rails.env.test?
  end

  def self.digest(card)
    new.digest(card)
  end

  def self.resolve_later(text, card: nil, now: Time.current)
    new.resolve_later(text, card: card, now: now)
  end

  def digest(card)
    front = self.class.enabled? ? ask_for_front(card) : nil
    if front
      stamp_labels = Stamp.for_card(card).pluck(:label)
      card.update!(
        project: front["project"].presence || card.project,
        summary: front["summary"].to_s.truncate(200).presence || card.summary,
        ask: front["ask"],
        proposed_action: front["proposed_action"].presence,
        payload: card.payload.merge("likely_stamps" => Array(front["likely_stamps"]) & stamp_labels),
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
    when "hold"
      time = Time.zone.parse(front["hold_until"].to_s) rescue nil
      card.hold!(until_time: time) if time&.future?
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
              "Prefer a time. Use an event_key only when the text names something that matches a known key.",
      user: "Deferral: #{text}\nKnown event keys: #{known.join(", ").presence || "none"}",
      schema: LATER_SCHEMA
    )
    return unless answer

    time = answer["fires_at"].presence && Time.zone.parse(answer["fires_at"])
    key = answer["event_key"].presence_in(known)
    { until_time: time, event_key: key } if time || key
  rescue ArgumentError
    nil
  end

  def structured(system:, user:, schema:, effort: :low)
    message = client.beta.messages.create(
      model: MODEL,
      max_tokens: 16_000,
      system_: system,
      messages: [ { role: "user", content: user } ],
      output_config: { effort: effort, format: { type: :json_schema, schema: schema } },
      fallbacks: :default,
      betas: BETAS
    )
    return if message.stop_reason == :refusal

    text = message.content.select { |b| b.type == :text }.map(&:text).join
    JSON.parse(text)
  rescue Anthropic::Errors::Error, JSON::ParserError => e
    Rails.logger.warn("[secretary] #{e.class}: #{e.message}")
    nil
  end

  private
    def ask_for_front(card)
      stamps = Stamp.for_card(card).by_use.pluck(:label)
      source = card.source
      structured(
        system: DIGEST_SYSTEM,
        user: <<~EVENT,
          Now: #{Time.current.iso8601} (#{Time.zone.name})
          Standing instructions: #{Directive.texts.presence&.join("; ") || "none"}
          Card type: #{card.card_type}
          Source: #{source&.name} (#{source&.kind})
          Intake's draft front: #{{ project: card.project, summary: card.summary, ask: card.ask }.to_json}
          Available stamps: #{stamps.to_json}

          Event payload:
          #{JSON.pretty_generate(card.payload.except("likely_stamps"))}
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

    def client
      @client ||= Anthropic::Client.new
    end
end
