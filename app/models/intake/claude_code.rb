module Intake
  # Claude Code hooks: Stop (turn finished) and Notification (needs input).
  # Each POSTs its JSON hook input; session_id is the card's key, so a
  # session only ever holds one open card.
  # https://code.claude.com/docs/en/hooks
  module ClaudeCode
    TRANSCRIPT_TAIL_BYTES = 256.kilobytes

    def self.call(source, payload)
      return post(payload) if payload["hook_event_name"] == "Post"
      session_id = payload["session_id"].to_s
      hook = payload["hook_event_name"].to_s
      project = payload["cwd"].present? ? File.basename(payload["cwd"]) : nil
      last_message = payload["last_assistant_message"].presence || last_assistant_message(payload["transcript_path"])

      summary, ask =
        case hook
        when "Notification" then [ payload["message"].presence || "Agent needs input", "decision" ]
        else [ first_line(last_message) || "Agent finished its turn", "review" ]
        end

      payload = payload.merge("remote_session_url" => CloudSession.url(payload["remote_session_id"])) if payload["remote_session_id"].present?

      Event.new(
        key: session_id.present? ? "claude_code:#{session_id}" : nil,
        project: project,
        summary: summary.truncate(200),
        ask: ask,
        body: [ payload["message"], last_message ].compact_blank.uniq.join("\n\n"),
        payload: payload.merge("last_assistant_message" => last_message),
        event_keys: [ "claude_code:#{hook.underscore}", project && "claude_code:#{hook.underscore}:#{project}", session_id.presence && "claude_code:#{session_id}" ].compact
      )
    end

    # A card Claude chose to post (the stack MCP bridge's post_to_stack): its
    # own card, so it isn't folded into the session's next Stop.
    def self.post(payload)
      project = payload["project"].presence || (payload["cwd"].present? ? File.basename(payload["cwd"]) : "chat")
      body = payload["last_assistant_message"].to_s
      Event.new(
        key: nil,
        project: project,
        summary: (payload["summary"].presence || first_line(body) || "Claude posted to the stack").truncate(200),
        ask: payload["ask"].presence_in(Card::ASKS) || "review",
        proposed_action: payload["proposed_action"].presence,
        body: body,
        payload: payload,
        event_keys: [ "claude_code:post", "claude_code:post:#{project}" ]
      )
    end

    def self.first_line(text)
      text.to_s.lines.map(&:strip).find(&:present?)
    end

    # The server runs on the same machine as the agents, so the transcript is
    # readable. Walk the JSONL tail backwards to the last assistant text.
    def self.last_assistant_message(path)
      return if path.blank? || !File.readable?(path)

      tail = File.open(path, "rb") do |f|
        f.seek([ f.size - TRANSCRIPT_TAIL_BYTES, 0 ].max)
        f.read
      end

      tail.lines.reverse_each do |line|
        entry = JSON.parse(line) rescue next
        next unless entry["type"] == "assistant"
        content = entry.dig("message", "content")
        text = content.is_a?(String) ? content : Array(content).select { |b| b["type"] == "text" }.map { |b| b["text"] }.join("\n")
        return text if text.present?
      end
      nil
    end
  end
end
