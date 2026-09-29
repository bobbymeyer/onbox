require "test_helper"

class JudgeTest < ActiveSupport::TestCase
  JUDGE = { "STACK_JUDGE_URL" => "http://127.0.0.1:9300" }.freeze

  setup do
    @card = Card.create!(summary: "Printer is out of toner", project: "office", source: sources(:printer), card_type: "generic")
    @receipts = Directive.create!(text: "Hold receipts until evening")
    @outages = Directive.create!(text: "Outages go to the front")
  end

  test "off unless STACK_JUDGE_URL is set, and the URL may carry /v1" do
    assert_not Judge.enabled?
    with_env("STACK_JUDGE_URL" => "http://127.0.0.1:9300/v1/") do
      assert Judge.enabled?
      assert_equal "http://127.0.0.1:9300", Judge.url
    end
  end

  test "a reading keeps the clear answers and drops the unclear ones" do
    sent = nil
    reading = judging(ask: [ "decision", 0.93 ], front: 0.05, stamps: { "Approve" => 0.97, "Done" => 0.85, "Weekly" => 0.1 },
                      directives: { @receipts.id => 0.03, @outages.id => 0.5 }, sent: ->(body) { sent = body }) do
      Judge.front(@card, stamps: Stamp.for_card(@card).by_use.pluck(:label), directives: [ @receipts, @outages ])
    end

    assert_equal "jev-latest", sent[:model]
    assert_match "Printer is out of toner", sent[:state]
    assert_equal "choice", sent[:questions]["ask"][:type]
    assert_equal "decision", reading["ask"]
    assert_equal false, reading["front"]
    assert_equal %w[Approve Done], reading["likely_stamps"]
    assert_equal [ @outages ], reading["directives"], "a clearly irrelevant instruction is left out, an unclear one kept"
    assert_equal [ "decision", 0.93 ], reading["answers"]["ask"]

    unclear = judging(ask: [ "reply", 0.6 ], front: 0.5, stamps: { "Approve" => 0.5, "Done" => 0.1, "Weekly" => 0.1 }) do
      Judge.front(@card, stamps: %w[Approve Done Weekly], directives: [])
    end
    assert_equal [ nil, nil, nil ], unclear.values_at("ask", "front", "likely_stamps")

    none = judging(ask: [ "reply", 0.9 ], front: 0.1, stamps: { "Approve" => 0.1 }) { Judge.front(@card, stamps: %w[Approve], directives: []) }
    assert_equal [], none["likely_stamps"], "every stamp clearly wrong is a clear answer too"
  end

  test "digest with only the Judge answers the typed parts and records its reading" do
    judging(ask: [ "reply", 0.9 ], front: 0.95, stamps: { "Approve" => 0.1, "Done" => 0.92, "Weekly" => 0.1 }) do
      with_env(JUDGE) { Secretary.digest(@card) }
    end

    @card.reload
    assert_equal "reply", @card.ask
    assert_equal "Printer is out of toner", @card.summary
    assert_equal %w[Done], @card.payload["likely_stamps"]
    assert_equal 0.95, @card.payload["judge"]["front"]
    assert_equal @card, Card.current, "a clear yes on urgency puts it in front"
    assert @card.digested_at
  end

  test "the secretary writes the words with only the instructions that apply, and the Judge's clear answers stand" do
    prompt = nil
    llm = { "project" => "office", "summary" => "Toner's out", "ask" => "reply", "proposed_action" => "Order toner.",
            "likely_stamps" => [ "Approve" ], "placement" => "hold", "hold_until" => 2.hours.from_now.iso8601 }
    stub(Secretary::Backends::Local, :call, ->(user:, **) { prompt = user; llm }) do
      judging(ask: [ "decision", 0.9 ], front: 0.02, stamps: { "Approve" => 0.5, "Done" => 0.1, "Weekly" => 0.1 },
              directives: { @receipts.id => 0.9, @outages.id => 0.05 }) do
        with_env(JUDGE.merge("STACK_SECRETARY" => "local")) { Secretary.digest(@card) }
      end
    end

    assert_match "Hold receipts until evening", prompt
    assert_no_match "Outages go to the front", prompt
    @card.reload
    assert_equal [ "Toner's out", "decision", "Order toner." ], @card.values_at(:summary, :ask, :proposed_action)
    assert_equal %w[Approve], @card.payload["likely_stamps"], "unclear stamps leave the secretary's"
    assert @card.held?, "a hold needs the secretary's time, so the Judge doesn't overrule it"
  end

  test "an unreachable Judge leaves the card as it was, and the status says why" do
    stub(Judge, :request, ->(*) { raise Judge::Error, "couldn't reach http://127.0.0.1:9300: Connection refused" }) do
      with_env(JUDGE) do
        Secretary.digest(@card)
        assert_equal [ false, "couldn't reach http://127.0.0.1:9300: Connection refused" ], Judge.status.values_at("reachable", "error")
      end
    end
    assert_equal "acknowledge", @card.reload.ask
    assert_nil @card.payload["judge"]
    assert @card.digested_at
  end

  test "status lists the models and whether ours is among them" do
    stub(Judge, :request, ->(*) { { "data" => [ { "id" => "jev-latest" } ] } }) do
      with_env(JUDGE) { assert_equal [ true, true ], Judge.status.values_at("reachable", "model_ready") }
    end
  end

  private
    # Answers each question the way OpenJev would, from the probabilities given.
    def judging(ask:, front:, stamps: {}, directives: {}, sent: nil, &block)
      reply = ->(_verb, _path, body) do
        sent&.call(body)
        stamp_labels = body[:questions].filter_map { |key, q| [ key, q[:instructions][/"(.+)"/, 1] ] if key.start_with?("stamp_") }.to_h
        answers = body[:questions].to_h do |key, _|
          answer = case key
          when "ask" then { "choice" => ask[0], "probabilities" => { ask[0] => ask[1] }, "confidence" => 0.5 }
          when "front" then { "noul" => front }
          when /\Astamp_/ then { "noul" => stamps.fetch(stamp_labels[key]) }
          when /\Adirective_(\d+)\z/ then { "noul" => directives.fetch($1.to_i, 0.5) }
          end
          [ key, answer ]
        end
        { "model" => "jev-latest", "answers" => answers }
      end
      stub(Judge, :request, reply, &block)
    end

    def stub(object, name, callable)
      original = object.method(name)
      object.define_singleton_method(name) { |*args, **kwargs| callable.call(*args, **kwargs) }
      yield
    ensure
      object.singleton_class.remove_method(name)
      object.define_singleton_method(name, original) unless object.respond_to?(name)
    end
end
