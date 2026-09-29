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

  module_function

  def bin
    ENV.fetch("STACK_CLAUDE_BIN", "claude")
  end

  # internal: the secretary's own runs, which the stack hook ignores so they
  # never become cards.
  def env(internal: false)
    vars = STRIPPED.to_h { |key| [ key, nil ] }.merge("STACK_INTERNAL" => internal ? "1" : nil)
    token = Credential.claude_token&.secret
    token ? vars.merge("CLAUDE_CODE_OAUTH_TOKEN" => token) : vars
  end

  # A scratch directory for the secretary's runs, away from any project.
  def workdir
    Rails.root.join("tmp", "secretary").tap(&:mkpath).to_s
  end

  # { "loggedIn" => true, "authMethod" => ..., ... } or { "error" => ... }.
  def status
    output, status = Open3.capture2e(env, bin, "auth", "status", "--json")
    status.success? ? JSON.parse(output) : { "error" => output.strip.presence || "claude auth status failed" }
  rescue SystemCallError, JSON::ParserError => e
    { "error" => e.message }
  end
end
