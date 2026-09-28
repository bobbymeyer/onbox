class FireTriggersJob < ApplicationJob
  queue_as :default

  def perform
    Trigger.fire_due!
  end
end
