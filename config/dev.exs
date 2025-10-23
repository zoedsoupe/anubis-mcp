import Config

# Enable session persistence in development
if System.get_env("ENABLE_SESSION_STORE") == "true" do
  config :anubis_mcp, :session_store,
    enabled: true,
    adapter: Anubis.Server.Session.Store.Redis,
    redis_url: System.get_env("REDIS_URL", "redis://localhost:6379/0"),
    pool_size: String.to_integer(System.get_env("REDIS_POOL_SIZE", "10")),
    ttl: String.to_integer(System.get_env("SESSION_TTL", "1800")),
    namespace: System.get_env("SESSION_NAMESPACE", "anubis:sessions"),
    connection_name: :anubis_redis
end
