module MacMail
  # Reads the Mac's Mail (every account it has) and pushes new unread inbox
  # mail through the intake, one card per thread. Mailing lists and bulk mail
  # are left out unless the source includes them. The inbox and the stack
  # stay in step: handling a card marks its message read in Mail (see
  # CardType::Email), and a message read, archived or deleted in Mail clears
  # its card.
  module Sync
    FIRST_LOOKBACK = 1.day
    SKIPPED_LIMIT = 500
    READ = "read in Mail".freeze

    module_function

    # Mail received from a day before the first read on counts, however late
    # Mail downloads it; older unread mail stays in Mail.
    def call(source, kit: MacEventKit, now: Time.current)
      since = (Time.zone.parse(source.settings["since"].to_s) if source.settings["since"]) || now - FIRST_LOOKBACK
      skipped = source.settings.fetch("skipped", [])
      unread = kit.mail_unread
      fresh = unread.reject { |m| m["junk"] || skipped.include?(m["message_id"]) }
        .select { |m| (t = Time.zone.parse(m["received"].to_s)) && t >= since }
        .reject { |m| seen?(m["message_id"]) }

      messages = kit.mail_messages(fresh.map { |m| m["message_id"] }).map { |m| Message.normalize(m) }
      bulk, wanted = messages.partition { |m| m["bulk"] && !include_bulk?(source) }
      cards = wanted.sort_by { |m| m["date"].to_s }.map { |m| Intake.receive(source, m) }

      clear_read(source, unread.map { |m| m["message_id"] }.to_set)
      source.update!(settings: source.settings.merge(
        "since" => since.iso8601, "skipped" => (skipped + bulk.map { |m| m["message_id"] }).last(SKIPPED_LIMIT),
        "last_polled_at" => now.iso8601, "last_error" => nil
      ))
      cards
    rescue MacEventKit::Error => e
      source.update!(settings: source.settings.merge("last_error" => e.message))
      raise
    end

    def include_bulk?(source)
      source.settings["include_bulk"] == true
    end

    def seen?(message_id)
      Card.where("json_extract(payload, '$.message_id') = ?", message_id).exists?
    end

    # A card whose newest message is no longer unread in an inbox was dealt
    # with in Mail.
    def clear_read(source, unread_ids)
      source.cards.open.where(card_type: "email").find_each do |card|
        card.handle!(with: READ) if unread_ids.exclude?(card.payload["message_id"])
      end
    end
  end
end
