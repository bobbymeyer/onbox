require "test_helper"

class NoticerTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  def reply_on_agent(text, session: SecureRandom.hex(4))
    Gestures.reply(agent_card(session_id: session), text)
  end

  test "phrases normalize across case, punctuation and ampersands" do
    assert_equal "pr and merge", Noticer.normalize("PR & merge.")
    assert_equal "pr and merge", Noticer.normalize("  pr and   merge ")
  end

  test "a reply typed three times becomes an offer card, once" do
    reply_on_agent("Ship it to staging")
    reply_on_agent("ship it to staging.")
    assert_empty Noticer.call("agent")

    reply_on_agent("Ship it to staging!")
    offer = Noticer.call("agent").sole
    assert_equal "stamp_offer", offer.card_type
    assert_equal "decision", offer.ask
    assert_equal "Ship it to staging!", offer.proposed_action
    assert_match "3 times", offer.summary
    assert_equal offer, Card.current

    reply_on_agent("ship it to staging")
    assert_empty Noticer.call("agent"), "never offered twice"
  end

  test "replies on other card types, long replies, and blank replies don't count" do
    3.times { |i| Gestures.reply(email_card(thread_id: "t#{i}", message_id: "m#{i}"), "Ship it to staging") }
    assert_empty Noticer.call("agent")

    long = "x" * 300
    3.times { reply_on_agent(long) }
    assert_empty Noticer.call("agent")
  end

  test "phrases that already are a stamp aren't offered" do
    3.times { reply_on_agent("Open a PR for onbox and merge it once CI is green.") }
    3.times { reply_on_agent("PR & merge") }
    assert_empty Noticer.call("agent")
  end

  test "accepting casts a stamp that does what the reply did" do
    3.times { reply_on_agent("Ship it to staging") }
    offer = Noticer.call("agent").sole

    stamp = Noticer.cast!(offer, label: "Staging", template: "Ship it to staging, then report the URL.")
    assert_equal [ "Staging", "agent", "instruct", "Ship it to staging, then report the URL." ],
                 [ stamp.label, stamp.card_type, stamp.action_kind, stamp.template ]
    assert offer.reload.handled?
    assert_equal "accepted", Noticing.sole.status

    card = agent_card(session_id: "new")
    assert_includes StampTray.for(card).shown.map(&:label), "Staging"
    assert_enqueued_with job: AgentDispatchJob, args: [ card, "Ship it to staging, then report the URL." ] do
      Gestures.stamp(card, stamp)
    end
  end

  test "email phrases become reply stamps" do
    3.times { |i| Gestures.reply(email_card(thread_id: "t#{i}", message_id: "m#{i}"), "Thanks, got it.") }
    offer = Noticer.call("email").sole
    assert_equal "reply", Noticer.cast!(offer, label: "", template: "").action_kind
  end

  test "declining leaves no stamp and the noticing declined" do
    3.times { reply_on_agent("Ship it to staging") }
    offer = Noticer.call("agent").sole
    assert_equal "pending", Noticing.sole.status

    Gestures.reply(offer, "")
    assert_equal "declined", Noticing.sole.status
    assert_no_difference("Stamp.count") { Noticer.call("agent") }
  end

  test "a reply enqueues the noticer for its card type" do
    assert_enqueued_with job: NoticerJob, args: [ "agent" ] do
      reply_on_agent("anything")
    end
  end
end
