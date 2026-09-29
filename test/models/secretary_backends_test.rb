require "test_helper"

class SecretaryBackendsTest < ActiveSupport::TestCase
  SCHEMA = Secretary::Decomposition::SCHEMA

  test "tiers pick their backend; unknown names are off" do
    with_env("STACK_SECRETARY" => "local", "STACK_SECRETARY_DEEP" => "claude_code") do
      assert_equal [ "local", "claude_code" ], [ Secretary.backend_name(:routine), Secretary.backend_name(:deep) ]
    end
    with_env("STACK_SECRETARY" => "api") { assert_equal "off", Secretary.backend_name, "the API-key backend is gone" }
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

  def with_local_reply(reply)
    sent = []
    original = Secretary::Backends::Local.method(:request)
    Secretary::Backends::Local.define_singleton_method(:request) { |verb, path, body = nil| sent << [ verb, path, body ]; reply }
    yield sent
  ensure
    Secretary::Backends::Local.define_singleton_method(:request, original)
  end

  test "local asks the OpenAI-compatible endpoint for schema-constrained JSON" do
    reply = { "choices" => [ { "finish_reason" => "stop", "message" => { "content" => { "steps" => [] }.to_json } } ] }
    with_env("STACK_SECRETARY" => "local", "STACK_SECRETARY_MODEL" => "qwen-moe") do
      with_local_reply(reply) do |sent|
        assert_equal({ "steps" => [] }, Secretary.new.structured(system: "s", user: "u", schema: SCHEMA))
        verb, path, body = sent.sole
        assert_equal [ :post, "chat/completions", "qwen-moe", 0 ], [ verb, path, body[:model], body[:temperature] ]
        assert_equal({ type: "json_schema", json_schema: { name: "reply", strict: true, schema: SCHEMA } }, body[:response_format])
        assert_equal({ enable_thinking: false }, body[:chat_template_kwargs])
        assert_equal %w[system user], body[:messages].map { |m| m[:role] }
      end
    end
  end

  test "local degrades to nil when unset, cut off, or unreachable" do
    with_env("STACK_SECRETARY" => "local", "STACK_SECRETARY_MODEL" => nil) do
      assert_nil Secretary.new.structured(system: "s", user: "u", schema: SCHEMA), "no model set"
    end
    with_env("STACK_SECRETARY" => "local", "STACK_SECRETARY_MODEL" => "qwen-moe") do
      with_local_reply({ "choices" => [ { "finish_reason" => "length", "message" => { "content" => "{" } } ] }) do
        assert_nil Secretary.new.structured(system: "s", user: "u", schema: SCHEMA), "ran out of tokens"
      end
    end
    with_env("STACK_SECRETARY" => "local", "STACK_SECRETARY_MODEL" => "qwen-moe", "STACK_SECRETARY_URL" => "http://127.0.0.1:9/v1") do
      status = Secretary::Backends::Local.status
      assert_not status["reachable"]
      assert_match "couldn't reach http://127.0.0.1:9/v1", status["error"]
      assert_nil Secretary.new.structured(system: "s", user: "u", schema: SCHEMA)
    end
  end

  test "local status lists the endpoint's models" do
    with_env("STACK_SECRETARY_MODEL" => "qwen-moe") do
      with_local_reply({ "data" => [ { "id" => "qwen-moe" }, { "id" => "gemma" } ] }) do
        assert_equal [ true, %w[qwen-moe gemma], true ], Secretary::Backends::Local.status.values_at("reachable", "models", "model_ready")
      end
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
