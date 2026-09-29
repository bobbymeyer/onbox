module Intake
  module Normalizer
    def self.for(source)
      case source.kind
      when "claude_code" then ClaudeCode
      when "email" then Email
      when "calendar" then Calendar
      else Generic
      end
    end
  end
end
