module MacMail
  # Flattens a message from the Mac helper into the plain hash the email
  # normalizer reads. The thread is the first message it answers, from its
  # References (or In-Reply-To), so a thread holds one card.
  module Message
    BODY_LIMIT = 50_000

    module_function

    def normalize(message)
      headers = parse_headers(message["headers"])
      id = strip_brackets(message["message_id"])
      {
        "message_id" => message["message_id"],
        "thread_id" => thread_root(headers) || id,
        "from" => message["from"],
        "reply_to" => message["reply_to"].presence,
        "to" => message["to"].presence,
        "cc" => message["cc"].presence,
        "subject" => message["subject"],
        "date" => message["received"],
        "account" => message["account"],
        "mailbox" => message["mailbox"],
        "bulk" => bulk?(headers),
        "body" => message["body"].to_s.truncate(BODY_LIMIT)
      }
    end

    def thread_root(headers)
      ids = "#{headers["references"]} #{headers["in-reply-to"]}".scan(/<([^<>\s]+)>/).flatten
      ids.first
    end

    # Newsletters, notifications and other mail sent to many at once.
    def bulk?(headers)
      headers["list-unsubscribe"].present? || headers["list-id"].present? ||
        headers["precedence"].to_s.match?(/\A\s*(bulk|list|junk)/i) ||
        headers["auto-submitted"].to_s.strip.then { |v| v.present? && v != "no" }
    end

    # "Name: value" lines, folded lines joined, keys lowercased. The first
    # of a repeated header wins.
    def parse_headers(text)
      text.to_s.gsub(/\r?\n[ \t]+/, " ").each_line.each_with_object({}) do |line, headers|
        name, value = line.chomp.split(":", 2)
        next unless value && name.match?(/\A[!-9;-~]+\z/)
        headers[name.downcase] ||= value.strip
      end
    end

    def strip_brackets(id) = id.to_s.delete_prefix("<").delete_suffix(">")
  end
end
