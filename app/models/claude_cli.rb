require "open3"

# Every Claude call the stack makes goes through the official claude CLI,
# signed in with Bobby's Claude account (Max plan): `claude auth login`, or
# `claude setup-token` and CLAUDE_CODE_OAUTH_TOKEN for a background service.
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
    STRIPPED.to_h { |key| [ key, nil ] }.merge("STACK_INTERNAL" => internal ? "1" : nil)
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
