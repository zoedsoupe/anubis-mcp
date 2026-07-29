defmodule Anubis.Server.Transport.Session do
  @moduledoc """
  Public contract between server transports and session processes.

  Transports never talk to `Anubis.Server.Session` internals directly. Every
  client message flows through a *session dispatcher* implementing this
  behaviour, so the delivery mechanism can be swapped without touching
  transport code (for example, to route sessions across a cluster).

  ## Wire protocol

  The default dispatcher (`Anubis.Server.Transport.Session.Local`) delivers
  messages to the session process with these shapes, which are part of the
  public contract and handled by `Anubis.Server.Session`:

    * `{:mcp_request, message, context}` — synchronous `GenServer.call/3`.
      The session replies `{:ok, binary() | nil}` with the JSON-encoded
      response (`nil` when no response body is due), or `{:error, term()}`.
    * `{:mcp_notification, message, context}` — asynchronous `GenServer.cast/2`
      for client notifications.
    * `{:mcp_response, message, context}` — asynchronous `GenServer.cast/2`
      for client responses to server-initiated requests (sampling, roots,
      elicitation).

  ## Transport context

  The `context` is a map carrying request metadata from the transport to the
  session. Keys are transport-specific; the ones consumed by
  `Anubis.Server.Session` are:

    * `:assigns` — map merged into the frame assigns
    * `:req_headers` — HTTP request headers, exposed on the context
    * `:remote_ip` — client IP, exposed on the context
    * `:auth` — validated auth claims, exposed on the context

  Transports may add any other keys (e.g. `:type`, `:query_params`); sessions
  ignore unknown keys.

  ## Swapping the dispatcher

  All dispatch functions on this module delegate to the configured adapter,
  which defaults to `Anubis.Server.Transport.Session.Local`:

      config :anubis_mcp, :session_dispatcher, MyApp.ClusterDispatcher

  A custom dispatcher must implement this behaviour. It receives the same
  `t:session/0` reference transports already resolved, so a cluster-aware
  implementation can encode routing information in a `:via` tuple or resolve
  the owning node from the session id carried in the `t:context/0`.
  """

  @typedoc "A reference to a session process, as resolved by the transport."
  @type session :: GenServer.server()

  @typedoc "A decoded JSON-RPC message (map with string keys)."
  @type message :: %{String.t() => term()}

  @typedoc "Transport context map. See the module documentation for known keys."
  @type context :: %{optional(atom()) => term()}

  @typedoc "Reply expected from a dispatched request."
  @type request_reply :: {:ok, binary() | nil} | {:error, term()}

  @typedoc "Wire shape for client requests delivered to a session."
  @type request_wire :: {:mcp_request, message(), context()}

  @typedoc "Wire shape for client notifications delivered to a session."
  @type notification_wire :: {:mcp_notification, message(), context()}

  @typedoc "Wire shape for client responses delivered to a session."
  @type response_wire :: {:mcp_response, message(), context()}

  @doc """
  Delivers a client request to the session and returns its reply.

  Supported options:

    * `:timeout` — how long to wait for the session reply (default: 5000)
  """
  @callback dispatch_request(session(), message(), context(), opts) :: request_reply()
            when opts: [{:timeout, timeout()}]

  @doc "Delivers a client notification to the session."
  @callback dispatch_notification(session(), message(), context()) :: :ok

  @doc "Delivers a client response (to a server-initiated request) to the session."
  @callback dispatch_response(session(), message(), context()) :: :ok

  @doc """
  Dispatches a client request through the configured dispatcher.

  See `c:dispatch_request/4`.
  """
  @spec dispatch_request(session(), message(), context(), keyword()) :: request_reply()
  def dispatch_request(session, message, context, opts \\ []) do
    dispatcher().dispatch_request(session, message, context, opts)
  end

  @doc """
  Dispatches a client notification through the configured dispatcher.

  See `c:dispatch_notification/3`.
  """
  @spec dispatch_notification(session(), message(), context()) :: :ok
  def dispatch_notification(session, message, context) do
    dispatcher().dispatch_notification(session, message, context)
  end

  @doc """
  Dispatches a client response through the configured dispatcher.

  See `c:dispatch_response/3`.
  """
  @spec dispatch_response(session(), message(), context()) :: :ok
  def dispatch_response(session, message, context) do
    dispatcher().dispatch_response(session, message, context)
  end

  defp dispatcher, do: Anubis.get_session_dispatcher()
end
