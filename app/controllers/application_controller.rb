class ApplicationController < ActionController::Base
  allow_browser versions: :modern

  stale_when_importmap_changes

  # Tailscale is the perimeter; a password is an optional second lock.
  if (password = ENV["STACK_PASSWORD"]).present?
    http_basic_authenticate_with name: ENV.fetch("STACK_USER", "bobby"), password: password
  end
end
