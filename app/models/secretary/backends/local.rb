require "net/http"

class Secretary
  module Backends
    # A local model through Ollama on the same machine. The JSON schema goes
    # in `format`, so the reply is constrained to it.
    module Local
      module_function

      def url = ENV.fetch("STACK_OLLAMA_URL", "http://localhost:11434")
      def model = ENV.fetch("STACK_LOCAL_MODEL", "qwen3:30b")

      def call(system:, user:, schema:, effort: nil)
        reply = post("/api/chat", {
          model: model, stream: false, think: false, format: schema, options: { temperature: 0.2 },
          messages: [ { role: "system", content: system }, { role: "user", content: user } ]
        })
        JSON.parse(reply.dig("message", "content").to_s)
      rescue JSON::ParserError => e
        raise Error, "unreadable reply from #{model}: #{e.message}"
      end

      # { "reachable" => bool, "models" => [...], "model_ready" => bool }
      def status
        models = Array(get("/api/tags")["models"]).map { |m| m["name"] }
        { "reachable" => true, "models" => models, "model_ready" => models.any? { |m| m == model || m == "#{model}:latest" } }
      rescue Error => e
        { "reachable" => false, "error" => e.message }
      end

      def post(path, body)
        request(Net::HTTP::Post.new(URI.join(url, path), "Content-Type" => "application/json").tap { |r| r.body = body.to_json })
      end

      def get(path)
        request(Net::HTTP::Get.new(URI.join(url, path)))
      end

      def request(req)
        uri = req.uri
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 5, read_timeout: 300) { |http| http.request(req) }
        raise Error, "Ollama #{response.code}: #{response.body.to_s.truncate(300)}" unless response.is_a?(Net::HTTPSuccess)
        JSON.parse(response.body)
      rescue SystemCallError, Net::OpenTimeout, Net::ReadTimeout, SocketError, JSON::ParserError => e
        raise Error, "Ollama at #{url}: #{e.message}"
      end
    end
  end
end
