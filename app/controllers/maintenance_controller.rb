# Maintenance mode: the full stack, all of it visible.
class MaintenanceController < ApplicationController
  def show
    Trigger.fire_due!
    @live = Card.live.in_stack_order.includes(:source, :blocked_by)
    @held = Card.held.includes(:source, :triggers).order(:hold_until)
    @recent = Card.handled.order(handled_at: :desc).limit(20)
    @flip_rate = FlipRate.recent
  end
end
