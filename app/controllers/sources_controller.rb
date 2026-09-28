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

  # Email sources: the Gmail search that decides which mail becomes cards.
  def update
    source = Source.find(params[:id])
    query = params.expect(source: [ :email_query ])[:email_query].to_s.strip
    source.update!(settings: source.settings.merge("query" => query.presence))
    redirect_to sources_path, notice: "#{source.name} will use: #{source.email_query}"
  end

  def poll
    source = Source.find(params[:id])
    cards = Gmail::Sync.call(source)
    redirect_to sources_path, notice: "#{source.name}: #{cards.size} new card(s)"
  rescue ArgumentError, Google::Apis::Error, Signet::AuthorizationError => e
    redirect_to sources_path, alert: "#{source.name}: #{e.message}"
  end

  def destroy
    Source.find(params[:id]).destroy!
    redirect_to sources_path, notice: "Source deleted"
  end
end
