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
