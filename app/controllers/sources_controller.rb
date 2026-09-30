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

  def poll
    source = Source.find(params[:id])
    cards = source.poll!
    redirect_to sources_path, notice: "#{source.name}: #{cards.size} new card(s)"
  rescue ArgumentError, MacEventKit::Error => e
    redirect_to sources_path, alert: "#{source.name}: #{e.message}"
  end

  # Mail, Calendar and Reminders: asks macOS for access (the prompt appears
  # on the Mac's screen), then reads the app once.
  def allow
    source = Source.find(params[:id])
    access = MacEventKit.request_access(source.mac_access)[source.mac_access]
    if access == "granted"
      cards = source.poll!
      redirect_to sources_path, notice: "#{source.name} connected: #{helpers.pluralize(cards.size, "new card")}"
    else
      redirect_to sources_path, alert: "macOS says #{access.to_s.humanize(capitalize: false)} for #{source.name}. Allow it in System Settings → Privacy & Security → #{source.email? ? "Automation" : source.mac_app.pluralize}."
    end
  rescue MacEventKit::Error => e
    redirect_to sources_path, alert: "#{source.name}: #{e.message}"
  end

  # Reminders: which list lands in the stack whole. Mail: whether mailing
  # lists and newsletters become cards.
  def update
    source = Source.find(params[:id])
    if source.email?
      include_bulk = params.expect(source: [ :include_bulk ])[:include_bulk] == "1"
      source.update!(settings: source.settings.merge("include_bulk" => include_bulk))
      redirect_to sources_path, notice: include_bulk ? "Newsletters and mailing lists now become cards too" : "Newsletters and mailing lists stay in Mail"
    else
      list = params.expect(source: [ :reminders_list ])[:reminders_list].to_s.strip
      source.update!(settings: source.settings.merge("list" => list.presence))
      redirect_to sources_path, notice: "Everything in \"#{MacReminders::Sync.list_name(source)}\" now lands in the stack"
    end
  end

  # A new token; the old one stops working at once.
  def rotate
    source = Source.find(params[:id])
    source.regenerate_token
    redirect_to sources_path, notice: "New token for #{source.name}. Update whatever sends to it."
  end

  def destroy
    Source.find(params[:id]).destroy!
    redirect_to sources_path, notice: "Source deleted"
  end
end
