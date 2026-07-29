defmodule Anubis.Server.Transport.SessionTest do
  use Anubis.MCP.Case, async: false

  alias Anubis.Server.Transport.Session, as: SessionDispatcher
  alias Anubis.Server.Transport.Session.Local

  @moduletag capture_log: true

  defmodule RecordingDispatcher do
    @moduledoc false

    @behaviour SessionDispatcher

    @impl true
    def dispatch_request(session, message, context, opts) do
      record(context, {:request, message, opts})
      Local.dispatch_request(session, message, context, opts)
    end

    @impl true
    def dispatch_notification(session, message, context) do
      record(context, {:notification, message})
      Local.dispatch_notification(session, message, context)
    end

    @impl true
    def dispatch_response(session, message, context) do
      record(context, {:response, message})
      Local.dispatch_response(session, message, context)
    end

    defp record(%{test_pid: pid}, entry), do: send(pid, {:dispatched, entry})
    defp record(_context, _entry), do: :ok
  end

  describe "Local dispatcher" do
    setup :initialized_server

    test "dispatch_request/4 delivers the request and returns the encoded reply", %{server: session} do
      ping = build_request("ping")

      assert {:ok, reply} = Local.dispatch_request(session, ping, %{}, [])
      assert %{"result" => %{}, "id" => id} = JSON.decode!(reply)
      assert id == ping["id"]
    end

    test "dispatch_notification/3 delivers the notification asynchronously", %{server: session} do
      notification = build_notification("notifications/initialized", %{})

      assert :ok = Local.dispatch_notification(session, notification, %{})
    end

    test "dispatch_response/3 delivers the response asynchronously", %{server: session} do
      response = build_response(%{}, "unknown-request-id")

      assert :ok = Local.dispatch_response(session, response, %{})
    end
  end

  describe "configured dispatcher" do
    setup do
      Application.put_env(:anubis_mcp, :session_dispatcher, RecordingDispatcher)
      on_exit(fn -> Application.delete_env(:anubis_mcp, :session_dispatcher) end)
    end

    setup :initialized_server

    test "delegates every dispatch call to the configured adapter", %{server: session} do
      context = %{test_pid: self()}

      ping = build_request("ping")
      assert {:ok, _} = SessionDispatcher.dispatch_request(session, ping, context)
      assert_received {:dispatched, {:request, ^ping, []}}

      notification = build_notification("notifications/initialized", %{})
      assert :ok = SessionDispatcher.dispatch_notification(session, notification, context)
      assert_received {:dispatched, {:notification, ^notification}}

      response = build_response(%{}, "unknown-request-id")
      assert :ok = SessionDispatcher.dispatch_response(session, response, context)
      assert_received {:dispatched, {:response, ^response}}
    end
  end

  test "dispatcher defaults to the local adapter" do
    Application.delete_env(:anubis_mcp, :session_dispatcher)

    assert Anubis.get_session_dispatcher() == Local
  end
end
