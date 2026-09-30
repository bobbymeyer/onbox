# The stack MCP bridge's way in (see StackMcp): post a card, and read what
# Bobby did with it. Authenticated like the intake, with a source's token;
# a source only sees its own cards.
class Api::CardsController < IntakeController
  def create
    params = request.request_parameters.presence || JSON.parse(request.raw_post.presence || "{}")
    params = params.to_h.deep_stringify_keys
    card = params["kind"] == "permission" ? StackMcp.permission_card(@source, params) : note(params)
    render json: StackMcp.status(card), status: :created
  rescue JSON::ParserError
    render json: { error: "body must be JSON" }, status: :bad_request
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def show
    card = @source.cards.find_by(id: params[:id])
    return render(json: { error: "no such card" }, status: :not_found) unless card
    render json: StackMcp.status(card)
  end

  private
    # A card Claude posts: what it needs from Bobby, or news. It goes through
    # the intake like any other, so the secretary fronts and places it.
    def note(params)
      Intake.receive(@source, {
        "hook_event_name" => "Post", "session_id" => params["session_id"].presence,
        "cwd" => params["cwd"].presence, "project" => params["project"].presence,
        "summary" => params["summary"], "ask" => params["ask"], "proposed_action" => params["proposed_action"],
        "last_assistant_message" => params["body"].presence || params["summary"]
      }.compact)
    end
end
