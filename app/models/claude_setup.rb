# Connects the Claudes on this Mac to the stack (bin/rails stack:connect):
#   Claude Code  - the Stop/Notification hook and the stack MCP bridge in
#                  ~/.claude/settings.json and ~/.claude.json (via the CLI),
#                  plus a standing instruction in ~/.claude/CLAUDE.md;
#   desktop app  - the bridge in claude_desktop_config.json.
# Each file is backed up before it changes, and no token is ever printed.
module ClaudeSetup
  INSTRUCTION_MARK = "<!-- onbox: the stack -->".freeze
  INSTRUCTION = <<~MD.freeze
    #{INSTRUCTION_MARK}
    ## The Stack

    Bobby works from The Stack, a one-card-at-a-time queue. When you need a
    decision, a reply or a review from him, or you finish a long task he asked
    to hear about, put a card in front of him with the stack tool's
    post_to_stack (one-line summary he can act on, the detail in the body, your
    suggested answer as proposed_action), then carry on with anything that
    doesn't depend on it. Use check_stack with the card's id to read his answer.
  MD

  module_function

  def home = Pathname(Dir.home)
  def settings_path = home.join(".claude/settings.json")
  def memory_path = home.join(".claude/CLAUDE.md")
  def desktop_path = home.join("Library/Application Support/Claude/claude_desktop_config.json")

  # Returns a line per thing done.
  def connect!
    [ hooks!, code_mcp!, instruction!, desktop! ].compact
  end

  def hooks!
    settings = read_json(settings_path)
    env = settings["env"] ||= {}
    env["STACK_URL"] = StackMcp.url
    env["STACK_TOKEN"] = ClaudeRun.source.token
    hook = Rails.root.join("script/stack-hook").to_s
    settings["hooks"] ||= {}
    %w[Stop Notification].each do |event|
      entries = settings["hooks"][event] ||= []
      next if entries.any? { |entry| Array(entry["hooks"]).any? { |h| h["command"] == hook } }
      entries << { "hooks" => [ { "type" => "command", "command" => hook } ] }
    end
    write_json(settings_path, settings)
    "Claude Code: stack hook on Stop and Notification, STACK_URL #{StackMcp.url} (#{settings_path})"
  end

  # Registers the bridge for every Claude Code session through the CLI's own
  # `claude mcp add-json`, so it lands wherever the CLI keeps user servers.
  def code_mcp!
    Open3.capture2e(ClaudeCli.env, ClaudeCli.bin, "mcp", "remove", "stack", "--scope", "user")
    output, status = Open3.capture2e(ClaudeCli.env, ClaudeCli.bin, "mcp", "add-json", "stack", StackMcp.server.to_json, "--scope", "user")
    status.success? ? "Claude Code: stack tools for every session (claude mcp, user scope)" : "Claude Code: couldn't add the stack tools: #{output.strip.truncate(300)}"
  rescue SystemCallError => e
    "Claude Code: couldn't add the stack tools: #{ClaudeCli.explain(e)}"
  end

  def instruction!
    text = memory_path.exist? ? memory_path.read : ""
    return "Claude Code: standing instruction already in #{memory_path}" if text.include?(INSTRUCTION_MARK)
    backup(memory_path)
    memory_path.dirname.mkpath
    memory_path.write([ text.rstrip.presence, INSTRUCTION ].compact.join("\n\n"))
    "Claude Code: standing instruction added to #{memory_path}"
  end

  def desktop!
    return "Desktop app: not installed here, skipped" unless desktop_path.dirname.exist?
    config = read_json(desktop_path)
    (config["mcpServers"] ||= {})["stack"] = StackMcp.server.except("type")
    write_json(desktop_path, config)
    "Desktop app: stack tools added (#{desktop_path}). Quit and reopen Claude to load them."
  end

  def read_json(path)
    path.exist? ? JSON.parse(path.read.presence || "{}") : {}
  end

  def write_json(path, data)
    backup(path)
    path.dirname.mkpath
    path.write(JSON.pretty_generate(data) + "\n")
    File.chmod(0o600, path)
  end

  def backup(path)
    FileUtils.cp(path, "#{path}.onbox-backup") if path.exist?
  end
end
