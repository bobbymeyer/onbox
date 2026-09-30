require "net/http"

# OpenJev beside the secretary. It answers typed questions with probabilities
# (POST /v1/systemone) rather than writing text, so it takes the parts of a
# card's front that are a choice: the ask, whether the card jumps the queue,
# which stamps fit, and which standing instructions apply. The local model
# still writes the words.
#
# Off unless STACK_JUDGE_URL is set. Only a clear answer counts (at or past
# STACK_JUDGE_THRESHOLD either way); an unclear one, or a Judge that doesn't
# answer, leaves the secretary's own answer standing.
module Judge
  class Error < StandardError; end

  READ_TIMEOUT = 20 # a read after the model's pages were evicted takes ~6s
  STAMP_LIMIT = 12

  ASK_CRITERIA = {
    "decision" => "Bobby must choose between options or approve something before it goes ahead",
    "reply" => "someone is waiting for a written answer from Bobby",
    "review" => "Bobby must look over work, or the event is unclear and needs a human look",
    "acknowledge" => "nothing to do but note it: notifications, receipts, newsletters, finished work with no follow-up"
  }.freeze

  module_function

  def url = ENV["STACK_JUDGE_URL"].presence&.chomp("/")&.delete_suffix("/v1")
  def model = ENV.fetch("STACK_JUDGE_MODEL", "openjev-latest")
  def threshold = ENV.fetch("STACK_JUDGE_THRESHOLD", "0.8").to_f
  def enabled? = url.present?

  # The Judge's reading of a card, or nil when it doesn't answer (logged):
  #   "ask"           one of Card::ASKS, or nil when unclear
  #   "front"         true / false, or nil when unclear
  #   "likely_stamps" up to three labels clearly fitting, most likely first; [] when
  #                   none fits, nil when none clearly fits but some were unclear
  #   "directives"    the directives not clearly irrelevant
  #   "answers"       the raw probabilities, for the card's payload
  def front(card, stamps:, directives:)
    stamps = stamps.first(STAMP_LIMIT)
    questions = {
      "ask" => { type: "choice", instructions: "What does this card need from Bobby?", criteria: ASK_CRITERIA },
      "front" => { type: "noul", instructions: "Does this need Bobby now, ahead of everything else in his queue? " \
                                               "Only for something plainly urgent, or a standing instruction that says so." }
    }
    stamps.each_with_index do |label, i|
      questions["stamp_#{i}"] = { type: "noul", instructions: "Would Bobby answer this card by stamping it \"#{label}\"?" }
    end
    directives.each do |directive|
      questions["directive_#{directive.id}"] = { type: "noul", instructions: "Does this standing instruction from Bobby apply to this card: #{directive.text}" }
    end

    answers = read(state: state(card, directives), questions: questions)
    probabilities = answers.transform_values { |answer| answer["noul"] || answer.dig("probabilities", answer["choice"]) }

    ask = answers.dig("ask", "choice")
    stamp_ps = stamps.each_with_index.to_h { |label, i| [ label, probabilities["stamp_#{i}"] ] }
    likely = stamp_ps.select { |_, p| clear_yes?(p) }.sort_by { |_, p| -p }.first(3).map(&:first)
    reading = {
      "ask" => (ask if ask.in?(Card::ASKS) && clear_yes?(probabilities["ask"])),
      "front" => verdict(probabilities["front"]),
      "likely_stamps" => (likely if likely.any? || stamp_ps.values.all? { |p| verdict(p) == false }),
      "directives" => directives.reject { |d| verdict(probabilities["directive_#{d.id}"]) == false },
      "answers" => {
        "ask" => [ ask, probabilities["ask"]&.round(2) ],
        "front" => probabilities["front"]&.round(2),
        "stamps" => stamp_ps.transform_values { |p| p&.round(2) },
        "directives" => directives.to_h { |d| [ d.id.to_s, probabilities["directive_#{d.id}"]&.round(2) ] }
      }.compact_blank
    }
    unclear = reading.values_at("ask", "front", "likely_stamps").count(&:nil?)
    Rails.logger.info("[judge] card #{card.id}: #{reading["answers"].to_json}#{" (#{unclear} unclear)" if unclear.positive?}")
    reading
  rescue Error => e
    Rails.logger.warn("[judge] card #{card.id}: #{e.message}")
    nil
  end

  # The secretary's front with the Judge's clear answers in place of its own.
  # Works without a secretary front too, starting from the card's own.
  def overrule(front, reading, card)
    return front unless reading
    front ||= {
      "project" => card.project, "summary" => card.summary, "ask" => card.ask, "proposed_action" => card.proposed_action,
      "likely_stamps" => card.payload["likely_stamps"], "placement" => "normal", "hold_until" => ""
    }
    placement = front["placement"]
    unless placement == "hold" # a hold needs a time, which only the secretary gives
      placement = { true => "front", false => "normal" }.fetch(reading["front"], placement)
    end
    front.merge(
      "ask" => reading["ask"] || front["ask"],
      "likely_stamps" => reading["likely_stamps"] || front["likely_stamps"],
      "placement" => placement
    )
  end

  # One read. Returns the answers keyed by question.
  def read(state:, questions:)
    request(:post, "v1/systemone", { model: model, state: state, questions: questions }).fetch("answers") do
      raise Error, "no answers in the reply"
    end
  end

  # { "reachable" => bool, "models" => [...], "model_ready" => bool }
  # OpenJev lists {"models": [{"name": ...}]}; an OpenAI-style
  # {"data": [{"id": ...}]} is read too.
  def status
    listing = request(:get, "v1/models")
    models = Array(listing["models"]).map { |m| m["name"] } + Array(listing["data"]).map { |m| m["id"] }
    { "reachable" => true, "models" => models, "model_ready" => models.include?(model) }
  rescue Error => e
    { "reachable" => false, "error" => e.message }
  end

  def clear_yes?(p) = p.is_a?(Numeric) && p >= threshold

  # true or false when the answer is clear, nil when it isn't.
  def verdict(p)
    return unless p.is_a?(Numeric)
    if p >= threshold then true
    elsif p <= 1 - threshold then false
    end
  end

  def state(card, directives)
    <<~STATE
      Now: #{Time.current.iso8601} (#{Time.zone.name})
      Card type: #{card.card_type}
      Source: #{card.source&.name} (#{card.source&.kind})
      Project: #{card.project}
      Summary: #{card.summary}
      Bobby's standing instructions: #{directives.map(&:text).join("; ").presence || "none"}

      Event:
      #{JSON.pretty_generate(card.payload.except(*Card::SECRETARY_KEYS)).truncate(6000)}
    STATE
  end

  def request(verb, path, body = nil)
    raise Error, "STACK_JUDGE_URL is not set" unless url
    uri = URI.join(url + "/", path)
    req = verb == :post ? Net::HTTP::Post.new(uri, "Content-Type" => "application/json") : Net::HTTP::Get.new(uri)
    req.body = body.to_json if body

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 3, read_timeout: READ_TIMEOUT) { |http| http.request(req) }
    raise Error, "#{uri} answered #{response.code}: #{response.body.to_s.truncate(300)}" unless response.is_a?(Net::HTTPSuccess)
    JSON.parse(response.body)
  rescue SocketError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError, JSON::ParserError => e
    raise Error, "couldn't reach #{url}: #{e.message}"
  end
end
