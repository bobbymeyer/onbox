require "test_helper"

class GmailTest < ActiveSupport::TestCase
  G = Google::Apis::GmailV1

  def header(name, value) = G::MessagePartHeader.new(name: name, value: value)
  def part(mime, data = nil, parts: nil) = G::MessagePart.new(mime_type: mime, body: G::MessagePartBody.new(data: data), parts: parts)

  def api_message(payload)
    payload.headers = [ header("From", "Ada <ada@example.com>"), header("Subject", "Hi"), header("Message-ID", "<x@y>") ]
    G::Message.new(id: "m1", thread_id: "t1", snippet: "Hi there", label_ids: [ "INBOX" ], payload: payload)
  end

  test "normalizes headers and prefers the plain-text part" do
    msg = api_message(part("multipart/alternative", parts: [ part("text/html", "<p>html</p>"), part("text/plain", "plain body") ]))
    n = Gmail::Message.normalize(msg)
    assert_equal [ "m1", "t1", "Ada <ada@example.com>", "Hi", "<x@y>", "plain body" ],
                 n.values_at("message_id", "thread_id", "from", "subject", "rfc822_message_id", "body")
  end

  test "falls back to stripped HTML" do
    n = Gmail::Message.normalize(api_message(part("text/html", "<p>Hello <b>you</b></p>")))
    assert_equal "Hello you", n["body"]
  end

  test "reply goes to the sender in the thread, with threading headers" do
    sent = []
    service = Object.new
    service.define_singleton_method(:send_user_message) { |_user, message| sent << message }

    mailbox = Gmail::Mailbox.new(sources(:gmail))
    mailbox.instance_variable_set(:@service, service)
    mailbox.reply(email_payload(references: "<old@mail>"), "Thursday works.")

    message = sent.sole
    mail = Mail.new(message.raw)
    assert_equal "t1", message.thread_id
    assert_equal [ "ada@example.com" ], mail.to
    assert_equal "Re: Dinner Thursday?", mail.subject
    assert_equal "abc@mail.example", mail.in_reply_to
    assert_equal [ "old@mail", "abc@mail.example" ], mail.references
    assert_equal "Thursday works.", mail.body.decoded
  end

  test "sync turns new mail into cards, skipping sent and already-seen mail" do
    source = connect(sources(:gmail))
    email_card(message_id: "seen", thread_id: "t0")
    mailbox = FakeMailbox.new([
      email_payload(message_id: "new", thread_id: "t5"),
      email_payload(message_id: "seen", thread_id: "t0"),
      email_payload(message_id: "mine", thread_id: "t6", labels: [ "SENT" ])
    ])

    now = Time.current.change(usec: 0)
    cards = Gmail::Sync.call(source, mailbox: mailbox, now: now)

    assert_equal [ "new" ], cards.map { |c| c.payload["message_id"] }
    _, query, after = mailbox.calls.sole
    assert_equal "in:inbox category:primary", query
    assert_equal now - 1.day - 5.minutes, after
    assert_equal now, source.reload.last_polled_at

    Gmail::Sync.call(source, mailbox: mailbox, now: now + 2.minutes)
    assert_equal now - 5.minutes, mailbox.calls.last.last
  end

  test "sync refuses an unconnected source" do
    assert_raises(ArgumentError) { Gmail::Sync.call(sources(:gmail), mailbox: FakeMailbox.new) }
  end
end
