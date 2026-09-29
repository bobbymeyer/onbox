require "open3"

# The Mac's Calendar and Reminders, through a small Swift helper that uses
# EventKit (script/eventkit). onbox builds it the first time it's needed,
# with the Xcode command line tools, and talks to it in JSON. macOS asks once
# for permission to read calendars and reminders.
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

  # { "calendar" => "granted" | "denied" | "not_determined" | ..., "reminders" => ... }
  def access = run("access")
  def request_access = run("request")

  def events(from:, to:) = run("events", from.utc.iso8601, to.utc.iso8601)
  def reminders = run("reminders")
  def complete(id) = run("complete", id)
  def reschedule(id, time) = run("reschedule", id, time.utc.iso8601)

  def granted?(kind)
    access[kind] == "granted"
  rescue Error
    false
  end

  def run(*args)
    raise Error, "Calendar and Reminders need onbox to run on the Mac" unless available?
    build! unless ENV["STACK_EVENTKIT_BIN"].present?

    output, error, status = Open3.capture3(bin, *args)
    raise Error, (error.presence || output).strip.truncate(500) unless status.success?
    JSON.parse(output)
  rescue SystemCallError, JSON::ParserError => e
    raise Error, e.message
  end

  # Compiles the helper when it's missing or older than its source.
  def build!
    return if File.exist?(bin) && File.mtime(bin) >= [ File.mtime(SOURCE), File.mtime(PLIST) ].max

    FileUtils.mkdir_p(File.dirname(bin))
    output, status = Open3.capture2e("xcrun", "swiftc", "-O", "-o", bin, SOURCE.to_s,
      "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", PLIST.to_s)
    raise Error, "couldn't build the Calendar/Reminders helper (install the Xcode command line tools: xcode-select --install): #{output.strip.truncate(400)}" unless status.success?
  rescue SystemCallError => e
    raise Error, "couldn't build the Calendar/Reminders helper: #{e.message} (xcode-select --install)"
  end
end
