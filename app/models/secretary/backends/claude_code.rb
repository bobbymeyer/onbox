class Secretary
  module Backends
    # Structured calls through `claude -p` on Bobby's Max plan: no tools, no
    # saved session, output validated against the JSON schema by the CLI.
    module ClaudeCode
      module_function

      def call(system:, user:, schema:, effort: nil)
        argv = [ ClaudeCli.bin, "-p", "--output-format", "json", "--json-schema", schema.to_json,
                 "--system-prompt", system, "--tools", "", "--no-session-persistence" ]
        argv += [ "--model", ENV["STACK_CLAUDE_MODEL"] ] if ENV["STACK_CLAUDE_MODEL"].present?

        output, error, status = Open3.capture3(ClaudeCli.env(internal: true), *argv, stdin_data: user, chdir: ClaudeCli.workdir)
        raise Error, (error.presence || output).to_s.strip.truncate(500) unless status.success?
        parse(output)
      rescue SystemCallError => e
        raise Error, ClaudeCli.explain(e)
      end

      # The JSON envelope carries the validated object in structured_output;
      # older CLIs put it in result as text.
      def parse(output)
        envelope = JSON.parse(output)
        raise Error, envelope["result"].to_s.truncate(500) if envelope["is_error"]
        envelope["structured_output"].presence || JSON.parse(envelope["result"].to_s[/\{.*\}/m].to_s)
      rescue JSON::ParserError => e
        raise Error, "unreadable reply from claude: #{e.message}"
      end
    end
  end
end
