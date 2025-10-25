import Config

boolean = fn env ->
  System.get_env(env) in ["1", "true"]
end

config :anubis_mcp, compile_cli?: boolean.("ANUBIS_MCP_COMPILE_CLI")

config :logger, :default_formatter,
  format: "[$level] $message $metadata\n",
  metadata: [:mcp_server, :mcp_client, :mcp_client_name, :mcp_transport]

# Session store configuration - disabled by default
# To enable Redis persistence, uncomment and configure:
# config :anubis_mcp, :session_store,
#   enabled: true,
#   adapter: Anubis.Server.Session.Store.Redis,
#   redis_url: System.get_env("REDIS_URL", "redis://localhost:6379/0"),
#   pool_size: 10,
#   ttl: 1800,  # 30 minutes in seconds
#   namespace: "anubis:sessions",
#   connection_name: :anubis_redis
