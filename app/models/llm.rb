require "net/http"

# Structured generation against the OpenAI-compatible endpoint in
# config.x.llm: the reply is constrained to a JSON schema, so it always parses
# into the shape asked for. Every caller is expected to treat a raised Error
# as "no answer" rather than as a failure -- the Secretary degrades to the
# intake's own front when this is unavailable.
class Llm
  class Error < StandardError; end
  class Refused < Error; end # the server answered, with an error

  READ_TIMEOUT = 600 # the first request after idle waits for the model to load

  def self.extract(instructions:, input:, schema:)
    new.extract(instructions:, input:, schema:)
  end

  def initialize(config = Rails.configuration.x.llm)
    @base_url = config.base_url
    @model = config.model
  end

  def extract(instructions:, input:, schema:)
    raise Error, "STACK_SECRETARY_MODEL is not set" if @model.blank?

    reply = post("chat/completions", {
      model: @model,
      temperature: 0,
      messages: [
        { role: "system", content: instructions },
        { role: "user", content: input }
      ],
      response_format: { type: "json_schema", json_schema: { name: "front", strict: true, schema: schema } },
      # Qwen3 opens with a <think> block otherwise, and the schema does not
      # allow for one -- the grammar rejects the response mid-generation.
      chat_template_kwargs: { enable_thinking: false }
    })

    choice = reply.dig("choices", 0) or raise Error, "The model returned no choices"
    raise Error, "The model ran out of tokens before finishing" if choice["finish_reason"] == "length"

    JSON.parse(choice.dig("message", "content").to_s)
  rescue JSON::ParserError => e
    raise Error, "The model returned invalid JSON: #{e.message}"
  end

  private
    def post(path, body)
      uri = URI.join(@base_url.chomp("/") + "/", path)
      request = Net::HTTP::Post.new(uri, "Content-Type" => "application/json")
      request.body = body.to_json

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 10, read_timeout: READ_TIMEOUT) do |http|
        http.request(request)
      end
      raise Refused, "#{uri} answered #{response.code}: #{response.body.to_s.truncate(300)}" unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    rescue SocketError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError => e
      raise Error, "Could not reach #{@base_url}: #{e.message}"
    end
end
