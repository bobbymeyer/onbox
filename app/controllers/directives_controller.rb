# Standing instructions the secretary follows for every new card.
class DirectivesController < ApplicationController
  def create
    directive = Directive.new(text: params.expect(directive: [ :text ])[:text].to_s.strip)
    if directive.save
      redirect_to maintenance_path(anchor: "secretary"), notice: "The secretary will follow that"
    else
      redirect_to maintenance_path(anchor: "secretary"), alert: "Write the instruction first"
    end
  end

  def destroy
    Directive.find(params[:id]).destroy!
    redirect_to maintenance_path(anchor: "secretary"), notice: "Instruction dropped", status: :see_other
  end
end
