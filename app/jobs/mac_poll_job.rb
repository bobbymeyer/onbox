# Reads the Mac's Calendar and Reminders into the stack.
class MacPollJob < ApplicationJob
  queue_as :default

  def perform
    return unless MacEventKit.available?

    Source.mac.select(&:connected?).each do |source|
      source.poll!
    rescue MacEventKit::Error => e
      Rails.logger.warn("[mac] #{source.name}: #{e.message}")
    end
  end
end
