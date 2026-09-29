# The secretary's accounting, newest first, filterable by period.
class DigestsController < ApplicationController
  def index
    @period = params[:period].presence_in(Accounting::PERIODS.keys)
    scope = Accounting.newest_first
    @accountings = (@period ? scope.where(period: @period) : scope).limit(50)
  end

  # Write any digest whose window has closed but hasn't been written yet.
  def catch_up
    written = Accountant.run
    redirect_to digests_path, notice: written.any? ? "Wrote #{written.map(&:title).to_sentence}" : "Nothing new to account for"
  end
end
