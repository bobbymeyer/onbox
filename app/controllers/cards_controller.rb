class CardsController < ApplicationController
  before_action :set_card

  def stamp
    Gestures.stamp(@card, Stamp.find(params[:stamp_id]), text: params[:text])
    advance "Stamped: #{@card.handled_with}"
  end

  def reply
    text = params[:text].to_s.strip
    return advance("Nothing to send", alert: true) if text.empty? && @card.type.requires_text?

    Gestures.reply(@card, text)
    advance "Handled"
  end

  def top
    Gestures.top_of_stack(@card)
    advance "Back on top"
  end

  def later
    if Gestures.later(@card, params[:when])
      advance "Held until #{helpers.hold_description(@card.reload)}"
    else
      advance "Couldn't read \"#{params[:when]}\" as a time", alert: true
    end
  end

  def flip
    Gestures.flip(@card)
    head :no_content
  end

  # Maintenance gestures

  def release
    @card.handlings.create!(verb: "release")
    @card.release!
    redirect_back_or_to maintenance_path
  end

  def bottom
    @card.update!(position: Card.bottom_position)
    redirect_back_or_to maintenance_path
  end

  def edit
  end

  def update
    if @card.update(card_params)
      redirect_to maintenance_path, notice: "Card updated"
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @card.destroy!
    redirect_back_or_to maintenance_path, notice: "Card deleted"
  end

  private
    def set_card
      @card = Card.find(params[:id])
    end

    def card_params
      params.expect(card: [ :project, :summary, :ask, :proposed_action, :card_type ])
    end

    def advance(message, alert: false)
      flash[alert ? :alert : :notice] = message
      redirect_to params[:return_to] == "stack" ? maintenance_path : root_path, status: :see_other
    end
end
