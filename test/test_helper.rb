ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
  end
end

class ActiveSupport::TestCase
  def claude_event(session_id: "sess-1", hook: "Stop", cwd: "/Users/bobby/code/onbox", **extra)
    { "session_id" => session_id, "hook_event_name" => hook, "cwd" => cwd, "transcript_path" => "/nonexistent" }.merge(extra.stringify_keys)
  end

  def agent_card(**attrs)
    Intake.receive(sources(:claude_code), claude_event(**attrs)).reload
  end
end

class ActiveSupport::TestCase
  def email_payload(**overrides)
    {
      "message_id" => "m1", "thread_id" => "t1", "rfc822_message_id" => "<abc@mail.example>",
      "from" => "Ada Lovelace <ada@example.com>", "to" => "bobby@bobbymeyer.com",
      "subject" => "Dinner Thursday?", "snippet" => "Are you free", "labels" => [ "INBOX", "UNREAD" ],
      "body" => "Are you free Thursday at 7?"
    }.merge(overrides.stringify_keys)
  end

  def email_card(**overrides)
    Intake.receive(sources(:gmail), email_payload(**overrides)).reload
  end

  def connect(source)
    source.update!(secret: "refresh-token")
    source
  end

  # Stands in for Gmail::Mailbox.
  class FakeMailbox
    attr_reader :calls

    def initialize(messages = [])
      @messages = messages
      @calls = []
    end

    def messages(query:, after:)
      @calls << [ :messages, query, after ]
      @messages
    end

    def reply(payload, text) = @calls << [ :reply, payload["thread_id"], text ]
    def archive(thread_id) = @calls << [ :archive, thread_id ]
  end
end

class ActiveSupport::TestCase
  def with_stub(object, name, value)
    original = object.method(name)
    object.define_singleton_method(name) { |*, **| value }
    yield
  ensure
    object.singleton_class.remove_method(name)
    object.define_singleton_method(name, original) unless object.respond_to?(name)
  end
end

class ActiveSupport::TestCase
  FAKE_CLAUDE = Rails.root.join("test/support/fake_claude").to_s

  def with_env(vars)
    old = vars.keys.to_h { |k| [ k, ENV[k] ] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    old.each { |k, v| ENV[k] = v }
  end
end

class ActiveSupport::TestCase
  # A normalized calendar event, Thursday 1 Oct 2026 15:00–16:00 by default.
  def calendar_event(**overrides)
    {
      "event_id" => "ev1", "series_id" => "ev1", "recurring" => false, "status" => "confirmed",
      "updated" => "2026-09-29T10:00:00Z", "summary" => "Design review",
      "start" => Time.zone.local(2026, 10, 1, 15).iso8601, "end" => Time.zone.local(2026, 10, 1, 16).iso8601,
      "all_day" => false, "location" => "Room 4", "organizer" => "Ada Lovelace", "organizer_self" => false,
      "attendees" => [ { "name" => "Ada Lovelace", "response" => "accepted" } ], "self_response" => "pending"
    }.merge(overrides.stringify_keys)
  end

  # Stands in for MacEventKit: canned events and reminders, and a log of calls.
  class FakeKit
    attr_accessor :events_list, :reminders_list
    attr_reader :calls

    def initialize(events: [], reminders: [])
      @events_list, @reminders_list, @calls = events, reminders, []
    end

    def events(from:, to:) = @events_list
    def reminders = @reminders_list
    def complete(id) = @calls << [ :complete, id ]
    def reschedule(id, time) = @calls << [ :reschedule, id, time ]
  end

  def reminder(**overrides)
    { "reminder_id" => "r1", "title" => "Renew passport", "notes" => nil, "list" => "Personal",
      "due" => nil, "all_day_due" => false, "priority" => 0, "url" => nil }.merge(overrides.stringify_keys)
  end
end
