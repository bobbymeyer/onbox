require "open3"
require "shellwords"

# Sends an instruction back to a Claude Code session. Runs through the claude
# CLI on Bobby's login, so the turn counts against his Max plan (see
# ClaudeCli). The command is a template so it can be pointed elsewhere (a tmux
# send-keys, a wrapper script); placeholders are substituted per argument,
# never through a shell. The agent's Stop hook fires as usual and brings the
# result back as a card.
module AgentDispatch
  DEFAULT_COMMAND = "{claude} --resume {session_id} -p {instruction}".freeze

  module_function

  def argv(session_id:, instruction:, cwd: nil)
    template = ENV.fetch("STACK_AGENT_COMMAND", DEFAULT_COMMAND)
    values = { "claude" => ClaudeCli.bin, "session_id" => session_id.to_s, "instruction" => instruction.to_s, "cwd" => cwd.to_s }
    Shellwords.split(template).map { |arg| arg.gsub(/\{(\w+)\}/) { values.fetch($1, "") } }
  end

  # Returns [output, success?].
  def call(session_id:, instruction:, cwd: nil)
    dir = cwd.present? && File.directory?(cwd) ? cwd : Dir.home
    output, status = Open3.capture2e(ClaudeCli.env, *argv(session_id: session_id, instruction: instruction, cwd: cwd), chdir: dir)
    [ output, status.success? ]
  rescue SystemCallError => e
    [ e.message, false ]
  end
end
