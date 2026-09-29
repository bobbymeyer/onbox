class Secretary
  # Maintenance mode is a conversation: "why is this so high", "always defer
  # these till evening". The secretary answers and may make reversible changes
  # to the stack. It never deletes, handles, or sends anything.
  module Conversation
    OPERATIONS = %w[to_front to_top hold release set_project set_ask remember forget].freeze

    SYSTEM = <<~PROMPT.freeze
      You are the secretary for The Stack, Bobby's single-user queue of index
      cards. He sees only the card at the front, so your judgment about the
      order has to stay legible to him. In maintenance mode he talks to you
      about the whole stack.

      Answer plainly and briefly. Explain why cards sit where they do when
      asked. When he asks for a change, make it with operations:
      - to_front / to_top: move card target_id to the front, or back on top.
      - hold: hold card target_id until value (ISO 8601 with offset).
      - release: put held card target_id back in the stack.
      - set_project / set_ask: change card target_id's project, or its ask
        (decision, reply, review, acknowledge), to value.
      - remember: save value as a standing instruction you will follow for
        every new card (e.g. "Hold receipts until 18:00").
      - forget: drop standing instruction target_id.
      Only act on what he asked for. You cannot delete, handle, or send
      anything; if he asks, say he can do it from the list. Say what you changed.
    PROMPT

    SCHEMA = {
      type: "object",
      properties: {
        reply: { type: "string" },
        operations: {
          type: "array",
          items: {
            type: "object",
            properties: {
              op: { type: "string", enum: OPERATIONS },
              target_id: { type: [ "integer", "null" ] },
              value: { type: [ "string", "null" ] }
            },
            required: %w[op target_id value],
            additionalProperties: false
          }
        }
      },
      required: %w[reply operations],
      additionalProperties: false
    }.freeze

    module_function

    # Records Bobby's message and the secretary's reply; returns the reply.
    def say(text)
      SecretaryMessage.create!(role: "bobby", body: text)
      history = SecretaryMessage.recent(12)

      answer = Secretary.new.structured(system: SYSTEM, user: context(history), schema: SCHEMA, effort: :medium, tier: :deep)
      body, applied =
        if answer
          [ answer["reply"].to_s.presence || "Done.", Array(answer["operations"]).filter_map { |op| apply(op) } ]
        else
          [ "I'm not available right now (see /secretary). You can still add a standing instruction below.", [] ]
        end

      SecretaryMessage.create!(role: "secretary", body: body, operations: applied)
    end

    # Applies one operation; returns a description of what changed, or nil.
    def apply(op)
      case op["op"]
      when "remember"
        directive = Directive.create!(text: op["value"]) if op["value"].present?
        directive && "Remembered: #{directive.text}"
      when "forget"
        directive = Directive.find_by(id: op["target_id"])
        directive&.destroy! && "Forgot: #{directive.text}"
      else
        card = Card.open.find_by(id: op["target_id"]) or return
        done = apply_to_card(card, op["op"], op["value"])
        card.handlings.create!(verb: "secretary", text: "#{done} (asked in maintenance)") if done
        done
      end
    rescue ActiveRecord::RecordInvalid, ArgumentError
      nil
    end

    def apply_to_card(card, op, value)
      case op
      when "to_front"
        card.release! if card.held?
        card.update!(position: Card.bottom_position)
        "Moved to front: #{card.summary}"
      when "to_top"
        card.to_top_of_stack!
        "Moved to top: #{card.summary}"
      when "hold"
        time = Time.zone.parse(value.to_s)
        return unless time&.future?
        card.hold!(until_time: time)
        "Held until #{time.to_fs(:short)}: #{card.summary}"
      when "release"
        return unless card.held?
        card.release!
        "Released: #{card.summary}"
      when "set_project"
        card.update!(project: value.to_s.strip.presence)
        "Re-tagged #{card.summary} as #{card.project || "no project"}"
      when "set_ask"
        card.update!(ask: value)
        "Ask for #{card.summary} is now #{value}"
      end
    end

    def context(history)
      <<~CONTEXT
        Now: #{Time.current.iso8601} (#{Time.zone.name})

        Live cards, front of the stack first:
        #{Card.live.in_stack_order.includes(:source, :blocked_by).limit(100).each_with_index.map { |c, i| "#{i + 1}. #{line(c)}#{" (waits on ##{c.blocked_by_id})" if c.blocked?}" }.join("\n").presence || "none"}

        Held cards:
        #{Card.held.includes(:source).order(:hold_until).limit(100).map { |c| "- #{line(c)} until #{[ c.hold_until&.iso8601, c.hold_event ].compact.join(" or ")}" }.join("\n").presence || "none"}

        Recently handled:
        #{Card.handled.order(handled_at: :desc).limit(10).map { |c| "- #{line(c)} with #{c.handled_with}" }.join("\n").presence || "none"}

        Standing instructions:
        #{Directive.texts.join("\n").presence || "none"}

        Your latest digests:
        #{Accounting.newest_first.limit(3).map { |a| "- #{a.title}: #{a.body}" }.join("\n").presence || "none"}

        Conversation so far (latest last):
        #{history.map { |m| "#{m.role}: #{m.body}" }.join("\n")}
      CONTEXT
    end

    def line(card)
      "[##{card.id}] #{card.source&.name || "stack"}/#{card.project} · #{card.ask} · #{ActionController::Base.helpers.time_ago_in_words(card.created_at)} old · #{card.summary}"
    end
  end
end
