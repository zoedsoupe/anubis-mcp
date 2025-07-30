import Config

boolean = fn env ->
  System.get_env(env) in ["1", "true"]
end

config :anubis_mcp, compile_cli?: boolean.("ANUBIS_MCP_COMPILE_CLI")

config :logger, :default_formatter,
  format: "[$level] $message $metadata\n",
  metadata: [:mcp_server, :mcp_client, :mcp_client_name, :mcp_transport]
