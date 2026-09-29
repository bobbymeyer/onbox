require "test_helper"

class SecretaryBackendsTest < ActiveSupport::TestCase
  SCHEMA = Secretary::Decomposition::SCHEMA

  test "tiers pick their backend; unknown names are off" do
    with_env("STACK_SECRETARY" => "local", "STACK_SECRETARY_DEEP" => "claude_code") do
      assert_equal [ "local", "claude_code" ], [ Secretary.backend_name(:routine), Secretary.backend_name(:deep) ]
    end
    with_env("STACK_SECRETARY" => "gpt") { assert_equal "off", Secretary.backend_name }
    assert_not Secretary.enabled?(:deep), "tests default to off"
  end

  test "claude_code runs claude -p on the login, marked internal, with the schema" do
    with_env("STACK_SECRETARY_DEEP" => "claude_code", "STACK_CLAUDE_BIN" => FAKE_CLAUDE, "ANTHROPIC_API_KEY" => "sk-should-not-leak") do
      answer = Secretary.new.structured(system: "Be brief.", user: "Break this down", schema: SCHEMA, tier: :deep)
      seen = answer["seen"]
      assert_equal "hi", answer["reply"]
      assert_equal "Break this down", seen["stdin"]
      assert_nil seen["api_key"]
      assert_equal "1", seen["internal"], "the stack hook ignores these runs"
      assert_equal Rails.root.join("tmp/secretary").to_s, File.realpath(seen["cwd"])
      assert_equal SCHEMA.to_json, seen["args"][seen["args"].index("--json-schema") + 1]
      assert_includes seen["args"].each_cons(2).to_a, [ "--tools", "" ]
      assert_includes seen["args"], "--no-session-persistence"
    end
  end

  test "a failing claude run degrades to nil" do
    with_env("STACK_SECRETARY_DEEP" => "claude_code", "STACK_CLAUDE_BIN" => FAKE_CLAUDE, "FAKE_CLAUDE_FAIL" => "1") do
      assert_nil Secretary.new.structured(system: "x", user: "y", schema: SCHEMA, tier: :deep)
    end
    with_env("STACK_SECRETARY_DEEP" => "claude_code", "STACK_CLAUDE_BIN" => "/nonexistent/claude") do
      assert_nil Secretary.new.structured(system: "x", user: "y", schema: SCHEMA, tier: :deep)
    end
  end

  test "claude_code reads structured_output, or JSON in the result text" do
    parse = ->(envelope) { Secretary::Backends::ClaudeCode.parse(envelope.to_json) }
    assert_equal({ "a" => 1 }, parse.({ "structured_output" => { "a" => 1 } }))
    assert_equal({ "a" => 1 }, parse.({ "result" => "Here:\n```json\n{\"a\": 1}\n```" }))
    assert_raises(Secretary::Error) { parse.({ "is_error" => true, "result" => "Credit balance is too low" }) }
  end

  test "local sends the schema to Ollama and parses the reply" do
    sent = nil
    reply = { "message" => { "content" => { "steps" => [] }.to_json } }
    original = Secretary::Backends::Local.method(:post)
    Secretary::Backends::Local.define_singleton_method(:post) { |_path, body| sent = body; reply }
    with_env("STACK_SECRETARY" => "local", "STACK_LOCAL_MODEL" => "qwen3:30b") do
      assert_equal({ "steps" => [] }, Secretary.new.structured(system: "s", user: "u", schema: SCHEMA))
    end
    assert_equal [ "qwen3:30b", SCHEMA, false, false ], sent.values_at(:model, :format, :stream, :think)
    assert_equal %w[system user], sent[:messages].map { |m| m[:role] }
  ensure
    Secretary::Backends::Local.define_singleton_method(:post, original)
  end

  test "local reports an unreachable Ollama plainly" do
    with_env("STACK_OLLAMA_URL" => "http://127.0.0.1:9", "STACK_SECRETARY" => "local") do
      status = Secretary::Backends::Local.status
      assert_not status["reachable"]
      assert_match "Ollama at http://127.0.0.1:9", status["error"]
      assert_nil Secretary.new.structured(system: "s", user: "u", schema: SCHEMA), "falls back instead of raising"
    end
  end

  test "claude auth status is read from the CLI" do
    with_env("STACK_CLAUDE_BIN" => FAKE_CLAUDE) do
      assert_equal [ true, "max" ], ClaudeCli.status.values_at("loggedIn", "subscriptionType")
    end
    with_env("STACK_CLAUDE_BIN" => "/nonexistent/claude") do
      assert ClaudeCli.status["error"]
    end
  end
end
