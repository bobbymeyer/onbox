# Maintenance mode: the full stack, all of it visible, and the secretary to
# talk to about it.
class MaintenanceController < ApplicationController
  BULK_OPS = %w[later front top project release done delete].freeze

  def show
    Trigger.fire_due!
    @live = Card.live.in_stack_order.includes(:source, :blocked_by)
    @held = Card.held.includes(:source, :triggers).order(:hold_until)
    @recent = Card.handled.order(handled_at: :desc).limit(20)
    @flip_rate = FlipRate.recent
    @messages = SecretaryMessage.recent(6)
    @directives = Directive.in_order
  end

  def converse
    text = params[:text].to_s.strip
    Secretary::Conversation.say(text) if text.present?
    redirect_to maintenance_path(anchor: "secretary"), status: :see_other
  end

  def bulk
    cards = Card.open.where(id: params[:card_ids]).in_stack_order.to_a
    op = params[:bulk_op].presence_in(BULK_OPS)
    return redirect_to(maintenance_path, alert: "Pick some cards and an action") if cards.empty? || op.nil?

    notice = apply(op, cards, params[:value].to_s.strip)
    redirect_to maintenance_path, notice: notice, status: :see_other
  rescue ArgumentError => e
    redirect_to maintenance_path, alert: e.message, status: :see_other
  end

  private
    def apply(op, cards, value)
      count = helpers.pluralize(cards.size, "card")
      case op
      when "later"
        resolved = Secretary.resolve_later(value) or raise ArgumentError, "Couldn't read \"#{value}\" as a time"
        cards.each do |card|
          card.handlings.create!(verb: "later", text: value)
          card.hold!(**resolved)
        end
        "Held #{count}"
      when "front"
        # Last first, so the selection keeps its order at the front.
        cards.reverse_each { |card| card.update!(position: Card.bottom_position) }
        "Moved #{count} to the front"
      when "top"
        cards.each(&:to_top_of_stack!)
        "Moved #{count} to the top"
      when "project"
        cards.each { |card| card.update!(project: value.presence) }
        "Re-tagged #{count} as #{value.presence || "no project"}"
      when "release"
        cards.select(&:held?).each(&:release!)
        "Released #{count}"
      when "done"
        cards.each do |card|
          card.handlings.create!(verb: "done")
          card.handle!(with: "done")
        end
        "Handled #{count}"
      when "delete"
        cards.each(&:destroy!)
        "Deleted #{count}"
      end
    end
end
