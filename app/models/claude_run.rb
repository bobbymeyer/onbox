require "open3"

# One headless Claude Code turn that onbox started: a new chat, a new session
# in a project, or Bobby's reply to an agent card resuming its session. It
# runs `claude -p` on Bobby's login (his Max plan) in its own process group,
# so it outlives an onbox restart, and writes its JSON result to a file. When
# it exits, the reply becomes (or refreshes) the session's card; a failure
# comes back as a card too. Permission prompts go to the stack as Allow/Deny
# cards through the stack MCP bridge (script/stack-mcp).
class ClaudeRun < ApplicationRecord
  STATES = %w[running finished failed stopped].freeze
  # How long a run may wait on a tool call, such as Bobby answering a
  # permission card: a week.
  TOOL_TIMEOUT_MS = 7.days.in_milliseconds.to_i.to_s

  belongs_to :card, optional: true
  belongs_to :result_card, class_name: "Card", optional: true

  validates :state, inclusion: { in: STATES }
  validates :prompt, :cwd, presence: true

  scope :running, -> { where(state: "running") }

  # The thread waiting on the process (tests join it).
  attr_reader :watcher
  scope :recent, -> { order(created_at: :desc) }

  def self.home
    Pathname(ENV["STACK_CLAUDE_HOME"].presence || (Rails.env.test? ? Rails.root.join("tmp/claude", Process.pid.to_s) : Rails.root.join("storage/claude"))).tap(&:mkpath)
  end

  # Where a new chat runs: one scratch folder, each chat its own session.
  def self.chat_dir
    home.join("chat").tap(&:mkpath).to_s
  end

  # Starts a turn and returns the run. session_id resumes that session;
  # card is the card being answered, which gets any failure.
  def self.start!(prompt:, cwd:, session_id: nil, card: nil)
    run = create!(prompt: prompt, cwd: cwd, session_id: session_id.presence, card: card)
    run.launch!
    run
  end

  # Checks runs whose watcher went away (an onbox restart) and finishes the
  # ones that have exited.
  def self.sweep!
    running.find_each { |run| run.finish! unless run.alive? }
  end

  def running? = state == "running"
  def failed? = state == "failed"
  def chat? = cwd == self.class.chat_dir
  def project = chat? ? "chat" : File.basename(cwd)

  def launch!
    File.write(path("prompt"), prompt)
    pid = Process.spawn(env, *argv, chdir: cwd, in: path("prompt"), out: path("out"), err: path("err"), pgroup: true)
    update!(pid: pid)
    watch(pid)
  rescue SystemCallError => e
    fail!(ClaudeCli.explain(e))
  end

  def argv
    args = [ ClaudeCli.bin, "-p", "--output-format", "json" ]
    args += [ "--resume", session_id ] if session_id
    if (config = StackMcp.config_file(self))
      args += [ "--mcp-config", config, "--permission-prompt-tool", StackMcp::APPROVE_TOOL ]
    end
    args += [ "--permission-mode", ENV["STACK_CLAUDE_PERMISSION_MODE"] ] if ENV["STACK_CLAUDE_PERMISSION_MODE"].present?
    args
  end

  # The CLI's own environment on Bobby's login, marked as started by onbox
  # (so the stack hook leaves the reply to onbox), with room to wait on him.
  def env
    ClaudeCli.env.merge(
      "STACK_LAUNCHED" => "1", "STACK_RUN_ID" => id.to_s,
      "MCP_TOOL_TIMEOUT" => TOOL_TIMEOUT_MS, "CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT" => TOOL_TIMEOUT_MS
    )
  end

  def alive?
    pid.present? && Process.kill(0, pid) && true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end

  # Stops the turn and everything it started.
  def stop!
    return unless running?
    update!(state: "stopped", error: "Stopped from onbox", finished_at: Time.current)
    Process.kill("TERM", -pid) if pid
  rescue Errno::ESRCH
    nil
  end

  # Turns the result into a card. Safe to call more than once.
  def finish!(exit_status = nil)
    with_lock do
      return unless running?
      envelope = result_envelope
      if exit_status.to_i.zero? && envelope && !envelope["is_error"] && envelope["result"].present?
        succeed!(envelope, exit_status)
      else
        fail!(envelope&.dig("result").presence || stderr_tail.presence || "Claude Code exited without a reply", exit_status: exit_status, envelope: envelope)
      end
    end
  end

  def path(kind) = self.class.home.join("runs").tap(&:mkpath).join("#{id}-#{created_at.to_i}.#{kind}").to_s

  private
    # Waits on the process in the background and finishes the run when it
    # exits. The sweeper covers the case where onbox restarts first.
    def watch(pid)
      @watcher = Thread.new do
        _, status = Process.wait2(pid)
        Rails.application.executor.wrap { self.class.find(id).finish!(status.exitstatus) }
      rescue Errno::ECHILD
        nil
      end
    end

    def succeed!(envelope, exit_status)
      sid = envelope["session_id"].presence || session_id
      result = Intake.receive(self.class.source, {
        "session_id" => sid, "hook_event_name" => "Stop", "cwd" => cwd,
        "last_assistant_message" => envelope["result"], "run_id" => id, "launched_by" => "onbox"
      })
      update!(state: "finished", session_id: sid, exit_status: exit_status, cost_usd: envelope["total_cost_usd"],
              result_card: result, finished_at: Time.current)
    end

    def fail!(message, exit_status: nil, envelope: nil)
      update!(state: "failed", error: message.to_s.truncate(4000), exit_status: exit_status,
              session_id: envelope&.dig("session_id").presence || session_id, finished_at: Time.current)
      summary = "Claude couldn't finish in #{project}"
      if card
        card.report_failure!(summary, message, prompt: prompt, run_id: id)
      else
        Card.create!(source: self.class.source, card_type: "generic", project: project, summary: summary, ask: "review",
                     payload: { "prompt" => prompt, "run_id" => id, "body" => message.to_s.last(4000) })
      end
    end

    def result_envelope
      File.read(path("out")).lines.reverse_each do |line|
        parsed = JSON.parse(line) rescue next
        return parsed if parsed.is_a?(Hash)
      end
      nil
    rescue Errno::ENOENT
      nil
    end

    def stderr_tail
      File.read(path("err")).strip.last(2000)
    rescue Errno::ENOENT
      nil
    end

    class << self
      # The source runs' cards arrive under: the Claude Code one.
      def source
        Source.find_by(name: "claude-code", kind: "claude_code") || Source.find_by(kind: "claude_code") ||
          Source.create!(name: "claude-code", kind: "claude_code")
      end
    end
end
