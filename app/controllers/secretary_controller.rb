# Which model does each duty, whether it's reachable, and which Claude
# account the CLI is signed in to.
class SecretaryController < ApplicationController
  TEST_SCHEMA = {
    type: "object", properties: { reply: { type: "string" } }, required: [ "reply" ], additionalProperties: false
  }.freeze

  def show
    @tiers = { routine: Secretary.backend_name(:routine), deep: Secretary.backend_name(:deep) }
    in_use = @tiers.values
    @claude = nil
    @claude = ClaudeCli.status
    @local = Secretary::Backends::Local.status if in_use.include?("local")
    @judge = Judge.status if Judge.enabled?
    @api_key_in_env = ENV["ANTHROPIC_API_KEY"].present?
    @credential = Credential.claude_token
    @login = ClaudeLogin.current
  end

  # Connecting Claude from here: runs the CLI's own sign-in (ClaudeLogin).
  def connect_claude
    ClaudeLogin.start!
    redirect_to secretary_path(anchor: "claude"), status: :see_other
  rescue ClaudeLogin::Failed => e
    redirect_to secretary_path(anchor: "claude"), alert: "Couldn't start the Claude sign-in: #{e.message}", status: :see_other
  end

  def claude_code
    login = ClaudeLogin.current or return redirect_to(secretary_path(anchor: "claude"), alert: "That sign-in expired. Start again.", status: :see_other)
    login.submit(params[:code])
    status = ClaudeCli.status
    redirect_to secretary_path(anchor: "claude"), status: :see_other,
      notice: status["loggedIn"] ? "Claude connected. Replies and deep duties now run on your Claude plan." : "Token saved, but claude says it isn't signed in: #{status["error"]}"
  rescue ClaudeLogin::Failed => e
    # That sign-in is spent; offer a fresh link straight away.
    fresh = begin
      ClaudeLogin.start!
    rescue ClaudeLogin::Failed
      nil
    end
    redirect_to secretary_path(anchor: "claude"), status: :see_other,
      alert: "#{e.message}. #{fresh ? "Here's a fresh link: sign in again and paste the new code (all of it, including the part after #)." : "Start again."}"
  end

  def cancel_claude
    ClaudeLogin.cancel!
    redirect_to secretary_path(anchor: "claude"), status: :see_other
  end

  def disconnect_claude
    ClaudeLogin.cancel!
    Credential.claude_token&.destroy!
    redirect_to secretary_path(anchor: "claude"), status: :see_other,
      notice: "Disconnected. To revoke the token itself, remove it in your Claude account settings."
  end

  def test_judge
    started = Time.current
    answer = Judge.read(state: "Bobby's printer finished the job he sent it.",
      questions: { "reply" => { type: "noul", instructions: "Does someone need a written reply from Bobby?" } })
    redirect_to secretary_path(anchor: "judge"),
      notice: "The Judge answered in #{(Time.current - started).round(1)}s: a reply is needed with probability #{answer.dig("reply", "noul")&.round(2).inspect} (expect near 0)."
  rescue Judge::Error => e
    redirect_to secretary_path(anchor: "judge"), alert: "The Judge didn't answer: #{e.message}"
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
