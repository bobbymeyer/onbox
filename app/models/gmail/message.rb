module Gmail
  # Flattens a Gmail API message into the plain hash the email normalizer
  # reads. The same shape can be POSTed to /intake by any other mail bridge.
  module Message
    BODY_LIMIT = 50_000

    module_function

    def normalize(message)
      headers = Array(message.payload&.headers).to_h { |h| [ h.name.downcase, h.value ] }
      {
        "message_id" => message.id,
        "thread_id" => message.thread_id,
        "rfc822_message_id" => headers["message-id"],
        "references" => headers["references"],
        "from" => headers["from"],
        "reply_to" => headers["reply-to"],
        "to" => headers["to"],
        "cc" => headers["cc"],
        "subject" => headers["subject"],
        "date" => headers["date"],
        "snippet" => message.snippet,
        "labels" => Array(message.label_ids),
        "body" => body_text(message.payload).to_s.truncate(BODY_LIMIT)
      }
    end

    # Prefer the text/plain part; fall back to stripped HTML.
    def body_text(part)
      return if part.nil?
      plain = find_part(part, "text/plain")
      return decode(plain) if plain
      html = find_part(part, "text/html")
      html && ActionController::Base.helpers.strip_tags(decode(html)).gsub(/\n{3,}/, "\n\n").strip
    end

    def find_part(part, mime_type)
      return part if part.mime_type == mime_type && part.body&.data.present?
      Array(part.parts).each do |child|
        found = find_part(child, mime_type)
        return found if found
      end
      nil
    end

    def decode(part)
      part.body.data.to_s.dup.force_encoding(Encoding::UTF_8).scrub
    end
  end
end
