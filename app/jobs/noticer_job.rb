class NoticerJob < ApplicationJob
  queue_as :default

  def perform(card_type)
    Noticer.call(card_type)
  end
end
