# Connects the Claudes on this Mac to the stack (bin/rails stack:connect):
#   Claude Code  - the Stop/Notification hook and the stack MCP bridge in
#                  ~/.claude/settings.json and ~/.claude.json (via the CLI),
#                  plus a standing instruction in ~/.claude/CLAUDE.md;
#   desktop app  - the bridge in claude_desktop_config.json.
# Each file is backed up before it changes, and no token is ever printed.
# ClaudeSetup.doctor checks that path end to end.
require "net/http"

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

  CLOUD_HOOK = Rails.root.join("script/cloud-stack-hook")
  CLOUD_HOOK_COMMAND = 'python3 "$CLAUDE_PROJECT_DIR/.claude/hooks/stack-hook"'.freeze

  # Puts the cloud hook in a repository checkout, so its Claude Code on the
  # web sessions report to the stack once committed: the script as
  # .claude/hooks/stack-hook and the Stop/Notification hooks in its
  # .claude/settings.json, keeping whatever else is there.
  def install_cloud_hook!(repo)
    repo = Pathname(repo).expand_path
    raise ArgumentError, "#{repo} isn't a git checkout" unless repo.join(".git").exist?
    hooks_dir = repo.join(".claude/hooks").tap(&:mkpath)
    FileUtils.cp(CLOUD_HOOK, hooks_dir.join("stack-hook"))
    File.chmod(0o755, hooks_dir.join("stack-hook"))

    path = repo.join(".claude/settings.json")
    settings = read_json(path)
    settings["hooks"] ||= {}
    %w[Stop Notification].each do |event|
      entries = settings["hooks"][event] ||= []
      next if entries.any? { |entry| Array(entry["hooks"]).any? { |h| h["command"] == CLOUD_HOOK_COMMAND } }
      entries << { "hooks" => [ { "type" => "command", "command" => CLOUD_HOOK_COMMAND } ] }
    end
    path.write(JSON.pretty_generate(settings) + "\n")
    "#{repo.basename}: commit .claude/hooks/stack-hook and .claude/settings.json, then its cloud sessions report to the stack"
  end

  DOCTOR_SESSION = "onbox-doctor".freeze

  # Checks every step from a Claude Code session's Stop to a card, and says
  # which one breaks. Sends two test cards (straight to onbox, then through
  # the hook script) and clears them. Returns a line per check.
  def doctor
    lines = []
    check = ->(ok, text) { lines << "#{ok ? "ok " : "NO "} #{text}"; ok }
    settings = read_json(settings_path)
    env = settings["env"] || {}
    url, token = env["STACK_URL"].presence, env["STACK_TOKEN"].presence
    hook = Rails.root.join("script/stack-hook").to_s
    source = ClaudeRun.source

    check.(settings_path.exist?, "#{settings_path} exists")
    check.(settings["disableAllHooks"] != true, "hooks aren't turned off there (disableAllHooks)")
    check.(url.present?, "STACK_URL is set there#{" (#{url})" if url}")
    check.(token.present? && ActiveSupport::SecurityUtils.secure_compare(token, source.token),
           "STACK_TOKEN there matches the #{source.name} source's current token#{" (it was rotated? run bin/rails stack:connect)" unless token.present? && ActiveSupport::SecurityUtils.secure_compare(token, source.token)}")
    %w[Stop Notification].each do |event|
      commands = Array(settings.dig("hooks", event)).flat_map { |entry| Array(entry["hooks"]).map { |h| h["command"] } }
      check.(commands.include?(hook), "the #{event} hook runs #{hook}#{" (found: #{commands.join(", ").presence || "none"})" unless commands.include?(hook)}")
    end
    check.(File.executable?(hook), "#{hook} is executable")

    if url && token
      code = post_test(url, token, "#{DOCTOR_SESSION}-direct")
      if check.(code.start_with?("2"), "onbox answers at #{url}/intake (#{code})")
        log = Rails.root.join("tmp/stack-hook-doctor.log").to_s
        FileUtils.rm_f(log)
        env = { "STACK_URL" => url, "STACK_TOKEN" => token, "STACK_HOOK_LOG" => log, "STACK_LAUNCHED" => nil, "STACK_INTERNAL" => nil }
        Open3.capture2e(env, hook, stdin_data: test_payload("#{DOCTOR_SESSION}-hook").to_json)
        arrived = source.cards.exists?(key: "claude_code:#{DOCTOR_SESSION}-hook")
        check.(arrived, "the hook script delivers a card#{": #{File.read(log).strip}" if !arrived && File.exist?(log)}")
      end
    end
    source.cards.open.where("key LIKE ?", "claude_code:#{DOCTOR_SESSION}%").find_each { |card| card.handle!(with: "stack:doctor") }

    last = source.cards.where.not("key LIKE ?", "claude_code:#{DOCTOR_SESSION}%").maximum(:created_at)
    lines << "Last Claude Code card: #{last ? "#{ActionController::Base.helpers.time_ago_in_words(last)} ago" : "never"}"
    hook_log = home.join(".claude/stack-hook.log")
    lines << "Recent hook failures (#{hook_log}):\n#{hook_log.read.lines.last(5).join}" if hook_log.exist? && hook_log.size.positive?
    lines << "Sessions started before the hooks were set up don't have them; restart those sessions."
    lines
  end

  def test_payload(session)
    { "session_id" => session, "hook_event_name" => "Stop", "cwd" => Rails.root.to_s,
      "last_assistant_message" => "Test card from bin/rails stack:doctor" }
  end

  def post_test(url, token, session)
    uri = URI.join(url.chomp("/") + "/", "intake")
    req = Net::HTTP::Post.new(uri, "Content-Type" => "application/json", "Authorization" => "Bearer #{token}")
    req.body = test_payload(session).to_json
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 5, read_timeout: 10) { |http| http.request(req) }.code
  rescue SystemCallError, SocketError, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError => e
    "unreachable: #{e.message}"
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
