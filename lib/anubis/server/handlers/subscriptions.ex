defmodule Anubis.Server.Handlers.Subscriptions do
  @moduledoc false

  alias Anubis.MCP.Error
  alias Anubis.Server.Frame
  alias Anubis.Server.Handlers.Resources

  @max_resource_subscriptions 1_000

  @list_changed_flags %{
    "toolsListChanged" => "tools",
    "promptsListChanged" => "prompts",
    "resourcesListChanged" => "resources"
  }

  @doc """
  Decides which of the notifications a `subscriptions/listen` request asks for
  the server will honor, and records the resource subscriptions on the frame.

  A list-changed flag is honored when the server declares `listChanged` for
  that capability. A resource URI is honored when the server declares
  `resources.subscribe` and the URI passes the same scope check as a
  handshake-era `resources/subscribe`. Everything else is left out of the
  result, which is the filter the acknowledgment carries.

  More than 1,000 `resourceSubscriptions` is `-32602`: the session and its
  stream each hold the accepted list for as long as the client listens. A URI
  asked for twice is honored once.
  """
  @spec handle_listen(map(), Frame.t(), module()) :: {:reply, map(), Frame.t()} | {:error, Error.t(), Frame.t()}
  def handle_listen(request, frame, server) do
    requested = get_in(request, ["params", "notifications"]) || %{}

    if length(requested["resourceSubscriptions"] || []) > @max_resource_subscriptions do
      message = "resourceSubscriptions accepts at most #{@max_resource_subscriptions} URIs"
      {:error, Error.protocol(:invalid_params, %{message: message}), frame}
    else
      listen(requested, frame, server)
    end
  end

  defp listen(requested, frame, server) do
    capabilities = server.server_capabilities()

    honored =
      for {flag, capability} <- @list_changed_flags,
          requested[flag] == true,
          declared?(capabilities, capability, :listChanged),
          into: %{},
          do: {flag, true}

    {uris, frame} = subscribe_resources(Enum.uniq(requested["resourceSubscriptions"] || []), frame, server)
    honored = if uris == [], do: honored, else: Map.put(honored, "resourceSubscriptions", uris)

    {:reply, %{"notifications" => honored}, frame}
  end

  defp subscribe_resources(uris, frame, server) do
    {accepted, frame} =
      Enum.reduce(uris, {[], frame}, fn uri, {accepted, frame} ->
        case Resources.handle_subscribe(%{"params" => %{"uri" => uri}}, frame, server) do
          {:reply, _result, frame} -> {[uri | accepted], frame}
          {:error, _error, frame} -> {accepted, frame}
        end
      end)

    {Enum.reverse(accepted), frame}
  end

  defp declared?(capabilities, capability, key) do
    case Map.get(capabilities, capability) do
      %{} = config -> Map.get(config, key) == true or Map.get(config, Atom.to_string(key)) == true
      _ -> false
    end
  end
end
