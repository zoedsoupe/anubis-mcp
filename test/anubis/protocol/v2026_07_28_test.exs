# credo:disable-for-this-file Credo.Check.Readability.ModuleNames
defmodule Anubis.Protocol.V2026_07_28Test do
  use ExUnit.Case, async: true

  alias Anubis.MCP.Message
  alias Anubis.Protocol.Schema
  alias Anubis.Protocol.V2025_11_25
  alias Anubis.Protocol.V2026_07_28

  @meta %{
    "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
    "io.modelcontextprotocol/clientCapabilities" => %{"elicitation" => %{}}
  }

  defp request(method, params \\ %{}) do
    %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => Map.put(params, "_meta", @meta)}
  end

  describe "version/0 and era/0" do
    test "identifies the first stateless version" do
      assert V2026_07_28.version() == "2026-07-28"
      assert V2026_07_28.era() == :stateless
    end
  end

  describe "request_methods/0" do
    test "adds discovery and subscriptions" do
      assert "server/discover" in V2026_07_28.request_methods()
      assert "subscriptions/listen" in V2026_07_28.request_methods()
    end

    test "drops the handshake, ping and logging/setLevel" do
      for method <- ~w(initialize ping logging/setLevel) do
        refute method in V2026_07_28.request_methods()
      end
    end

    test "drops the resource subscribe RPCs replaced by subscriptions/listen" do
      for method <- ~w(resources/subscribe resources/unsubscribe) do
        refute method in V2026_07_28.request_methods()
      end
    end

    test "drops server-initiated requests, now carried by MRTR" do
      for method <- ~w(roots/list sampling/createMessage elicitation/create) do
        refute method in V2026_07_28.request_methods()
      end
    end

    test "drops the task methods, now an extension" do
      for method <- V2025_11_25.request_methods(), String.starts_with?(method, "tasks/") do
        refute method in V2026_07_28.request_methods()
      end
    end

    test "keeps the core primitives" do
      for method <- ~w(tools/list tools/call prompts/list prompts/get
                       resources/list resources/templates/list resources/read
                       completion/complete) do
        assert method in V2026_07_28.request_methods()
      end
    end
  end

  describe "notification_methods/0" do
    test "adds the subscription acknowledgement" do
      assert "notifications/subscriptions/acknowledged" in V2026_07_28.notification_methods()
    end

    test "drops initialized, roots list_changed and task status" do
      for method <- ~w(notifications/initialized notifications/roots/list_changed notifications/tasks/status) do
        refute method in V2026_07_28.notification_methods()
      end
    end
  end

  describe "supported_features/0" do
    @introduced [:stateless, :discovery, :subscriptions, :multi_round_trip_requests, :result_caching, :extensions]

    test "declares the features this revision introduces" do
      for feature <- @introduced do
        assert V2026_07_28.supports_feature?(feature)
      end
    end

    test "no longer supports ping" do
      refute V2026_07_28.supports_feature?(:ping)
    end
  end

  describe "server_capabilities/1" do
    test "advertises the new extensions capability and drops tasks" do
      declared = %{
        "tools" => %{},
        "logging" => %{},
        "extensions" => %{"io.modelcontextprotocol/tasks" => %{}},
        "tasks" => %{"list" => true}
      }

      shaped = V2026_07_28.server_capabilities(declared)

      assert shaped == Map.delete(declared, "tasks")
    end
  end

  describe "per-request _meta" do
    test "accepts a request carrying the required fields" do
      assert {:ok, _} = Message.validate_message(request("tools/list"), V2026_07_28)
    end

    test "rejects a request whose params are missing entirely" do
      message = %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"}

      assert {:error, :invalid_request} = Message.validate_message(message, V2026_07_28)
    end

    test "rejects a request with no _meta" do
      message = %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list", "params" => %{}}

      assert {:error, :invalid_request} = Message.validate_message(message, V2026_07_28)
    end

    test "rejects a request missing protocolVersion or clientCapabilities" do
      for key <- Map.keys(@meta) do
        params = %{"_meta" => Map.delete(@meta, key)}
        message = %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list", "params" => params}

        assert {:error, :invalid_request} = Message.validate_message(message, V2026_07_28)
      end
    end

    test "rejects an unrecognized logLevel" do
      message = request("tools/list", %{})
      meta = Map.put(@meta, "io.modelcontextprotocol/logLevel", "chatty")
      message = put_in(message, ["params", "_meta"], meta)

      assert {:error, :invalid_request} = Message.validate_message(message, V2026_07_28)
    end

    test "accepts every specification log level" do
      for level <- Schema.log_levels() do
        meta = Map.put(@meta, "io.modelcontextprotocol/logLevel", level)
        message = put_in(request("tools/list"), ["params", "_meta"], meta)

        assert {:ok, _} = Message.validate_message(message, V2026_07_28)
      end
    end

    test "preserves _meta keys the version does not model" do
      meta =
        Map.merge(@meta, %{
          "com.example/tenant" => "acme",
          "traceparent" => "00-0af7651916cd43dd8448eb211c80319c-00f067aa0ba902b7-01",
          "progressToken" => "tok-1"
        })

      message = put_in(request("tools/list"), ["params", "_meta"], meta)

      assert {:ok, validated} = Message.validate_message(message, V2026_07_28)
      assert validated["params"]["_meta"] == meta
    end

    test "rejects a client identity without a name and version" do
      meta = Map.put(@meta, "io.modelcontextprotocol/clientInfo", %{"name" => "c"})
      message = put_in(request("tools/list"), ["params", "_meta"], meta)

      assert {:error, :invalid_request} = Message.validate_message(message, V2026_07_28)
    end
  end

  describe "server/discover" do
    test "takes no parameters beyond _meta" do
      assert V2026_07_28.request_params_schema("server/discover") == %{}
      assert {:ok, _} = Message.validate_message(request("server/discover"), V2026_07_28)
    end
  end

  describe "subscriptions/listen" do
    test "accepts the notification filter" do
      params = %{
        "notifications" => %{
          "toolsListChanged" => true,
          "resourceSubscriptions" => ["file:///project/config.json"]
        }
      }

      assert {:ok, _} = Message.validate_message(request("subscriptions/listen", params), V2026_07_28)
    end

    test "rejects a filter with the wrong types" do
      params = %{"notifications" => %{"toolsListChanged" => "yes"}}

      assert {:error, :invalid_request} = Message.validate_message(request("subscriptions/listen", params), V2026_07_28)
    end

    test "acknowledgement notifications carry a _meta slot for the subscription id" do
      schema = V2026_07_28.notification_params_schema("notifications/subscriptions/acknowledged")

      assert {:required, :map} = schema["_meta"]
    end
  end

  describe "multi round-trip request retries" do
    @retry %{
      "inputResponses" => %{"github_login" => %{"action" => "accept"}},
      "requestState" => "opaque-blob"
    }

    test "the three supported methods carry inputResponses and requestState through" do
      retries = [
        {"tools/call", %{"name" => "weather", "arguments" => %{}}},
        {"prompts/get", %{"name" => "summarize"}},
        {"resources/read", %{"uri" => "file:///a.txt"}}
      ]

      for {method, params} <- retries do
        message = request(method, Map.merge(params, @retry))

        assert {:ok, validated} = Message.validate_message(message, V2026_07_28)
        assert validated["params"]["inputResponses"] == @retry["inputResponses"]
        assert validated["params"]["requestState"] == @retry["requestState"]
      end
    end

    test "methods that cannot return input_required drop retry fields before dispatch" do
      for method <- ~w(tools/list prompts/list resources/list server/discover) do
        message = request(method, @retry)

        assert {:ok, validated} = Message.validate_message(message, V2026_07_28)
        refute Map.has_key?(validated["params"], "inputResponses")
        refute Map.has_key?(validated["params"], "requestState")
      end
    end

    test "requestState must be a string" do
      params = %{"uri" => "file:///a.txt", "requestState" => %{"forged" => true}}

      assert {:error, :invalid_request} = Message.validate_message(request("resources/read", params), V2026_07_28)
    end
  end

  describe "unknown methods" do
    test "report method_not_found rather than a schema failure" do
      for method <- ~w(initialize ping resources/subscribe tasks/get) do
        assert {:error, :method_not_found} = Message.validate_message(request(method), V2026_07_28)
      end
    end
  end
end
