require "open3"

# The Mac's Calendar, Reminders and Mail, through a small Swift helper
# (script/eventkit): EventKit for the first two, Mail's scripting interface for
# the third. onbox builds it the first time it's needed, with the Xcode command
# line tools, and talks to it in JSON. macOS asks once for each.
module MacEventKit
  SOURCE = Rails.root.join("script/eventkit/onbox-eventkit.swift")
  PLIST = Rails.root.join("script/eventkit/Info.plist")

  class Error < StandardError; end

  module_function

  def available?
    RUBY_PLATFORM.include?("darwin") || ENV["STACK_EVENTKIT_BIN"].present?
  end

  def bin
    ENV["STACK_EVENTKIT_BIN"].presence || Rails.root.join("tmp/bin/onbox-eventkit").to_s
  end

  TIMEOUT = 90 # Mail can be slow to answer while it syncs
  REQUEST_TIMEOUT = 180 # waits on Bobby clicking Allow

  # { "calendar" => "granted" | "denied" | "not_determined" | ..., "reminders" => ... }
  def access = run("access")
  # kind: "calendar", "reminders" or "mail". Returns { kind => status }.
  def request_access(kind) = run("request", kind, timeout: REQUEST_TIMEOUT)

  def mail_access = run("mail-access")["mail"]
  def mail_unread = run("mail-unread")
  def mail_messages(ids) = ids.empty? ? [] : run("mail-messages", *ids)
  def mail_reply(id, text) = run("mail-reply", id, text)
  def mail_archive(id) = run("mail-archive", id)
  def mail_read(id) = run("mail-read", id)

  def events(from:, to:) = run("events", from.utc.iso8601, to.utc.iso8601)
  def reminders = run("reminders")
  def complete(id) = run("complete", id)
  def reschedule(id, time) = run("reschedule", id, time.utc.iso8601)

  def granted?(kind)
    (kind == "mail" ? mail_access : access[kind]) == "granted"
  rescue Error
    false
  end

  def run(*args, timeout: TIMEOUT)
    raise Error, "Calendar, Reminders and Mail need onbox to run on the Mac" unless available?
    build! unless ENV["STACK_EVENTKIT_BIN"].present?

    Open3.popen3(bin, *args) do |stdin, stdout, stderr, wait|
      stdin.close
      output, error = Thread.new { stdout.read }, Thread.new { stderr.read }
      unless wait.join(timeout)
        Process.kill("KILL", wait.pid)
        raise Error, "the Mac helper didn't answer #{args.first} within #{timeout}s"
      end
      raise Error, (error.value.presence || output.value).strip.truncate(500) unless wait.value.success?
      JSON.parse(output.value)
    end
  rescue SystemCallError, JSON::ParserError => e
    raise Error, e.message
  end

  # Compiles the helper when it's missing or older than its source.
  def build!
    return if File.exist?(bin) && File.mtime(bin) >= [ File.mtime(SOURCE), File.mtime(PLIST) ].max

    FileUtils.mkdir_p(File.dirname(bin))
    output, status = Open3.capture2e("xcrun", "swiftc", "-O", "-o", bin, SOURCE.to_s,
      "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", PLIST.to_s)
    raise Error, "couldn't build the Mac helper (install the Xcode command line tools: xcode-select --install): #{output.strip.truncate(400)}" unless status.success?
  rescue SystemCallError => e
    raise Error, "couldn't build the Mac helper: #{e.message} (xcode-select --install)"
  end
end
