require "net/http"

class Secretary
  module Backends
    # A local model behind an OpenAI-compatible endpoint (llama-swap on the
    # Mac Studio): /v1/chat/completions with a strict json_schema response
    # format, so the reply always parses into the shape asked for.
    module Local
      READ_TIMEOUT = 600 # the first request after idle waits for the model to load

      module_function

      def url = ENV.fetch("STACK_SECRETARY_URL", "https://chat.bobbymeyer.com/v1")
      def model = ENV["STACK_SECRETARY_MODEL"].presence

      def call(system:, user:, schema:, effort: nil)
        raise Error, "STACK_SECRETARY_MODEL is not set" unless model

        reply = request(:post, "chat/completions", {
          model: model,
          temperature: 0,
          messages: [ { role: "system", content: system }, { role: "user", content: user } ],
          response_format: { type: "json_schema", json_schema: { name: "reply", strict: true, schema: schema } },
          # Qwen3 opens with a <think> block otherwise, which the schema's
          # grammar rejects mid-generation.
          chat_template_kwargs: { enable_thinking: false }
        })

        choice = reply.dig("choices", 0) or raise Error, "the model returned no choices"
        raise Error, "the model ran out of tokens before finishing" if choice["finish_reason"] == "length"
        JSON.parse(choice.dig("message", "content").to_s)
      rescue JSON::ParserError => e
        raise Error, "the model returned invalid JSON: #{e.message}"
      end

      # { "reachable" => bool, "models" => [...], "model_ready" => bool }
      def status
        models = Array(request(:get, "models")["data"]).map { |m| m["id"] }
        { "reachable" => true, "models" => models, "model_ready" => models.include?(model) }
      rescue Error => e
        { "reachable" => false, "error" => e.message }
      end

      def request(verb, path, body = nil)
        uri = URI.join(url.chomp("/") + "/", path)
        req = verb == :post ? Net::HTTP::Post.new(uri, "Content-Type" => "application/json") : Net::HTTP::Get.new(uri)
        req.body = body.to_json if body

        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 10, read_timeout: READ_TIMEOUT) { |http| http.request(req) }
        raise Error, "#{uri} answered #{response.code}: #{response.body.to_s.truncate(300)}" unless response.is_a?(Net::HTTPSuccess)
        JSON.parse(response.body)
      rescue SocketError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError, JSON::ParserError => e
        raise Error, "couldn't reach #{url}: #{e.message}"
      end
    end
  end
end
