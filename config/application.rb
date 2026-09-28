require_relative "boot"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Stack
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # "Tonight" and "tomorrow morning" resolve in this zone.
    config.time_zone = ENV.fetch("STACK_TIME_ZONE", "UTC")

    # The Secretary writes card fronts against an OpenAI-compatible endpoint,
    # constrained to a JSON schema. Any server that speaks
    # /v1/chat/completions with a json_schema response_format will do; on the
    # Mac Studio it is llama-swap, reached over the tailnet by default and
    # straight down the host's loopback port from inside a container.
    config.x.llm.base_url = ENV.fetch("STACK_SECRETARY_URL", "https://chat.bobbymeyer.com/v1")
    config.x.llm.model = ENV["STACK_SECRETARY_MODEL"]
    # config.eager_load_paths << Rails.root.join("extras")
  end
end
