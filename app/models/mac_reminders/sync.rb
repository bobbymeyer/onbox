module MacReminders
  # Reads the Mac's Reminders. A reminder becomes a card when it comes due
  # (any list), and everything in the Stack list becomes a card straight away,
  # so "Hey Siri, add X to Stack" lands in front of Bobby. Done completes the
  # reminder; Later moves its due time. Reminders completed elsewhere clear
  # their card.
  module Sync
    DEFAULT_LIST = "Stack".freeze
    COMPLETED = "completed in Reminders".freeze

    module_function

    def list_name(source)
      source.settings["list"].presence || ENV["STACK_REMINDERS_LIST"].presence || DEFAULT_LIST
    end

    def call(source, kit: MacEventKit, now: Time.current)
      list = list_name(source)
      reminders = kit.reminders
      due = reminders.select { |r| r["list"] == list || ((t = Time.zone.parse(r["due"].to_s)) && t <= now) }
      cards = due.reject { |r| seen?(source, r) }.map { |r| Intake.receive(source, r.merge("stack_list" => r["list"] == list)) }

      clear_completed(source, reminders.map { |r| r["reminder_id"] }.to_set)
      source.update!(settings: source.settings.merge("last_polled_at" => now.iso8601, "last_error" => nil))
      cards
    rescue MacEventKit::Error => e
      source.update!(settings: source.settings.merge("last_error" => e.message))
      raise
    end

    # Already in the stack (live or held), or handled at this due time.
    def seen?(source, reminder)
      source.cards.open.exists?(key: Intake::Reminder.key(source, reminder)) ||
        Card.where("json_extract(payload, '$.reminder_id') = ? AND json_extract(payload, '$.due') IS ?", reminder["reminder_id"], reminder["due"]).exists?
    end

    def clear_completed(source, incomplete_ids)
      source.cards.open.where(card_type: "reminder").find_each do |card|
        card.handle!(with: COMPLETED) if incomplete_ids.exclude?(card.payload["reminder_id"])
      end
    end
  end
end
