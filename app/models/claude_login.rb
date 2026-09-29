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
  ENTER_DELAY = 0.5

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
    env = ClaudeCli.env.merge("CLAUDE_CODE_OAUTH_TOKEN" => nil, "BROWSER" => "true", "TERM" => "xterm-256color")
    @reader, @writer, @pid = PTY.spawn(env, ClaudeCli.bin, "setup-token", chdir: ClaudeCli.workdir)
    @reader.winsize = [ 60, 1000 ] # wide enough that nothing wraps
    Process.detach(@pid)
    @thread = Thread.new { read_output }

    wait_until(URL_WAIT) { url || exited? }
    raise Failed, "claude didn't offer a sign-in link: #{tail}" unless url
  rescue SystemCallError => e
    raise Failed, ClaudeCli.explain(e)
  end

  def url
    output[URL_PATTERN]
  end

  # Types the code Claude showed into the CLI and stores the token it prints.
  # A sign-in gets one try: after a rejected code the CLI moves on to a new
  # challenge, so this one is ended and the caller starts a fresh one.
  def submit(pasted)
    raise Failed, "the sign-in expired; start again" unless alive?

    # Type the code, then press Enter on its own: sent together, some versions
    # take the burst as a paste and the Enter never submits.
    typed_at = output.bytesize
    @writer.write(self.class.normalize_code(pasted))
    sleep ENTER_DELAY
    @writer.write("\r")
    wait_until(TOKEN_WAIT) { token || exited? || rejected?(since: typed_at) }
    found = token
    unless found
      Rails.logger.warn("[claude login] no token; CLI said: #{reason}")
      raise Failed, output.bytesize > typed_at ? "Claude didn't accept that code (#{reason})" : "Claude Code didn't respond to the code"
    end
    Credential.store_claude_token!(found)
  ensure
    stop
  end

  # Claude's page shows the code as "code#state". Take it with stray
  # whitespace from a phone copy, or as the callback page's address.
  def self.normalize_code(pasted)
    text = pasted.to_s.gsub(/\s+/, "")
    if text.match?(%r{\Ahttps?://}) && text.include?("code=")
      query = Rack::Utils.parse_query(URI(text).query.to_s)
      text = [ query["code"], query["state"] ].compact_blank.join("#")
    end
    text
  rescue URI::InvalidURIError
    text
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
      loop do
        chunk = @reader.readpartial(4096)
        @buffer_lock.synchronize { @buffer << chunk }
        answer_queries(chunk)
      end
    rescue EOFError, IOError, Errno::EIO
      nil
    ensure
      @exited = true
    end

    # Answer what a real terminal would, so a CLI that asks about its
    # terminal before taking input isn't left waiting.
    TERMINAL_ANSWERS = {
      "\e[c" => "\e[?62;22c",     # device attributes
      "\e[0c" => "\e[?62;22c",
      "\e[>0q" => "\eP>|onbox\e\\", # terminal name and version
      "\e[?u" => "\e[?0u",        # keyboard protocol flags
      "\e[6n" => "\e[1;1R"        # cursor position
    }.freeze

    def answer_queries(chunk)
      TERMINAL_ANSWERS.each { |query, answer| @writer.write(answer) if chunk.include?(query) }
    rescue IOError, Errno::EIO
      nil
    end

    def rejected?(since:)
      output.byteslice(since..).to_s.match?(/error|invalid|retry/i)
    end

    def wait_until(limit)
      deadline = Time.current + limit
      sleep 0.1 until yield || Time.current > deadline
    end

    # What the CLI said went wrong, without its retry prompt.
    def reason
      tail.sub(/\A.*?prompted\s*>\s*\**\S*\s*/, "").sub(/\s*Press Enter to retry\.?\s*\z/i, "").presence || "no reason given"
    end

    # The last readable words the CLI printed, for error messages.
    def tail
      text = output.gsub(/\e\][^\a\e]*(?:\a|\e\\)/, "").gsub(/\e\[[0-9;?>]*[a-zA-Z~]/, "").gsub(/[^[:print:]\n]/, "")
      text.gsub(TOKEN_PATTERN, "[token]").split("\n").map(&:strip).compact_blank.last(3).join(" ").truncate(300).presence || "no output"
    end
end
