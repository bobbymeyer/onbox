class AccountingJob < ApplicationJob
  queue_as :default

  def perform
    Accountant.run
  end
end
