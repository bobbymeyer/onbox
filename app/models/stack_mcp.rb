# onbox's side of the stack MCP bridge (script/stack-mcp): a small stdio MCP
# server that Claude runs next to itself. It gives Claude three tools:
#   approve        - Claude Code's permission prompt tool for runs onbox
#                    starts: each prompt becomes an Allow/Deny card, and the
#                    run waits for Bobby's answer;
#   post_to_stack  - put a card in front of Bobby (a decision, a reply, a
#                    review, or news that a long job finished);
#   check_stack    - read what Bobby did with a card.
# The bridge talks to /api/cards with the claude-code source's token. The
# same script serves the Claude desktop app and any Claude Code session.
module StackMcp
  SCRIPT = Rails.root.join("script/stack-mcp")
  APPROVE_TOOL = "mcp__stack__approve".freeze
  ALLOWED = %w[Allow Approve].freeze

  module_function

  # Where the bridge reaches onbox from the same machine.
  def url
    ENV["STACK_SELF_URL"].presence || "http://127.0.0.1:#{ENV.fetch("PORT", 3000)}"
  end

  # The MCP config for a run onbox starts, written where only Bobby can read
  # it (it holds the source token). It names the run, which turns on the
  # approve tool. nil when approvals are turned off.
  def config_file(run)
    return if ENV["STACK_CLAUDE_APPROVALS"] == "off"
    path = run.path("mcp.json")
    File.write(path, { "mcpServers" => { "stack" => server(run_id: run.id) } }.to_json)
    File.chmod(0o600, path)
    path
  end

  # One MCP server entry, for runs and for the Claude apps alike.
  def server(run_id: nil)
    env = { "STACK_URL" => url, "STACK_TOKEN" => ClaudeRun.source.token, "STACK_RUN_ID" => run_id&.to_s }.compact
    { "type" => "stdio", "command" => RbConfig.ruby, "args" => [ SCRIPT.to_s ], "env" => env }
  end

  # What the bridge tells Claude about a card.
  def status(card)
    reply = card.handlings.where.not(text: [ nil, "" ]).order(:created_at).last&.text
    decision =
      if !card.handled? then "pending"
      elsif ALLOWED.include?(card.handled_with) then "allow"
      else "deny"
      end
    { "card_id" => card.id, "state" => card.state, "handled_with" => card.handled_with, "reply" => reply,
      "decision" => decision, "hold_until" => card.hold_until&.iso8601 }
  end

  # A permission prompt as a card, in front of Bobby: the run is waiting.
  def permission_card(source, params)
    run = ClaudeRun.find_by(id: params["run_id"])
    tool, input = params["tool_name"].to_s, params["tool_input"].presence || {}
    Card.create!(
      source: source, card_type: "permission", ask: "decision",
      project: run&.project || params["project"].presence,
      summary: "Allow #{tool}: #{describe(tool, input)}".truncate(200),
      position: Card.bottom_position,
      payload: { "tool_name" => tool, "tool_input" => input, "tool_use_id" => params["tool_use_id"],
                 "run_id" => run&.id, "session_id" => run&.session_id, "cwd" => run&.cwd,
                 "body" => "#{tool}\n\n#{JSON.pretty_generate(input)}" }.compact
    )
  end

  # The part of a tool call Bobby needs to decide on.
  def describe(tool, input)
    input = input.to_h
    input["command"].presence || input["file_path"].presence || input["url"].presence ||
      input["pattern"].presence || input.to_json.truncate(120)
  end
end
