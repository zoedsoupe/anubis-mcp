defmodule Anubis do
  @moduledoc false

  import Peri

  alias Anubis.Server.Transport.STDIO, as: ServerSTDIO
  alias Anubis.Server.Transport.StreamableHTTP, as: ServerStreamableHTTP
  alias Anubis.Transport.STDIO, as: ClientSTDIO
  alias Anubis.Transport.StreamableHTTP, as: ClientStreamableHTTP

  @client_transports if Mix.env() == :test,
                       do: [
                         ClientSTDIO,
                         ClientStreamableHTTP,
                         StubTransport,
                         FakeTransport,
                         BufferedMockTransport
                       ],
                       else: [ClientSTDIO, ClientStreamableHTTP]

  @server_transports if Mix.env() == :test,
                       do: [
                         ServerSTDIO,
                         ServerStreamableHTTP,
                         StubTransport
                       ],
                       else: [ServerSTDIO, ServerStreamableHTTP]

  defschema :client_transport,
    layer: {:required, {:enum, @client_transports}},
    name: {:required, get_schema(:process_name)}

  defschema :server_transport,
    layer: {:required, {:enum, @server_transports}},
    name: {:required, get_schema(:process_name)}

  defschema :process_name, {:either, {:pid, {:custom, &genserver_name/1}}}

  @doc false
  def genserver_name({:via, registry, _}) when is_atom(registry), do: :ok
  def genserver_name({:global, _}), do: :ok
  def genserver_name(name) when is_atom(name), do: :ok

  def genserver_name(val) do
    {:error, "#{inspect(val, pretty: true)} is not a valid name for a GenServer"}
  end

  @doc false
  def exported?(m, f, a) do
    function_exported?(m, f, a) or
      (Code.ensure_loaded?(m) and function_exported?(m, f, a))
  end

  @spec get_session_store_adapter :: nil | module
  def get_session_store_adapter do
    config = Application.get_env(:anubis_mcp, :session_store)
    enabled? = config[:enabled] || false
    adapter = config[:adapter]

    if enabled? && Code.ensure_loaded?(adapter), do: adapter
  end

  @default_session_store_ttl to_timeout(minute: 30)

  @spec get_session_store_ttl :: pos_integer
  def get_session_store_ttl do
    config = Application.get_env(:anubis_mcp, :session_store) || []
    config[:ttl] || @default_session_store_ttl
  end

  @typedoc "A resolved session store: the adapter and the options it was started with."
  @type session_store :: nil | {module(), keyword()}

  @doc """
  Resolves the session store a server should use, preferring the server's
  own `:session_store` option over the global `config :anubis_mcp,
  :session_store`.

  The `:session_store` option accepts:

    * `{module, opts}` — start this adapter with these opts
    * `module` — start this adapter with no opts
    * `false` or `nil` — no store for this server, even when one is
      configured globally

  Anything else falls back to the global config.
  """
  @spec resolve_session_store(keyword()) :: session_store()
  def resolve_session_store(opts) do
    case Keyword.get(opts, :session_store, :__global__) do
      :__global__ -> global_session_store()
      false -> nil
      nil -> nil
      {adapter, store_opts} when is_atom(adapter) and is_list(store_opts) -> {adapter, store_opts}
      adapter when is_atom(adapter) -> {adapter, []}
    end
  end

  @spec global_session_store() :: session_store()
  defp global_session_store do
    config = Application.get_env(:anubis_mcp, :session_store) || []
    enabled? = Keyword.get(config, :enabled, false)
    adapter = Keyword.get(config, :adapter)

    cond do
      not enabled? -> nil
      is_nil(adapter) -> nil
      Code.ensure_loaded?(adapter) -> {adapter, config}
      true -> nil
    end
  end

  @spec get_session_dispatcher :: module
  def get_session_dispatcher do
    Application.get_env(:anubis_mcp, :session_dispatcher, Anubis.Server.Transport.Session.Local)
  end
end
