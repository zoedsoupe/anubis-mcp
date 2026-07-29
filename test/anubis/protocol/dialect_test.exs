defmodule Anubis.Protocol.DialectTest do
  use ExUnit.Case, async: true

  alias Anubis.Protocol.V2024_11_05
  alias Anubis.Protocol.V2025_03_26
  alias Anubis.Protocol.V2025_06_18
  alias Anubis.Protocol.V2025_11_25

  @versions [V2024_11_05, V2025_03_26, V2025_06_18, V2025_11_25]

  describe "era/0" do
    test "all current versions belong to the legacy era" do
      for mod <- @versions do
        assert mod.era() == :legacy
      end
    end
  end

  describe "supports_feature?/1" do
    test "agrees with supported_features/0" do
      for mod <- @versions, feature <- mod.supported_features() do
        assert mod.supports_feature?(feature)
      end
    end

    test "reports version-specific features" do
      refute V2024_11_05.supports_feature?(:elicitation)
      refute V2025_03_26.supports_feature?(:elicitation)
      assert V2025_06_18.supports_feature?(:elicitation)
      refute V2025_06_18.supports_feature?(:tasks)
      assert V2025_11_25.supports_feature?(:tasks)
    end
  end

  describe "transport_rules/0" do
    test "early versions allow batching and do not require the version header" do
      assert %{batching: true, protocol_version_header: false} = V2024_11_05.transport_rules()
      assert %{batching: true, protocol_version_header: false} = V2025_03_26.transport_rules()
    end

    test "2025-06-18 removes batching and requires the version header" do
      assert %{batching: false, protocol_version_header: true} = V2025_06_18.transport_rules()
      assert %{batching: false, protocol_version_header: true} = V2025_11_25.transport_rules()
    end
  end

  describe "server_capabilities/1" do
    @declared %{"tools" => %{}, "resources" => %{}, "tasks" => %{"list" => true}}

    test "older versions drop capabilities introduced later" do
      assert V2024_11_05.server_capabilities(@declared) == %{"tools" => %{}, "resources" => %{}}
      assert V2025_06_18.server_capabilities(@declared) == %{"tools" => %{}, "resources" => %{}}
    end

    test "2025-11-25 advertises the tasks capability" do
      assert V2025_11_25.server_capabilities(@declared) == @declared
    end
  end

  describe "request_result_schema/1" do
    test "returns nil for unmodeled methods" do
      for mod <- @versions do
        assert mod.request_result_schema("tools/call") == nil
        assert mod.request_result_schema("unknown/method") == nil
      end
    end

    test "sampling result in 2024-11-05 accepts text and image content only" do
      schema = V2024_11_05.request_result_schema("sampling/createMessage")

      assert {:ok, _} =
               Peri.validate(schema, %{
                 "role" => "assistant",
                 "content" => %{"type" => "text", "text" => "hi"},
                 "model" => "m"
               })

      assert {:error, _} =
               Peri.validate(schema, %{
                 "role" => "assistant",
                 "content" => %{"type" => "audio", "data" => "AA==", "mimeType" => "audio/mp3"},
                 "model" => "m"
               })
    end

    test "sampling result from 2025-03-26 on accepts audio content" do
      for mod <- [V2025_03_26, V2025_06_18, V2025_11_25] do
        schema = mod.request_result_schema("sampling/createMessage")

        assert {:ok, _} =
                 Peri.validate(schema, %{
                   "role" => "assistant",
                   "content" => %{"type" => "audio", "data" => "AA==", "mimeType" => "audio/mp3"},
                   "model" => "m"
                 })
      end
    end

    test "elicitation result exists from 2025-06-18 on" do
      assert V2025_03_26.request_result_schema("elicitation/create") == nil

      for mod <- [V2025_06_18, V2025_11_25] do
        schema = mod.request_result_schema("elicitation/create")
        assert {:ok, _} = Peri.validate(schema, %{"action" => "accept", "content" => %{"name" => "zoey"}})
        assert {:error, _} = Peri.validate(schema, %{"action" => "bogus"})
      end
    end
  end

  describe "message schemas" do
    test "request branches cover exactly the version's request methods" do
      for mod <- @versions do
        assert {:multi, :method, branches} = mod.request_message_schema()
        assert MapSet.new(Map.keys(branches)) == MapSet.new(mod.request_methods())
      end
    end

    test "notification branches cover exactly the version's notification methods" do
      for mod <- @versions do
        assert {:multi, :method, branches} = mod.notification_message_schema()
        assert MapSet.new(Map.keys(branches)) == MapSet.new(mod.notification_methods())
      end
    end

    test "request schema validates a versioned method envelope" do
      message = %{
        "jsonrpc" => "2.0",
        "method" => "tools/call",
        "id" => 1,
        "params" => %{"name" => "greet", "arguments" => %{}}
      }

      for mod <- @versions do
        assert {:ok, _} = Peri.validate(mod.request_message_schema(), message)
      end
    end

    test "tasks methods only validate from 2025-11-25 on" do
      message = %{"jsonrpc" => "2.0", "method" => "tasks/get", "id" => 1, "params" => %{"taskId" => "t-1"}}

      assert {:error, _} = Peri.validate(V2025_06_18.request_message_schema(), message)
      assert {:ok, _} = Peri.validate(V2025_11_25.request_message_schema(), message)
    end

    test "elicitation only validates from 2025-06-18 on" do
      message = %{
        "jsonrpc" => "2.0",
        "method" => "elicitation/create",
        "id" => 1,
        "params" => %{
          "message" => "name?",
          "requestedSchema" => %{"type" => "object", "properties" => %{"name" => %{"type" => "string"}}}
        }
      }

      assert {:error, _} = Peri.validate(V2025_03_26.request_message_schema(), message)
      assert {:ok, _} = Peri.validate(V2025_06_18.request_message_schema(), message)
    end

    test "progress notification message field exists from 2025-03-26 on" do
      params = %{"progressToken" => "t", "progress" => 1, "message" => "working"}

      assert {:ok, validated} = Peri.validate(V2025_03_26.notification_message_schema(), envelope(params))
      assert validated["params"]["message"] == "working"

      assert {:ok, validated} = Peri.validate(V2024_11_05.notification_message_schema(), envelope(params))
      refute Map.has_key?(validated["params"], "message")
    end

    test "requests carry the progress _meta slot" do
      message = %{
        "jsonrpc" => "2.0",
        "method" => "tools/list",
        "id" => 1,
        "params" => %{"_meta" => %{"progressToken" => "tok"}}
      }

      assert {:ok, validated} = Peri.validate(V2024_11_05.request_message_schema(), message)
      assert validated["params"]["_meta"] == %{"progressToken" => "tok"}
    end

    test "initialize keeps its open _meta extension namespace" do
      message = %{
        "jsonrpc" => "2.0",
        "method" => "initialize",
        "id" => 1,
        "params" => %{
          "protocolVersion" => "2024-11-05",
          "capabilities" => %{},
          "_meta" => %{"appId" => "acme"},
          "clientInfo" => %{"name" => "c", "version" => "1"}
        }
      }

      assert {:ok, validated} = Peri.validate(V2024_11_05.request_message_schema(), message)
      assert validated["params"]["_meta"] == %{"appId" => "acme"}
    end
  end

  defp envelope(params) do
    %{"jsonrpc" => "2.0", "method" => "notifications/progress", "params" => params}
  end
end
