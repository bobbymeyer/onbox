require "test_helper"

class EmailTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test "an email becomes an email card keyed by thread, fronted by sender and subject" do
    card = email_card
    assert_equal [ "email", "mail:thread:t1@mail.example", "Ada Lovelace", "Dinner Thursday?", "reply" ],
                 [ card.card_type, card.key, card.project, card.summary, card.ask ]
    assert_equal "Are you free Thursday at 7?", card.payload["body"]
  end

  test "a new message in the thread refreshes its open card" do
    first = email_card
    again = email_card(message_id: "m2@mail.example", body: "Or Friday?")
    assert_equal first.id, again.id
    assert_equal "Or Friday?", again.payload["body"]
  end

  test "mail from someone wakes cards held on them" do
    held = Card.create!(summary: "Waiting on Ada")
    held.hold!(event_key: "mail:from:ada@example.com")
    email_card(thread_id: "other")
    assert held.reload.live?
  end

  test "replying sends in the thread; archive archives it; anything else marks it read" do
    card = email_card
    assert_enqueued_with job: EmailActionJob, args: [ card, "reply", "Thursday works." ] do
      Gestures.reply(card, "Thursday works.")
    end

    other = email_card(thread_id: "t2", message_id: "m9")
    assert_enqueued_with job: EmailActionJob, args: [ other, "archive", nil ] do
      Gestures.stamp(other, stamps(:archive))
    end
    assert other.handled?

    done = email_card(thread_id: "t3", message_id: "m10")
    assert_enqueued_with job: EmailActionJob, args: [ done, "read", nil ] do
      Gestures.stamp(done, stamps(:done))
    end

    empty = email_card(thread_id: "t4", message_id: "m11")
    assert_enqueued_with job: EmailActionJob, args: [ empty, "read", nil ] do
      Gestures.reply(empty, "")
    end
  end

  test "Approve on an email sends the drafted reply" do
    card = email_card
    card.update!(proposed_action: "Thursday works.")
    assert_enqueued_with job: EmailActionJob, args: [ card, "reply", "Thursday works." ] do
      Gestures.stamp(card, stamps(:approve))
    end
  end

  test "the tray only offers stamps the card type can carry out" do
    email = StampTray.for(email_card).shown.map(&:label)
    assert_includes email, "Archive"
    assert_not_includes email, "PR and merge"

    agent = StampTray.for(agent_card).shown.map(&:label)
    assert_not_includes agent, "Archive"
  end

  test "email actions run in Mail, by Message-ID" do
    card = email_card
    calls = []
    originals = %i[mail_reply mail_archive mail_read].to_h { |name| [ name, MacEventKit.method(name) ] }
    originals.each_key { |name| MacEventKit.define_singleton_method(name) { |*args| calls << [ name, *args ] } }
    EmailActionJob.perform_now(card, "reply", "Yes.")
    EmailActionJob.perform_now(card, "archive")
    EmailActionJob.perform_now(card, "read")
    assert_equal [ [ :mail_reply, "m1@mail.example", "Yes." ], [ :mail_archive, "m1@mail.example" ], [ :mail_read, "m1@mail.example" ] ], calls
  ensure
    originals&.each { |name, original| MacEventKit.define_singleton_method(name, original) }
  end

  test "an email action Mail can't carry out comes back as a card" do
    card = email_card
    with_env("STACK_EVENTKIT_BIN" => nil) do
      skip "running on a Mac" if MacEventKit.available?
      EmailActionJob.perform_now(card, "reply", "Yes.")
    end
    failure = card.children.sole
    assert_equal "Couldn't reply \"Dinner Thursday?\" in Mail", failure.summary
    assert_equal "Yes.", failure.payload["text"]
  end
end

class MacMailTest < ActiveSupport::TestCase
  NOW = Time.zone.parse("2026-09-30T10:00:00Z")

  def sync(messages, now: NOW)
    kit = FakeKit.new(mail: messages)
    cards = travel_to(now) { MacMail::Sync.call(sources(:mail), kit: kit, now: now) }
    [ cards, kit ]
  end

  test "new unread inbox mail becomes cards, once" do
    cards, = sync([ mail_message ])
    card = cards.sole
    assert_equal [ "email", "Dinner Thursday?", "Ada Lovelace" ], [ card.card_type, card.summary, card.project ]
    assert_equal "iCloud", card.payload["account"]

    again, kit = sync([ mail_message ], now: NOW + 2.minutes)
    assert_empty again
    assert_equal [ [ :mail_messages, [] ] ], kit.calls, "seen mail isn't fetched again"
    assert_equal NOW + 2.minutes, sources(:mail).reload.last_polled_at
  end

  test "mail from a day before the first read on counts, even when Mail downloads it late" do
    old = mail_message(message_id: "old", received: (NOW - 2.days).iso8601)
    cards, = sync([ old, mail_message ])
    assert_equal [ "m1@mail.example" ], cards.map { |c| c.payload["message_id"] }

    late = mail_message(message_id: "late", subject: "Late", received: (NOW - 3.hours).iso8601)
    cards, = sync([ old, mail_message, late ], now: NOW + 1.hour)
    assert_equal [ "Late" ], cards.map(&:summary)
  end

  test "junk, and newsletters unless included, stay in Mail" do
    junk = mail_message(message_id: "junk", junk: true)
    bulk = "List-Unsubscribe: <mailto:x@list.example>\nPrecedence: bulk\n"
    news = mail_message(message_id: "news", subject: "This week", headers: bulk)
    cards, = sync([ junk, news, mail_message ])
    assert_equal [ "Dinner Thursday?" ], cards.map(&:summary)

    _, kit = sync([ junk, news, mail_message ], now: NOW + 2.minutes)
    assert_equal [ [ :mail_messages, [] ] ], kit.calls, "a skipped newsletter isn't fetched again"

    sources(:mail).update!(settings: sources(:mail).settings.merge("include_bulk" => true))
    more = mail_message(message_id: "news2", subject: "Next week", headers: bulk)
    cards, = sync([ junk, news, more, mail_message ], now: NOW + 4.minutes)
    assert_equal [ "Next week" ], cards.map(&:summary)
  end

  test "a reply joins its thread's card" do
    sync([ mail_message ])
    reply = mail_message(message_id: "m2@mail.example", subject: "Re: Dinner Thursday?", body: "Or Friday?",
                         headers: "In-Reply-To: <m1@mail.example>\nReferences: <m1@mail.example>\n")
    card = sync([ mail_message, reply ], now: NOW + 2.minutes).first.sole
    assert_equal "mail:thread:m1@mail.example", card.key
    assert_equal 1, Card.where(card_type: "email").count
    assert_equal "Or Friday?", card.payload["body"]
  end

  test "mail read, archived or deleted in Mail clears its card" do
    card = sync([ mail_message ]).first.sole
    sync([ mail_message(read: true) ], now: NOW + 2.minutes)
    assert card.reload.handled?
    assert_equal "read in Mail", card.handled_with
  end

  test "headers: folded lines, threads and bulk mail" do
    headers = MacMail::Message.parse_headers("References: <a@x>\n <b@x>\nList-ID: News <news.example>\nSubject: Hi\n")
    assert_equal "<a@x> <b@x>", headers["references"]
    assert_equal "a@x", MacMail::Message.thread_root(headers)
    assert MacMail::Message.bulk?(headers)
    assert_not MacMail::Message.bulk?(MacMail::Message.parse_headers("Auto-Submitted: no\n"))
    assert MacMail::Message.bulk?(MacMail::Message.parse_headers("Auto-Submitted: auto-generated\n"))
  end
end

class SecretaryEventKeysTest < ActiveSupport::TestCase
  test "an email card's sender is a known event key for Later" do
    card = Intake.receive(sources(:mail), email_payload).reload
    assert_includes Secretary.new.send(:known_event_keys, card), "mail:from:ada@example.com"
  end
end
