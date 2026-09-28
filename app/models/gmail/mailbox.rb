require "google/apis/gmail_v1"

module Gmail
  # The only code that talks to Gmail. Everything else sees plain hashes.
  class Mailbox
    PAGE_SIZE = 25

    def initialize(source)
      @source = source
    end

    # Normalized messages matching the query, received after the given time,
    # oldest first.
    def messages(query:, after:)
      q = [ query, "after:#{after.to_i}" ].compact_blank.join(" ")
      ids = Array(service.list_user_messages("me", q: q, max_results: PAGE_SIZE).messages).map(&:id)
      ids.reverse.map { |id| Message.normalize(service.get_user_message("me", id, format: "full")) }
    end

    def address
      service.get_user_profile("me").email_address
    end

    # Replies in the card's thread, to the sender (or their Reply-To).
    def reply(payload, text)
      subject = payload["subject"].to_s
      mail = ::Mail.new
      mail.to = payload["reply_to"].presence || payload["from"]
      mail.subject = subject.match?(/\Are:/i) ? subject : "Re: #{subject}"
      if (id = payload["rfc822_message_id"]).present?
        mail["In-Reply-To"] = id
        mail["References"] = [ payload["references"], id ].compact_blank.join(" ")
      end
      mail.charset = "UTF-8"
      mail.body = text

      message = Google::Apis::GmailV1::Message.new(raw: mail.to_s, thread_id: payload["thread_id"])
      service.send_user_message("me", message)
    end

    def archive(thread_id)
      request = Google::Apis::GmailV1::ModifyThreadRequest.new(remove_label_ids: [ "INBOX" ])
      service.modify_thread("me", thread_id, request)
    end

    private
      def service
        @service ||= Google::Apis::GmailV1::GmailService.new.tap do |s|
          s.authorization = Authorization.credentials(@source.secret)
        end
      end
  end
end
