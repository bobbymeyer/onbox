# Which model does each duty, whether it's reachable, and which Claude
# account the CLI is signed in to.
class SecretaryController < ApplicationController
  TEST_SCHEMA = {
    type: "object", properties: { reply: { type: "string" } }, required: [ "reply" ], additionalProperties: false
  }.freeze

  def show
    @tiers = { routine: Secretary.backend_name(:routine), deep: Secretary.backend_name(:deep) }
    in_use = @tiers.values
    @claude = ClaudeCli.status if in_use.include?("claude_code") || params[:check] == "claude"
    @local = Secretary::Backends::Local.status if in_use.include?("local")
    @api_key_in_env = ENV["ANTHROPIC_API_KEY"].present?
  end

  def test
    tier = params[:tier] == "deep" ? :deep : :routine
    started = Time.current
    answer = Secretary.new.structured(
      system: "You are a connectivity check. Reply with one short sentence.",
      user: "Say hello to Bobby and name the model you are.",
      schema: TEST_SCHEMA, effort: :low, tier: tier
    )
    elapsed = (Time.current - started).round(1)
    if answer
      redirect_to secretary_path, notice: "#{tier.to_s.capitalize} (#{Secretary.backend_name(tier)}) answered in #{elapsed}s: #{answer["reply"]}"
    else
      redirect_to secretary_path, alert: "#{tier.to_s.capitalize} (#{Secretary.backend_name(tier)}) didn't answer. Check the log and the status below."
    end
  end
end
