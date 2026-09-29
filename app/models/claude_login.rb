require "pty"
require "io/console"

# Connects onbox to Bobby's Claude account from the web interface by driving
# the official CLI's own sign-in, `claude setup-token`, in a pseudo-terminal:
#   1. start!  runs it and picks out the claude.com sign-in link it prints;
#   2. Bobby opens the link, approves, and pastes back the code Claude shows;
#   3. submit  types the code into the CLI, which prints a long-lived token
#      (inference scope, one year). Onbox stores it encrypted and only ever
#      hands it back to the CLI (see ClaudeCli.env).
# Onbox never talks to Claude's sign-in itself. The session lives in this
# server process for ten minutes at most.
class ClaudeLogin
  URL_PATTERN = %r{https://claude\.(?:com|ai)/[^\s\a\e"'<>]*oauth/authorize\?[^\s\a\e"'<>]+}
  TOKEN_PATTERN = /sk-ant-oat\d*-[A-Za-z0-9_-]{20,}/
  LIFETIME = 10.minutes
  URL_WAIT = 20.seconds
  TOKEN_WAIT = 60.seconds

  class Failed < StandardError; end

  @lock = Mutex.new

  class << self
    def current
      @lock.synchronize { @current if @current&.alive? }
    end

    # Starts a fresh sign-in, replacing any in progress.
    def start!
      @lock.synchronize do
        @current&.stop
        @current = new.tap(&:spawn)
      end
    end

    def cancel!
      @lock.synchronize do
        @current&.stop
        @current = nil
      end
    end
  end

  attr_reader :started_at

  def spawn
    @started_at = Time.current
    @buffer = +""
    @buffer_lock = Mutex.new
    env = ClaudeCli.env.merge("CLAUDE_CODE_OAUTH_TOKEN" => nil, "BROWSER" => "true")
    @reader, @writer, @pid = PTY.spawn(env, ClaudeCli.bin, "setup-token", chdir: ClaudeCli.workdir)
    @reader.winsize = [ 60, 1000 ] # wide enough that nothing wraps
    Process.detach(@pid)
    @thread = Thread.new { read_output }

    wait_until(URL_WAIT) { url || exited? }
    raise Failed, "claude didn't offer a sign-in link: #{tail}" unless url
  rescue SystemCallError => e
    raise Failed, "couldn't run #{ClaudeCli.bin}: #{e.message}"
  end

  def url
    output[URL_PATTERN]
  end

  # Types the code Claude showed into the CLI and stores the token it prints.
  def submit(code)
    raise Failed, "the sign-in expired; start again" unless alive?

    @writer.write("#{code.to_s.strip}\r")
    wait_until(TOKEN_WAIT) { token || exited? }
    found = token or raise Failed, "claude didn't accept that code: #{tail}"
    Credential.store_claude_token!(found)
  ensure
    stop if token || exited?
  end

  def alive?
    !exited? && Time.current - started_at < LIFETIME
  end

  def stop
    Process.kill("TERM", @pid) if @pid && !exited?
  rescue Errno::ESRCH
    nil
  ensure
    @exited = true
    @buffer_lock&.synchronize { @buffer.clear } # the token must not linger
  end

  private
    def exited? = @exited

    def token
      output[TOKEN_PATTERN]
    end

    def output
      @buffer_lock.synchronize { @buffer.dup }
    end

    def read_output
      loop { chunk = @reader.readpartial(4096); @buffer_lock.synchronize { @buffer << chunk } }
    rescue EOFError, IOError, Errno::EIO
      nil
    ensure
      @exited = true
    end

    def wait_until(limit)
      deadline = Time.current + limit
      sleep 0.1 until yield || Time.current > deadline
    end

    # The last readable words the CLI printed, for error messages.
    def tail
      text = output.gsub(/\e\][^\a\e]*(?:\a|\e\\)/, "").gsub(/\e\[[0-9;?>]*[a-zA-Z~]/, "").gsub(/[^[:print:]\n]/, "")
      text.gsub(TOKEN_PATTERN, "[token]").split("\n").map(&:strip).compact_blank.last(3).join(" ").truncate(300).presence || "no output"
    end
end
