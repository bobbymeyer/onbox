require "test_helper"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  # Phone-sized, since the dispenser is phone-first. Chrome refuses to start
  # as root without --no-sandbox (containers).
  driven_by :selenium, using: :headless_chrome, screen_size: [ 390, 844 ] do |options|
    options.add_argument("--no-sandbox") if Process.uid.zero?
  end
end
