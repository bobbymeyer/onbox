# Carries out an email card's action in Gmail: send the reply in its thread,
# or archive the thread. Failures come back as cards.
class EmailActionJob < ApplicationJob
  queue_as :default

  def perform(card, kind, text = nil)
    source = card.source
    return card.report_failure!("Couldn't #{kind} email: no connected mailbox", "", text: text) unless source&.connected?

    mailbox = Gmail::Mailbox.new(source)
    case kind
    when "reply" then mailbox.reply(card.payload, text)
    when "archive" then mailbox.archive(card.payload["thread_id"])
    end
  rescue Google::Apis::Error, Signet::AuthorizationError => e
    card.report_failure!("Couldn't #{kind} \"#{card.summary}\"", "#{e.class}: #{e.message}", text: text)
  end
end
