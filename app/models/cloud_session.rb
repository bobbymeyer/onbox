require "open3"

# A Claude Code on the web session (claude.ai/code) that reports to the stack
# through script/cloud-stack-hook. It runs on Anthropic's cloud; onbox only
# hears from it and answers it, with the claude CLI's documented
# `claude -p MESSAGE --cloud SESSION`, which queues the message even while the
# session is busy. That needs the CLI's own `claude auth login` on the Mac
# (not the setup-token onbox keeps) and remote sessions allowed for the
# account.
module CloudSession
  module_function

  # The hook sends the container's id (cse_...); claude.ai and the CLI name
  # the same session session_....
  def session_id(remote_id)
    remote_id.to_s.sub(/\Acse_/, "session_").presence
  end

  def url(remote_id)
    (id = session_id(remote_id)) && "https://claude.ai/code/#{id}"
  end

  # Sends Bobby's answer into the session. Returns [output, success?]. The
  # session's next Stop brings its reply back as a card.
  def reply(remote_id, text)
    argv = [ ClaudeCli.bin, "-p", text.to_s, "--cloud", session_id(remote_id) ]
    output, status = Open3.capture2e(ClaudeCli.env(login: true).merge("STACK_LAUNCHED" => "1"), *argv, chdir: ClaudeRun.chat_dir)
    [ output, status.success? ]
  rescue SystemCallError => e
    [ ClaudeCli.explain(e), false ]
  end
end
