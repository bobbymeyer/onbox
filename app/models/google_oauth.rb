require "signet/oauth_2/client"

# Sign-in to Google for the email and calendar sources, each with its own
# scope and refresh token. Uses the loopback redirect of a Desktop OAuth
# client, so it needs no public URL: after approving, the browser lands on a
# localhost address that fails to load, and Bobby pastes that address (or
# just its code) back into onbox.
module GoogleOauth
  SCOPES = {
    "email" => "https://www.googleapis.com/auth/gmail.modify",
    "calendar" => "https://www.googleapis.com/auth/calendar.events"
  }.freeze
  REDIRECT_URI = "http://localhost:8765".freeze

  module_function

  CLIENT_ID = "google_client_id".freeze
  CLIENT_SECRET = "google_client_secret".freeze

  # Entered on /sources (stored encrypted), or from the environment.
  def client_id
    Credential.find_by(name: CLIENT_ID)&.secret.presence || ENV["GOOGLE_CLIENT_ID"].presence || ENV["GMAIL_CLIENT_ID"].presence
  end

  def client_secret
    Credential.find_by(name: CLIENT_SECRET)&.secret.presence || ENV["GOOGLE_CLIENT_SECRET"].presence || ENV["GMAIL_CLIENT_SECRET"].presence
  end

  def configured?
    client_id.present? && client_secret.present?
  end

  def configure!(id, secret)
    raise ArgumentError, "both the client ID and secret are needed" if id.blank? || secret.blank?
    { CLIENT_ID => id, CLIENT_SECRET => secret }.each do |name, value|
      Credential.find_or_initialize_by(name: name).update!(secret: value.strip)
    end
  end

  def url(kind, state: nil)
    client(kind).authorization_uri(access_type: "offline", prompt: "consent", state: state).to_s
  end

  # Accepts the pasted redirect URL or the bare code; returns the refresh token.
  # With a state, the pasted URL must carry the same one.
  def exchange(kind, pasted, state: nil)
    pasted = pasted.to_s.strip
    address = pasted.match?(%r{\Ahttps?://|[?&]code=})
    query = address ? Rack::Utils.parse_query(URI(pasted).query.to_s) : { "code" => pasted }
    raise ArgumentError, "that link is from a different sign-in; start again" if state && query["state"] && query["state"] != state
    raise ArgumentError, "no code in what was pasted" if query["code"].blank?

    oauth = client(kind)
    oauth.code = query["code"]
    oauth.fetch_access_token!
    oauth.refresh_token or raise ArgumentError, "Google returned no refresh token; remove onbox's access in your Google account and connect again"
  rescue URI::InvalidURIError
    raise ArgumentError, "that doesn't look like the address the browser landed on"
  end

  def credentials(kind, refresh_token)
    Google::Auth::UserRefreshCredentials.new(
      client_id: client_id, client_secret: client_secret, refresh_token: refresh_token, scope: SCOPES.fetch(kind)
    )
  end

  def client(kind)
    Signet::OAuth2::Client.new(
      authorization_uri: "https://accounts.google.com/o/oauth2/v2/auth",
      token_credential_uri: "https://oauth2.googleapis.com/token",
      client_id: client_id,
      client_secret: client_secret,
      scope: SCOPES.fetch(kind),
      redirect_uri: REDIRECT_URI
    )
  end
end
