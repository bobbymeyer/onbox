# Reads the Mac's Calendar and Reminders into the stack.
class MacPollJob < ApplicationJob
  queue_as :default

  def perform
    return unless MacEventKit.available?

    connected, skipped = Source.mac.partition(&:connected?)

    # A mac source whose access is not granted is dropped by connected?, and the
    # rescue below only ever fires for one that got PAST it. So this job used to
    # do its work and write nothing at all every two minutes, and two sources
    # sitting at not_determined looked exactly like two quiet ones -- which is
    # what they did for a day after onbox went native, with every probe on the
    # machine green.
    #
    # Named rather than counted, because "which one" is the whole question: the
    # grants are separate, and Calendar approved while Reminders is not is a
    # different problem from neither being approved.
    #
    # Silent in the steady state: once both grants land, `skipped` is empty and
    # this logs nothing. The line exists only while something is actually wrong,
    # which matters because onbox's log does not rotate.
    if skipped.any?
      Rails.logger.info("[mac] skipped, access not granted: #{skipped.map(&:name).join(', ')}")
    end

    connected.each do |source|
      source.poll!
    rescue MacEventKit::Error => e
      Rails.logger.warn("[mac] #{source.name}: #{e.message}")
    end
  end
end
