# Dispenser mode: one full-screen card. No count, no peek at what is behind it.
class DispenserController < ApplicationController
  def show
    Trigger.fire_due!
    @card = Card.current
    @stamps = StampTray.for(@card) if @card
  end
end
