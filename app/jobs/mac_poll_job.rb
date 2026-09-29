# Reads the Mac's Calendar and Reminders into the stack.
class MacPollJob < ApplicationJob
  queue_as :default

  def perform
    return unless MacEventKit.available?

    connected, unconnected = Source.mac.partition(&:connected?)
    Rails.logger.info("[mac] skipped #{unconnected.map(&:name).sort.join(", ")}: not allowed in macOS") if unconnected.any?

    connected.each do |source|
      source.poll!
    rescue MacEventKit::Error => e
      Rails.logger.warn("[mac] #{source.name}: #{e.message}")
    end
  end
end
