module Gmail
  # Polls one mailbox and pushes new mail through the same intake as every
  # other source. Gmail push via Pub/Sub can later call this same method.
  module Sync
    OVERLAP = 5.minutes
    FIRST_LOOKBACK = 1.day

    module_function

    def call(source, mailbox: Mailbox.new(source), now: Time.current)
      raise ArgumentError, "#{source.name} is not connected to Gmail" unless source.connected?

      after = (source.last_polled_at || now - FIRST_LOOKBACK) - OVERLAP
      cards = mailbox.messages(query: source.email_query, after: after).filter_map do |message|
        next if message["labels"].include?("SENT") || seen?(message["message_id"])
        Intake.receive(source, message)
      end

      source.update!(settings: source.settings.merge("last_polled_at" => now.iso8601, "last_error" => nil))
      cards
    rescue Google::Apis::Error, Signet::AuthorizationError => e
      source.update!(settings: source.settings.merge("last_error" => "#{e.class}: #{e.message}".truncate(500)))
      raise
    end

    def seen?(message_id)
      Card.where("json_extract(payload, '$.message_id') = ?", message_id).exists?
    end
  end
end
