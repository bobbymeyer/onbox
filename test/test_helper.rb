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
      "message_id" => "m1@mail.example", "thread_id" => "t1@mail.example",
      "from" => "Ada Lovelace <ada@example.com>", "to" => "bobby@bobbymeyer.com",
      "subject" => "Dinner Thursday?", "account" => "iCloud", "mailbox" => "INBOX", "bulk" => false,
      "body" => "Are you free Thursday at 7?"
    }.merge(overrides.stringify_keys)
  end

  def email_card(**overrides)
    Intake.receive(sources(:mail), email_payload(**overrides)).reload
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
    attr_accessor :events_list, :reminders_list, :mail_list
    attr_reader :calls

    def initialize(events: [], reminders: [], mail: [])
      @events_list, @reminders_list, @mail_list, @calls = events, reminders, mail, []
    end

    # mail: full messages as the helper gives them, plus "read" and "junk".
    def mail_unread = @mail_list.reject { |m| m["read"] }.map { |m| m.slice("message_id", "received").merge("junk" => m["junk"] || false) }
    def mail_messages(ids) = (@calls << [ :mail_messages, ids ]) && @mail_list.select { |m| ids.include?(m["message_id"]) }

    def events(from:, to:) = @events_list
    def reminders = @reminders_list
    def complete(id) = @calls << [ :complete, id ]
    def reschedule(id, time) = @calls << [ :reschedule, id, time ]
  end

  # A message as the Mac helper reports it.
  def mail_message(**overrides)
    { "message_id" => "m1@mail.example", "subject" => "Dinner Thursday?", "from" => "Ada Lovelace <ada@example.com>",
      "reply_to" => "", "to" => "bobby@bobbymeyer.com", "cc" => "", "received" => "2026-09-30T09:00:00.000Z",
      "account" => "iCloud", "mailbox" => "INBOX", "read" => false,
      "headers" => "Message-ID: <m1@mail.example>\nFrom: Ada Lovelace <ada@example.com>\nSubject: Dinner Thursday?\n",
      "body" => "Are you free Thursday at 7?" }.merge(overrides.stringify_keys)
  end

  def reminder(**overrides)
    { "reminder_id" => "r1", "title" => "Renew passport", "notes" => nil, "list" => "Personal",
      "due" => nil, "all_day_due" => false, "priority" => 0, "url" => nil }.merge(overrides.stringify_keys)
  end
end
