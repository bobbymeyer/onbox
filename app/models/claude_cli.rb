require "open3"

# Every Claude call the stack makes goes through the official claude CLI, on
# Bobby's Claude account (Max plan). He connects it from /secretary, which
# runs the CLI's own `claude setup-token` sign-in (see ClaudeLogin); the
# resulting token is only ever handed to the CLI, as CLAUDE_CODE_OAUTH_TOKEN.
# Without one, the CLI falls back to whatever login it already has.
module ClaudeCli
  # An API key in the environment would make the CLI bill the API instead of
  # the subscription, so children never see one.
  STRIPPED = %w[ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN].freeze

  # Where Claude Code usually installs itself. A server started by a script,
  # launchd or a login item often has a PATH that includes none of these.
  INSTALL_PATHS = %w[
    ~/.local/bin/claude ~/.claude/local/claude /opt/homebrew/bin/claude /usr/local/bin/claude
    ~/.npm-global/bin/claude ~/.bun/bin/claude ~/.volta/bin/claude
    ~/.local/share/mise/shims/claude ~/.asdf/shims/claude ~/.nvm/versions/node/*/bin/claude
  ].freeze

  module_function

  # STACK_CLAUDE_BIN, else claude on the server's PATH, else the usual install
  # locations; the bare name when none has it, so the error says what to do.
  def bin
    ENV["STACK_CLAUDE_BIN"].presence || on_path || installed || "claude"
  end

  def found?
    path = bin
    path.include?("/") ? File.executable?(path) : false
  end

  def not_found_message
    "onbox can't find Claude Code's claude command. It looked on the server's PATH and in #{INSTALL_PATHS.first(4).join(", ")} and the usual npm/nvm places. " \
      "Install Claude Code on this Mac, or set STACK_CLAUDE_BIN to what `which claude` prints in Terminal, and run onbox natively (bin/serve), not in Docker."
  end

  # A readable reason for a failed run: a missing binary gets the fix.
  def explain(error)
    error.is_a?(Errno::ENOENT) ? not_found_message : error.message
  end

  # internal: the secretary's own runs, which the stack hook ignores so they
  # never become cards. The claude binary's own directory goes on PATH, so an
  # npm-installed claude finds its node.
  def env(internal: false)
    vars = STRIPPED.to_h { |key| [ key, nil ] }.merge("STACK_INTERNAL" => internal ? "1" : nil)
    dir = File.dirname(bin)
    vars["PATH"] = [ dir, ENV["PATH"] ].compact_blank.join(":") if bin.include?("/")
    token = Credential.claude_token&.secret
    token ? vars.merge("CLAUDE_CODE_OAUTH_TOKEN" => token) : vars
  end

  def on_path
    ENV["PATH"].to_s.split(":").map { |dir| File.join(dir, "claude") }.find { |path| File.executable?(path) && !File.directory?(path) }
  end

  def installed
    INSTALL_PATHS.flat_map { |pattern| Dir.glob(File.expand_path(pattern)).sort.reverse }
      .find { |path| File.executable?(path) && !File.directory?(path) }
  rescue ArgumentError # no HOME
    nil
  end

  # A scratch directory for the secretary's runs, away from any project.
  def workdir
    Rails.root.join("tmp", "secretary").tap(&:mkpath).to_s
  end

  # { "loggedIn" => true, "authMethod" => ..., ... } or { "error" => ... }.
  def status
    output, status = Open3.capture2e(env, bin, "auth", "status", "--json")
    status.success? ? JSON.parse(output) : { "error" => output.strip.presence || "claude auth status failed" }
  rescue SystemCallError => e
    { "error" => explain(e) }
  rescue JSON::ParserError => e
    { "error" => e.message }
  end
end
