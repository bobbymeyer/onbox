class SourcesController < ApplicationController
  def index
    @sources = Source.order(:name)
    @source = Source.new(kind: "claude_code")
  end

  def create
    @source = Source.new(params.expect(source: [ :name, :kind ]))
    if @source.save
      redirect_to sources_path, notice: "Source created"
    else
      @sources = Source.order(:name)
      render :index, status: :unprocessable_entity
    end
  end

  def destroy
    Source.find(params[:id]).destroy!
    redirect_to sources_path, notice: "Source deleted"
  end
end
