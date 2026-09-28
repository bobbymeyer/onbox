require "test_helper"

class EmailTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test "an email becomes an email card keyed by thread, fronted by sender and subject" do
    card = email_card
    assert_equal [ "email", "gmail:thread:t1", "Ada Lovelace", "Dinner Thursday?", "reply" ],
                 [ card.card_type, card.key, card.project, card.summary, card.ask ]
    assert_equal "Are you free Thursday at 7?", card.payload["body"]
  end

  test "a new message in the thread refreshes its open card" do
    first = email_card
    again = email_card(message_id: "m2", body: "Or Friday?")
    assert_equal first.id, again.id
    assert_equal "Or Friday?", again.payload["body"]
  end

  test "mail from someone wakes cards held on them" do
    held = Card.create!(summary: "Waiting on Ada")
    held.hold!(event_key: "gmail:from:ada@example.com")
    email_card(thread_id: "other")
    assert held.reload.live?
  end

  test "replying sends in the thread; archive archives it" do
    card = email_card
    assert_enqueued_with job: EmailActionJob, args: [ card, "reply", "Thursday works." ] do
      Gestures.reply(card, "Thursday works.")
    end

    other = email_card(thread_id: "t2", message_id: "m9")
    assert_enqueued_with job: EmailActionJob, args: [ other, "archive", nil ] do
      Gestures.stamp(other, stamps(:archive))
    end
    assert other.handled?
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

  test "the Gmail refresh token is encrypted at rest" do
    source = connect(sources(:gmail))
    raw = Source.connection.select_value("SELECT secret FROM sources WHERE id = #{source.id}")
    assert_not_includes raw, "refresh-token"
    assert_equal "refresh-token", source.reload.secret
  end

  test "email actions run against the mailbox" do
    card = email_card
    connect(card.source)
    mailbox = FakeMailbox.new
    with_stub(Gmail::Mailbox, :new, mailbox) do
      EmailActionJob.perform_now(card, "reply", "Yes.")
      EmailActionJob.perform_now(card, "archive")
    end
    assert_equal [ [ :reply, "t1", "Yes." ], [ :archive, "t1" ] ], mailbox.calls
  end

  test "an email action on an unconnected mailbox comes back as a card" do
    card = email_card
    EmailActionJob.perform_now(card, "reply", "Yes.")
    assert_match "no connected mailbox", card.children.sole.summary
  end
end

class SecretaryEventKeysTest < ActiveSupport::TestCase
  test "an email card's sender is a known event key for Later" do
    card = Intake.receive(sources(:gmail), email_payload).reload
    assert_includes Secretary.new.send(:known_event_keys, card), "gmail:from:ada@example.com"
  end
end
