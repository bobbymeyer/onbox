# Carries out an email card's action in the Mac's Mail: send the reply in its
# thread, archive it, or mark it read. Failures come back as cards.
class EmailActionJob < ApplicationJob
  queue_as :default

  def perform(card, kind, text = nil)
    id = card.payload["message_id"] or return
    case kind
    when "reply" then MacEventKit.mail_reply(id, text)
    when "archive" then MacEventKit.mail_archive(id)
    when "read" then MacEventKit.mail_read(id)
    end
  rescue MacEventKit::Error => e
    card.report_failure!("Couldn't #{kind == "read" ? "mark read" : kind} \"#{card.summary}\" in Mail", e.message, text: text)
  end
end
