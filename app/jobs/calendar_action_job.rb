# RSVPs in Google Calendar. Failures come back as cards.
class CalendarActionJob < ApplicationJob
  queue_as :default

  def perform(card, kind, note = nil)
    source = card.source
    return card.report_failure!("Couldn't answer the invitation: no connected calendar", "", response: kind) unless source&.connected?

    GoogleCalendar::Calendar.new(source).respond(card.payload, kind, note)
  rescue Google::Apis::Error, Signet::AuthorizationError, ArgumentError => e
    card.report_failure!("Couldn't #{kind} \"#{card.payload["summary"]}\"", "#{e.class}: #{e.message}", response: kind)
  end
end
