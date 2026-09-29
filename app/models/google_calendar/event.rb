module GoogleCalendar
  # Flattens a Google Calendar event into the plain hash cards carry.
  module Event
    module_function

    def normalize(event)
      self_attendee = Array(event.attendees).find(&:self)
      {
        "event_id" => event.id,
        "series_id" => event.recurring_event_id.presence || event.id,
        "recurring" => event.recurring_event_id.present?,
        "status" => event.status,
        "updated" => event.updated&.iso8601,
        "summary" => event.summary.presence || "(no title)",
        "start" => time(event.start),
        "end" => time(event.end),
        "all_day" => event.start&.date.present?,
        "location" => event.location,
        "description" => event.description && ActionController::Base.helpers.strip_tags(event.description).squish.truncate(4000),
        "html_link" => event.html_link,
        "meet_link" => event.hangout_link,
        "organizer" => event.organizer&.display_name.presence || event.organizer&.email,
        "organizer_self" => !!event.organizer&.self,
        "attendees" => Array(event.attendees).first(30).map { |a| { "name" => a.display_name.presence || a.email, "response" => a.response_status } },
        "self_response" => self_attendee&.response_status
      }
    end

    def time(point)
      return if point.nil?
      point.date_time ? point.date_time.to_time.iso8601 : Time.zone.parse(point.date.to_s)&.iso8601
    end
  end
end
