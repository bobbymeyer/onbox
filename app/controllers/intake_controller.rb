# The one webhook endpoint. Sources authenticate with their token as a bearer
# token (or ?token= for senders that cannot set headers).
class IntakeController < ActionController::API
  include ActionController::HttpAuthentication::Token::ControllerMethods

  # The intake is the one path open to the internet (cloud sessions reach
  # it through the Studio's Tailscale Funnel), so it's rate limited too.
  rate_limit to: 120, within: 1.minute, with: -> { render json: { error: "slow down" }, status: :too_many_requests }
  before_action :authenticate_source

  def create
    payload = request.request_parameters.presence || JSON.parse(request.raw_post.presence || "{}")
    card = Intake.receive(@source, payload.to_h.deep_stringify_keys)
    render json: { card_id: card.id, state: card.state }, status: :accepted
  rescue JSON::ParserError
    render json: { error: "body must be JSON" }, status: :bad_request
  end

  private
    def authenticate_source
      @source = authenticate_with_http_token { |token, _| find_source(token) } || find_source(params[:token])
      render json: { error: "unknown source token" }, status: :unauthorized unless @source
    end

    def find_source(token)
      return if token.blank?
      Source.all.find { |source| ActiveSupport::SecurityUtils.secure_compare(source.token, token.to_s) }
    end
end
