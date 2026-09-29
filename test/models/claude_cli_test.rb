require "test_helper"

class ClaudeCliTest < ActiveSupport::TestCase
  setup do
    @home = Dir.mktmpdir("home")
    @empty_path = Dir.mktmpdir("path")
  end

  teardown { FileUtils.rm_rf([ @home, @empty_path ]) }

  def install(relative)
    path = File.join(@home, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#!/bin/sh\necho ok\n")
    File.chmod(0o755, path)
    path
  end

  def isolated(**env, &block)
    with_env({ "HOME" => @home, "PATH" => "#{@empty_path}:/usr/bin:/bin", "STACK_CLAUDE_BIN" => nil }.merge(env.transform_keys(&:to_s)), &block)
  end

  test "finds claude where Claude Code installs it, even off the server's PATH" do
    native = install(".local/bin/claude")
    isolated do
      assert_equal native, ClaudeCli.bin
      assert ClaudeCli.found?
      assert ClaudeCli.env["PATH"].start_with?("#{@home}/.local/bin:"), "its directory goes on PATH for the run"
    end
  end

  test "an npm install under nvm is found, newest node first" do
    install(".nvm/versions/node/v20.1.0/bin/claude")
    newest = install(".nvm/versions/node/v22.3.0/bin/claude")
    isolated { assert_equal newest, ClaudeCli.bin }
  end

  test "PATH wins over install locations, and STACK_CLAUDE_BIN wins over both" do
    install(".local/bin/claude")
    on_path = File.join(@empty_path, "claude")
    File.write(on_path, "#!/bin/sh\n")
    File.chmod(0o755, on_path)
    isolated { assert_equal on_path, ClaudeCli.bin }
    isolated(STACK_CLAUDE_BIN: "/custom/claude") { assert_equal "/custom/claude", ClaudeCli.bin }
  end

  test "when it's nowhere, every path says how to fix it" do
    isolated do
      assert_not ClaudeCli.found?
      assert_equal "claude", ClaudeCli.bin
      assert_match "STACK_CLAUDE_BIN", ClaudeCli.status["error"]
      assert_raises(ClaudeLogin::Failed, match: /can't find Claude Code's claude command/) { ClaudeLogin.new.spawn }
      output, ok = AgentDispatch.call(session_id: "s", instruction: "go")
      assert_not ok
      assert_match "which claude", output
    end
  end
end
