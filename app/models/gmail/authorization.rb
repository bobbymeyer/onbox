require "signet/oauth_2/client"

module Gmail
  # One-time OAuth consent for a mailbox. Uses the loopback redirect, so it is
  # run on the Mac itself: open the URL, approve, and paste back the URL the
  # browser lands on (the page fails to load; the code is in its address).
  module Authorization
    SCOPE = "https://www.googleapis.com/auth/gmail.modify".freeze
    REDIRECT_URI = "http://localhost:8765".freeze

    module_function

    def client_id = ENV.fetch("GMAIL_CLIENT_ID")
    def client_secret = ENV.fetch("GMAIL_CLIENT_SECRET")

    def configured?
      ENV["GMAIL_CLIENT_ID"].present? && ENV["GMAIL_CLIENT_SECRET"].present?
    end

    def url
      oauth_client.authorization_uri(access_type: "offline", prompt: "consent").to_s
    end

    # Accepts the pasted redirect URL or the bare code; returns the refresh token.
    def exchange(pasted)
      code = pasted.to_s.include?("code=") ? Rack::Utils.parse_query(URI(pasted.strip).query)["code"] : pasted.strip
      client = oauth_client
      client.code = code
      client.fetch_access_token!
      client.refresh_token or raise "Google returned no refresh token; revoke the app's access and authorize again"
    end

    def credentials(refresh_token)
      Google::Auth::UserRefreshCredentials.new(
        client_id: client_id, client_secret: client_secret, refresh_token: refresh_token, scope: SCOPE
      )
    end

    def oauth_client
      Signet::OAuth2::Client.new(
        authorization_uri: "https://accounts.google.com/o/oauth2/v2/auth",
        token_credential_uri: "https://oauth2.googleapis.com/token",
        client_id: client_id,
        client_secret: client_secret,
        scope: SCOPE,
        redirect_uri: REDIRECT_URI
      )
    end
  end
end
