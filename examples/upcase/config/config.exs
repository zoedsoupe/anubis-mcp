import Config

config :anubis_mcp, log: true

if config_env() == :dev do
  config :logger, level: :debug
end
