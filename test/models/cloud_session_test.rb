require "test_helper"

class CloudSessionTest < ActiveSupport::TestCase
  test "a cloud session's card links to it, and a reply goes back with claude --cloud" do
    card = agent_card(remote_session_id: "cse_01ABC", last_assistant_message: "Tests pass. Merge?")
    assert_equal "https://claude.ai/code/session_01ABC", card.payload["remote_session_url"]
    assert_equal "Tests pass. Merge?", card.summary

    log = Rails.root.join("tmp/fake_claude_cloud_#{SecureRandom.hex(3)}.json").to_s
    Credential.store_claude_token!("sk-ant-oat01-onbox")
    with_env("STACK_CLAUDE_BIN" => FAKE_CLAUDE, "FAKE_CLAUDE_LOG" => log) do
      AgentDispatchJob.perform_now(card, "Yes, merge it")
    end
    seen = JSON.parse(File.read(log))
    assert_equal [ "-p", "Yes, merge it", "--cloud", "session_01ABC" ], seen["args"]
    assert_nil seen["oauth_token"], "--cloud needs the CLI's own login, not onbox's token"
    assert_equal 0, ClaudeRun.count, "nothing runs on the Mac"
  ensure
    FileUtils.rm_f(log) if log
  end

  test "a reply that can't reach the session comes back as a card with its link" do
    card = agent_card(remote_session_id: "cse_01ABC")
    with_env("STACK_CLAUDE_BIN" => FAKE_CLAUDE, "FAKE_CLAUDE_FAIL" => "1") { AgentDispatchJob.perform_now(card, "go") }
    failure = card.children.sole
    assert_match "Couldn't send instruction", failure.summary
    assert_match "https://claude.ai/code/session_01ABC", failure.payload["body"]
  end

  test "the cloud hook posts the session, its last reply and the token, and only in the cloud" do
    server = TCPServer.new("127.0.0.1", 0)
    received = Queue.new
    thread = Thread.new do
      loop do
        client = server.accept
        client.gets
        headers = {}
        while (line = client.gets) && line != "\r\n"
          name, value = line.split(":", 2)
          headers[name.downcase] = value.to_s.strip
        end
        received << [ headers, JSON.parse(client.read(headers["content-length"].to_i)) ]
        client.write("HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        client.close
      end
    end
    transcript = Rails.root.join("tmp/transcript-#{SecureRandom.hex(3)}.jsonl")
    File.write(transcript, [
      { type: "user", message: { content: "Run the tests" } },
      { type: "assistant", message: { content: [ { type: "text", text: "All 158 pass." }, { type: "tool_use", name: "Bash" } ] } }
    ].map(&:to_json).join("\n"))
    input = { session_id: "s1", hook_event_name: "Stop", cwd: "/home/user/onbox", transcript_path: transcript.to_s }.to_json
    env = { "STACK_URL" => "http://127.0.0.1:#{server.addr[1]}", "STACK_TOKEN" => "cloud-token",
            "CLAUDE_CODE_REMOTE" => "true", "CLAUDE_CODE_REMOTE_SESSION_ID" => "cse_01XYZ" }

    _, status = Open3.capture2(env, "python3", ClaudeSetup::CLOUD_HOOK.to_s, stdin_data: input)
    assert status.success?
    headers, body = received.pop
    assert_equal "Bearer cloud-token", headers["authorization"]
    assert_equal [ "s1", "cse_01XYZ", "All 158 pass." ], body.values_at("session_id", "remote_session_id", "last_assistant_message")
    assert_not body.key?("transcript_path")

    _, status = Open3.capture2(env.merge("CLAUDE_CODE_REMOTE" => nil), "python3", ClaudeSetup::CLOUD_HOOK.to_s, stdin_data: input)
    assert status.success?
    sleep 0.2
    assert received.empty?, "a local session reports through ~/.claude instead"

    _, status = Open3.capture2(env.merge("STACK_URL" => "http://127.0.0.1:9"), "python3", ClaudeSetup::CLOUD_HOOK.to_s, stdin_data: input)
    assert status.success?, "an unreachable onbox never fails the session"
  ensure
    thread&.kill
    server&.close
    FileUtils.rm_f(transcript) if transcript
  end

  test "installing the cloud hook in a repository keeps its settings" do
    repo = Rails.root.join("tmp/repo-#{SecureRandom.hex(3)}")
    FileUtils.mkdir_p(repo.join(".git"))
    FileUtils.mkdir_p(repo.join(".claude"))
    File.write(repo.join(".claude/settings.json"), { "permissions" => { "allow" => [ "Bash(npm test)" ] } }.to_json)
    2.times { ClaudeSetup.install_cloud_hook!(repo) }
    settings = JSON.parse(File.read(repo.join(".claude/settings.json")))
    assert_equal [ "Bash(npm test)" ], settings.dig("permissions", "allow")
    assert_equal [ ClaudeSetup::CLOUD_HOOK_COMMAND ], settings.dig("hooks", "Stop").flat_map { |e| e["hooks"].map { |h| h["command"] } }
    assert File.executable?(repo.join(".claude/hooks/stack-hook"))
    assert_raises(ArgumentError) { ClaudeSetup.install_cloud_hook!(Rails.root.join("tmp")) }
  ensure
    FileUtils.rm_rf(repo) if repo
  end
end
