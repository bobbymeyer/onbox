class CalendarPollJob < ApplicationJob
  queue_as :default

  def perform
    Source.calendar.select(&:connected?).each do |source|
      source.poll!
    rescue Google::Apis::Error, Signet::AuthorizationError => e
      Rails.logger.warn("[calendar] #{source.name}: #{e.message}")
    end
  end
end
