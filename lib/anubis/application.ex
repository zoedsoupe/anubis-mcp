defmodule Anubis.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    :logger.add_handlers(:anubis_mcp)

    children =
      [
        {Finch, name: Anubis.Finch, pools: %{default: [size: 15]}}
      ] ++ maybe_start_session_store()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Anubis.Supervisor]
    {:ok, pid} = Supervisor.start_link(children, opts)

    if Anubis.should_compile_cli?() do
      with {:module, cli} <- Code.ensure_loaded(Anubis.CLI), do: cli.main()
      {:ok, pid}
    else
      {:ok, pid}
    end
  end

  defp maybe_start_session_store do
    case Application.get_env(:anubis_mcp, :session_store) do
      nil ->
        []

      config ->
        # Check if session store is enabled
        if Keyword.get(config, :enabled, false) do
          adapter = Keyword.get(config, :adapter)

          if adapter && Code.ensure_loaded?(adapter) do
            require Logger

            Logger.info("Starting session store: #{inspect(adapter)}", %{
              enabled: true,
              adapter: adapter,
              ttl: Keyword.get(config, :ttl),
              namespace: Keyword.get(config, :namespace)
            })

            [{adapter, config}]
          else
            require Logger

            Logger.warning("Session store enabled but adapter not available: #{inspect(adapter)}")
            []
          end
        else
          require Logger

          Logger.debug("Session store configured but not enabled")
          []
        end
    end
  end
end
