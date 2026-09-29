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
  rescue ArgumentError, Google::Apis::Error, Signet::AuthorizationError, MacEventKit::Error => e
    redirect_to sources_path, alert: "#{source.name}: #{e.message}"
  end

  # Calendar and Reminders: asks macOS for access (the prompt appears on the
  # Mac's screen), then reads them once.
  def allow
    source = Source.find(params[:id])
    access = MacEventKit.request_access[source.calendar? ? "calendar" : "reminders"]
    if access == "granted"
      cards = source.poll!
      redirect_to sources_path, notice: "#{source.name} connected: #{helpers.pluralize(cards.size, "new card")}"
    else
      redirect_to sources_path, alert: "macOS says #{access.to_s.humanize(capitalize: false)} for #{source.name}. Allow it in System Settings → Privacy & Security → #{source.calendar? ? "Calendars" : "Reminders"}."
    end
  rescue MacEventKit::Error => e
    redirect_to sources_path, alert: "#{source.name}: #{e.message}"
  end

  # Reminders: which list lands in the stack whole.
  def update
    source = Source.find(params[:id])
    if source.email?
      query = params.expect(source: [ :email_query ])[:email_query].to_s.strip
      source.update!(settings: source.settings.merge("query" => query.presence))
      redirect_to sources_path, notice: "#{source.name} will use: #{source.email_query}"
    else
      list = params.expect(source: [ :reminders_list ])[:reminders_list].to_s.strip
      source.update!(settings: source.settings.merge("list" => list.presence))
      redirect_to sources_path, notice: "Everything in \"#{MacReminders::Sync.list_name(source)}\" now lands in the stack"
    end
  end

  # Google sign-in for the email source, from the web: a link to
  # approve, then paste back the address the browser landed on.
  def connect
    @source = Source.find(params[:id])
    return redirect_to(sources_path, alert: "#{@source.name} doesn't sign in to Google") unless @source.google?
    return unless GoogleOauth.configured?

    session[:google_state] = SecureRandom.hex(16)
    @url = GoogleOauth.url(@source.kind, state: session[:google_state])
  end

  def authorize
    source = Source.find(params[:id])
    begin
      source.update!(secret: GoogleOauth.exchange(source.kind, params[:pasted], state: session.delete(:google_state)))
    rescue ArgumentError, Signet::AuthorizationError => e
      return redirect_to(connect_source_path(source), alert: "Couldn't connect #{source.name}: #{e.message}")
    end

    cards = source.poll!
    redirect_to sources_path, notice: "#{source.name} connected: #{helpers.pluralize(cards.size, "new card")}"
  rescue Google::Apis::Error, Signet::AuthorizationError => e
    redirect_to sources_path, alert: "#{source.name} connected, but the first check failed: #{e.message}"
  end

  # The Google Cloud OAuth client (Desktop app) both sources sign in through.
  def google_client
    GoogleOauth.configure!(params[:client_id].to_s, params[:client_secret].to_s)
    redirect_back_or_to sources_path, notice: "Google client saved"
  rescue ArgumentError => e
    redirect_back_or_to sources_path, alert: e.message
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
