class GmailPollJob < ApplicationJob
  queue_as :default

  def perform(source = nil)
    sources = source ? [ source ] : Source.email.select(&:connected?)
    sources.each do |s|
      Gmail::Sync.call(s)
    rescue Google::Apis::Error, Signet::AuthorizationError => e
      Rails.logger.warn("[gmail] #{s.name}: #{e.message}")
    end
  end
end
