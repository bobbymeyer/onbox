# Completes or reschedules a reminder in the Mac's Reminders. Failures come
# back as cards.
class ReminderActionJob < ApplicationJob
  queue_as :default

  def perform(card, action, time = nil)
    id = card.payload["reminder_id"] or return
    case action
    when "complete" then MacEventKit.complete(id)
    when "reschedule" then MacEventKit.reschedule(id, Time.zone.parse(time))
    end
  rescue MacEventKit::Error => e
    card.report_failure!("Couldn't #{action} the reminder \"#{card.summary}\"", e.message)
  end
end
