require "test_helper"

class ClaudeRunTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @log = Rails.root.join("tmp/fake_claude_run_#{SecureRandom.hex(4)}.json").to_s
    @env = { "STACK_CLAUDE_BIN" => FAKE_CLAUDE, "FAKE_CLAUDE_LOG" => @log, "ANTHROPIC_API_KEY" => "sk-should-not-leak" }
  end

  teardown { FileUtils.rm_f(@log) }

  def finished(run)
    run.watcher&.join(15)
    150.times { break unless run.reload.running?; sleep 0.1 }
    run
  end

  def seen = JSON.parse(File.read(@log))

  test "a new chat runs claude on Bobby's login and its reply lands as an agent card" do
    run = with_env(@env) { finished(ClaudeRun.start!(prompt: "Summarize the Q3 notes", cwd: ClaudeRun.chat_dir)) }

    assert_equal [ "finished", "sess-new", 0.12 ], [ run.state, run.session_id, run.cost_usd ]
    card = run.result_card
    assert_equal [ "agent", "claude_code:sess-new", "chat", "Done: Summarize the Q3 notes" ], [ card.card_type, card.key, card.project, card.summary ]
    assert_match "All tests pass.", card.payload["body"]
    assert_equal "onbox", card.payload["launched_by"]

    assert_equal "Summarize the Q3 notes", seen["stdin"], "the prompt goes on stdin, never as an argument"
    assert_equal [ "1", run.id.to_s ], seen.values_at("launched", "run_id"), "marked so the stack hook leaves the reply to onbox"
    assert_equal ClaudeRun::TOOL_TIMEOUT_MS, seen["tool_timeout"]
    assert_nil seen["api_key"]
    assert_equal File.realpath(ClaudeRun.chat_dir), File.realpath(seen["cwd"])
    assert_includes seen["args"].each_cons(2).to_a, [ "--permission-prompt-tool", "mcp__stack__approve" ]
    config = JSON.parse(File.read(seen["args"][seen["args"].index("--mcp-config") + 1]))
    assert_equal [ "claude-code-test-token", run.id.to_s ], config.dig("mcpServers", "stack", "env").values_at("STACK_TOKEN", "STACK_RUN_ID")
    assert_equal "600", format("%o", File.stat(run.path("mcp.json")).mode & 0o777)
  end

  test "replying on an agent card resumes its session where it ran" do
    card = agent_card(cwd: Dir.pwd)
    run = with_env(@env) do
      AgentDispatchJob.perform_now(card, "Now open the PR")
      finished(ClaudeRun.last)
    end
    assert_includes seen["args"].each_cons(2).to_a, [ "--resume", "sess-1" ]
    assert_equal File.realpath(Dir.pwd), File.realpath(seen["cwd"])
    assert_equal card, run.card
    assert_equal "claude_code:sess-1", run.result_card.key
    assert_equal "Done: Now open the PR", run.result_card.summary
  end

  test "a failed turn comes back as a card: on the card answered, or on its own" do
    card = agent_card(cwd: Dir.pwd)
    run = with_env(@env) { finished(ClaudeRun.start!(prompt: "please fail", cwd: Dir.pwd, session_id: "sess-1", card: card)) }
    assert_equal "failed", run.state
    failure = card.children.sole
    assert_equal "Claude couldn't finish in onbox", failure.summary
    assert_match "Credit balance is too low", failure.payload["body"]

    alone = with_env(@env) { finished(ClaudeRun.start!(prompt: "fail again", cwd: ClaudeRun.chat_dir)) }
    assert_equal "Claude couldn't finish in chat", Card.find_by(summary: "Claude couldn't finish in chat", project: "chat").summary
    assert_equal "failed", alone.state
  end

  test "a claude that can't be found fails at once" do
    run = with_env("STACK_CLAUDE_BIN" => "/nonexistent/claude") { ClaudeRun.start!(prompt: "hi", cwd: ClaudeRun.chat_dir) }
    assert run.failed?
    assert_match "can't find Claude Code", run.error
  end

  test "stopping ends the run and its processes" do
    run = with_env(@env.merge("FAKE_CLAUDE_SLEEP" => "10")) { ClaudeRun.start!(prompt: "long job", cwd: ClaudeRun.chat_dir) }
    sleep 0.3
    run.stop!
    run = finished(run)
    assert_equal "stopped", run.state
    assert_not run.alive?
    assert_nil run.result_card
  end

  test "the sweeper finishes runs that exited while onbox was away" do
    run = ClaudeRun.create!(prompt: "while restarting", cwd: ClaudeRun.chat_dir, pid: 999_999_999)
    File.write(run.path("out"), { "type" => "result", "is_error" => false, "result" => "Finished anyway", "session_id" => "sess-9" }.to_json)
    ClaudeRunSweepJob.perform_now
    assert_equal "Finished anyway", run.reload.result_card.summary
    assert_equal "finished", run.state
  end
end

class StackApiTest < ActionDispatch::IntegrationTest
  TOKEN = { "Authorization" => "Bearer claude-code-test-token" }.freeze

  test "Claude posts a card of its own, and reads Bobby's answer" do
    agent_card # the session's own card
    post api_cards_url, params: { kind: "note", summary: "Which database for staging?", ask: "decision",
                                  body: "Postgres or SQLite?", proposed_action: "SQLite", cwd: "/Users/bobby/code/onbox" }, as: :json, headers: TOKEN
    assert_response :created
    card = Card.find(response.parsed_body["card_id"])
    assert_equal [ "Which database for staging?", "decision", "SQLite", "onbox" ], [ card.summary, card.ask, card.proposed_action, card.project ]
    assert_equal 2, Card.where(card_type: "agent").count, "a post is its own card, not the session's"

    get api_card_url(card), headers: TOKEN
    assert_equal "pending", response.parsed_body["decision"]

    Gestures.reply(card, "SQLite, keep it simple")
    get api_card_url(card), headers: TOKEN
    assert_equal [ "handled", "reply", "SQLite, keep it simple" ], response.parsed_body.values_at("state", "handled_with", "reply")
  end

  test "a permission prompt goes to the front, and Allow or anything else answers it" do
    Card.create!(summary: "already waiting")
    run = ClaudeRun.create!(prompt: "clean up", cwd: "/Users/bobby/code/onbox", session_id: "sess-4", state: "finished")
    post api_cards_url, params: { kind: "permission", tool_name: "Bash", tool_input: { command: "rm -rf tmp/cache", description: "Clear the cache" },
                                  tool_use_id: "tu1", run_id: run.id }, as: :json, headers: TOKEN
    card = Card.find(response.parsed_body["card_id"])
    assert_equal [ "permission", "Allow Bash: rm -rf tmp/cache", "onbox", "sess-4" ], [ card.card_type, card.summary, card.project, card.payload["session_id"] ]
    assert_equal card, Card.current, "the run is waiting, so it goes in front"
    assert_equal [ "Allow" ], StampTray.for(card).shown.map(&:label), "no stamp that would quietly deny"

    Gestures.stamp(card, stamps(:allow))
    get api_card_url(card), headers: TOKEN
    assert_equal "allow", response.parsed_body["decision"]

    post api_cards_url, params: { kind: "permission", tool_name: "Edit", tool_input: { file_path: "config/database.yml" } }, as: :json, headers: TOKEN
    denied = Card.find(response.parsed_body["card_id"])
    Gestures.reply(denied, "Not the database config")
    get api_card_url(denied), headers: TOKEN
    assert_equal [ "deny", "Not the database config" ], response.parsed_body.values_at("decision", "reply")
  end

  test "the API needs a token, and a source only sees its own cards" do
    post api_cards_url, params: { kind: "note", summary: "x", ask: "review" }, as: :json
    assert_response :unauthorized

    other = Card.create!(summary: "printer card", source: sources(:printer))
    get api_card_url(other), headers: TOKEN
    assert_response :not_found
  end

  test "the permission card shows the command and a way to say why not" do
    post api_cards_url, params: { kind: "permission", tool_name: "Bash", tool_input: { command: "bin/rails db:migrate", description: "Run migrations" } }, as: :json, headers: TOKEN
    get root_url
    assert_select ".permission-input", "bin/rails db:migrate"
    assert_select "button.stamp", "Allow"
    assert_select "input[type=submit][value=Deny]"
  end
end

class StackMcpBridgeTest < ActiveSupport::TestCase
  # Speaks MCP to script/stack-mcp over stdio, against a stand-in for onbox
  # that answers "pending" twice, then with the given decision.
  def bridge(requests, decision:, env: {})
    server = TCPServer.new("127.0.0.1", 0)
    polls = 0
    posted = []
    thread = Thread.new do
      loop do
        client = server.accept
        line = client.gets.to_s
        length = 0
        while (header = client.gets) && header != "\r\n"
          length = header.split(":", 2).last.to_i if header.downcase.start_with?("content-length")
        end
        posted << JSON.parse(client.read(length)) if length.positive?
        status = line.start_with?("POST") || (polls += 1) < 3 ? "pending" : decision
        body = { card_id: 7, state: status == "pending" ? "live" : "handled", decision: status,
                 handled_with: status == "allow" ? "Allow" : "reply", reply: status == "deny" ? "Use staging" : nil }.to_json
        client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
        client.close
      end
    end
    env = { "STACK_URL" => "http://127.0.0.1:#{server.addr[1]}", "STACK_TOKEN" => "t", "STACK_POLL_SECONDS" => "0.05" }.merge(env)
    input = requests.map(&:to_json).join("\n") + "\n"
    output, status = Open3.capture2(env, RbConfig.ruby, StackMcp::SCRIPT.to_s, stdin_data: input)
    assert status.success?
    [ output.lines.map { |l| JSON.parse(l) }.index_by { |r| r["id"] }, posted ]
  ensure
    thread&.kill
    server&.close
  end

  def call(id, name, arguments) = { jsonrpc: "2.0", id: id, method: "tools/call", params: { name: name, arguments: arguments } }

  test "lists its tools, and the approve tool only for runs onbox started" do
    list = { jsonrpc: "2.0", id: 1, method: "tools/list" }
    replies, = bridge([ list ], decision: "allow")
    assert_equal %w[post_to_stack check_stack], replies[1].dig("result", "tools").map { |t| t["name"] }
    replies, = bridge([ list ], decision: "allow", env: { "STACK_RUN_ID" => "5" })
    assert_includes replies[1].dig("result", "tools").map { |t| t["name"] }, "approve"
  end

  test "approve waits for Bobby and answers in Claude Code's permission format" do
    input = { "command" => "bin/rails db:migrate" }
    replies, posted = bridge([ call(2, "approve", { tool_name: "Bash", input: input, tool_use_id: "tu1" }) ], decision: "allow", env: { "STACK_RUN_ID" => "5" })
    assert_equal({ "behavior" => "allow", "updatedInput" => input }, JSON.parse(replies[2].dig("result", "content", 0, "text")))
    assert_equal [ "permission", "Bash", input, "5" ], posted.first.values_at("kind", "tool_name", "tool_input", "run_id")

    replies, = bridge([ call(3, "approve", { tool_name: "Bash", tool_input: input }) ], decision: "deny", env: { "STACK_RUN_ID" => "5" })
    assert_equal({ "behavior" => "deny", "message" => "Bobby denied this: Use staging" }, JSON.parse(replies[3].dig("result", "content", 0, "text")))
  end

  test "posts and checks cards" do
    replies, posted = bridge([ call(4, "post_to_stack", { summary: "Ready to merge?", ask: "decision" }), call(5, "check_stack", { card_id: 7 }) ], decision: "allow")
    assert_match "card 7", replies[4].dig("result", "content", 0, "text")
    assert_equal [ "note", "Ready to merge?", "decision" ], posted.first.values_at("kind", "summary", "ask")
    assert_match "hasn't answered yet", replies[5].dig("result", "content", 0, "text")
  end

  test "without onbox it says so rather than hanging" do
    replies, = bridge([ call(6, "post_to_stack", { summary: "x", ask: "review" }) ], decision: "allow", env: { "STACK_URL" => "http://127.0.0.1:9" })
    assert replies[6].dig("result", "isError")
    assert_match "couldn't reach The Stack", replies[6].dig("result", "content", 0, "text")
  end
end
