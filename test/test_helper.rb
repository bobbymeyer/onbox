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
