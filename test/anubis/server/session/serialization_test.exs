defmodule Anubis.Server.Session.SerializationTest do
  use ExUnit.Case, async: true

  alias Anubis.Protocol.V2025_03_26
  alias Anubis.Server.Frame
  alias Anubis.Server.Session

  describe "to_serializable/1" do
    test "produces a JSON-safe map from session state" do
      state = build_state()

      result = Session.to_serializable(state)

      assert result.id == "session_123"
      assert result.protocol_version == "2025-03-26"
      assert result.protocol_module == "Elixir.Anubis.Protocol.V2025_03_26"
      assert result.initialized == true
      assert result.client_info == %{"name" => "test_client"}
      assert result.client_capabilities == %{"tools" => %{}}
      assert result.log_level == "info"
      assert result.pending_requests == %{"req1" => %{started_at: 1000, method: "tools/list"}}
      assert is_map(result.frame)
    end

    test "converts protocol_module atom to string" do
      state = build_state(protocol_module: V2025_03_26)

      result = Session.to_serializable(state)

      assert result.protocol_module == "Elixir.Anubis.Protocol.V2025_03_26"
    end

    test "handles nil protocol_module" do
      state = build_state(protocol_module: nil)

      result = Session.to_serializable(state)

      assert result.protocol_module == nil
    end

    test "excludes non-serializable fields" do
      state = build_state()

      result = Session.to_serializable(state)

      refute Map.has_key?(result, :transport)
      refute Map.has_key?(result, :registry)
      refute Map.has_key?(result, :expiry_timer)
      refute Map.has_key?(result, :server_module)
      refute Map.has_key?(result, :server_info)
      refute Map.has_key?(result, :capabilities)
      refute Map.has_key?(result, :supported_versions)
      refute Map.has_key?(result, :task_supervisor)
      refute Map.has_key?(result, :server_requests)
      refute Map.has_key?(result, :timeout)
      refute Map.has_key?(result, :session_idle_timeout)
    end

    test "can be encoded to JSON without errors" do
      state = build_state()

      serializable = Session.to_serializable(state)

      assert {:ok, _json} = try_json_encode(serializable)
    end
  end

  describe "from_serializable/1" do
    test "reconstructs session data from deserialized JSON map" do
      state = build_state()

      round_tripped =
        state
        |> Session.to_serializable()
        |> json_round_trip()
        |> Session.from_serializable()

      assert round_tripped.session_id == "session_123"
      assert round_tripped.protocol_version == "2025-03-26"
      assert round_tripped.initialized == true
      assert round_tripped.client_info == %{"name" => "test_client"}
      assert round_tripped.client_capabilities == %{"tools" => %{}}
      assert round_tripped.log_level == "info"
    end

    test "converts protocol_module string back to atom" do
      state = build_state(protocol_module: V2025_03_26)

      round_tripped =
        state
        |> Session.to_serializable()
        |> json_round_trip()
        |> Session.from_serializable()

      assert round_tripped.protocol_module == V2025_03_26
    end

    test "handles nil protocol_module" do
      state = build_state(protocol_module: nil)

      round_tripped =
        state
        |> Session.to_serializable()
        |> json_round_trip()
        |> Session.from_serializable()

      assert round_tripped.protocol_module == nil
    end

    test "handles missing optional fields gracefully" do
      minimal = %{"id" => "s1", "initialized" => false}

      result = Session.from_serializable(minimal)

      assert result.session_id == "s1"
      assert result.initialized == false
      assert result.pending_requests == %{}
      assert %Frame{} = result.frame
    end
  end

  defp build_state(overrides \\ []) do
    defaults = %{
      session_id: "session_123",
      server_module: StubServer,
      protocol_version: "2025-03-26",
      protocol_module: V2025_03_26,
      initialized: true,
      client_info: %{"name" => "test_client"},
      client_capabilities: %{"tools" => %{}},
      log_level: "info",
      frame: %Frame{assigns: %{"key" => "value"}, pagination_limit: 10},
      server_info: %{name: "test"},
      capabilities: %{},
      supported_versions: ["2025-03-26"],
      transport: %{layer: StubTransport, name: :some_pid},
      registry: Anubis.Server.Registry,
      session_idle_timeout: 30_000,
      expiry_timer: make_ref(),
      pending_requests: %{"req1" => %{started_at: 1000, method: "tools/list"}},
      server_requests: %{"sreq1" => %{method: "sampling/createMessage", timer_ref: make_ref()}},
      timeout: 30_000,
      task_supervisor: :task_sup
    }

    Map.merge(defaults, Map.new(overrides))
  end

  defp json_round_trip(data) do
    data |> JSON.encode!() |> JSON.decode!()
  end

  defp try_json_encode(data) do
    {:ok, JSON.encode!(data)}
  rescue
    e -> {:error, e}
  end
end
