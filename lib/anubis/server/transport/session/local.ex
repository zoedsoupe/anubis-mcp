defmodule Anubis.Server.Transport.Session.Local do
  @moduledoc """
  Default session dispatcher for single-node deployments.

  Delivers messages straight to the session process with `GenServer.call/3`
  and `GenServer.cast/2`, using the wire shapes documented in
  `Anubis.Server.Transport.Session`.
  """

  @behaviour Anubis.Server.Transport.Session

  alias Anubis.Server.Transport.Session

  @default_timeout 5000

  @impl Session
  def dispatch_request(session, message, context, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    GenServer.call(session, {:mcp_request, message, context}, timeout)
  end

  @impl Session
  def dispatch_notification(session, message, context) do
    GenServer.cast(session, {:mcp_notification, message, context})
  end

  @impl Session
  def dispatch_response(session, message, context) do
    GenServer.cast(session, {:mcp_response, message, context})
  end
end
