class Secretary
  module Backends
    # The Claude API with an API key (or an `ant auth login` Console profile).
    # Billed to the API, not the Max plan; here for completeness.
    module Api
      BETAS = [ "server-side-fallback-2026-07-01" ].freeze

      module_function

      def model = ENV.fetch("STACK_SECRETARY_MODEL", "claude-opus-5-5")

      def call(system:, user:, schema:, effort: :low)
        message = Anthropic::Client.new.beta.messages.create(
          model: model,
          max_tokens: 16_000,
          system_: system,
          messages: [ { role: "user", content: user } ],
          output_config: { effort: effort, format: { type: :json_schema, schema: schema } },
          fallbacks: :default,
          betas: BETAS
        )
        raise Error, "declined (#{message.stop_details&.category})" if message.stop_reason == :refusal

        JSON.parse(message.content.select { |b| b.type == :text }.map(&:text).join)
      rescue Anthropic::Errors::Error, JSON::ParserError => e
        raise Error, "#{e.class}: #{e.message}"
      end
    end
  end
end
