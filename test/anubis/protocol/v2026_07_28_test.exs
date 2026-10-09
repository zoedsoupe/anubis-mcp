# credo:disable-for-this-file Credo.Check.Readability.ModuleNames
defmodule Anubis.Protocol.V2026_07_28Test do
  use ExUnit.Case, async: true

  alias Anubis.MCP.Message
  alias Anubis.Protocol.Registry
  alias Anubis.Protocol.Schema
  alias Anubis.Protocol.V2025_11_25
  alias Anubis.Protocol.V2026_07_28

  doctest Schema

  @meta %{
    "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
    "io.modelcontextprotocol/clientCapabilities" => %{"elicitation" => %{}}
  }

  @subscription_id "io.modelcontextprotocol/subscriptionId"

  defp request(method, params \\ %{}) do
    %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => Map.put(params, "_meta", @meta)}
  end

  # `notifications/resources/updated` is the only stream notification carrying
  # a body field of its own, so it needs the `uri` alongside the tagged `_meta`.
  defp stream_notification(method, meta) do
    params =
      case method do
        "notifications/resources/updated" -> %{"_meta" => meta, "uri" => "file:///a.txt"}
        _ -> %{"_meta" => meta}
      end

    %{"jsonrpc" => "2.0", "method" => method, "params" => params}
  end

  defp input_required(request) do
    %{"resultType" => "input_required", "inputRequests" => %{"ask" => request}}
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
    @introduced [:stateless, :discovery, :subscriptions, :extensions]
    @dropped [:ping, :roots, :sampling, :elicitation]
    @deferred [:multi_round_trip_requests, :result_caching, :standard_request_headers]

    test "declares the features this revision introduces" do
      for feature <- @introduced do
        assert V2026_07_28.supports_feature?(feature)
      end
    end

    test "drops the features whose methods this revision removed" do
      for feature <- @dropped do
        refute V2026_07_28.supports_feature?(feature)
      end
    end

    test "claims no feature whose implementation has not landed" do
      for feature <- @deferred do
        refute V2026_07_28.supports_feature?(feature)
      end
    end

    test "every declared feature is backed by a method or a capability key" do
      methods = V2026_07_28.request_methods()

      assert "server/discover" in methods
      assert "subscriptions/listen" in methods
      assert Map.has_key?(V2026_07_28.server_capabilities(%{"extensions" => %{}}), "extensions")
    end

    test "keeps logging, which per-request logLevel keeps alive" do
      assert V2026_07_28.supports_feature?(:logging)
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
  end

  describe "subscription stream notifications" do
    @stream_notifications ~w(
      notifications/subscriptions/acknowledged
      notifications/resources/updated
      notifications/tools/list_changed
      notifications/prompts/list_changed
      notifications/resources/list_changed
    )

    test "every stream notification requires a subscription id" do
      for method <- @stream_notifications do
        assert {:error, :invalid_request} =
                 Message.validate_message(stream_notification(method, %{}), V2026_07_28)
      end
    end

    test "a subscription id may be a string or an integer, matching the request id" do
      for method <- @stream_notifications, id <- [4, "sub-4"] do
        message = stream_notification(method, %{@subscription_id => id})

        assert {:ok, _} = Message.validate_message(message, V2026_07_28)
      end
    end

    test "rejects a subscription id that is not a request id" do
      message = stream_notification("notifications/tools/list_changed", %{@subscription_id => %{"nested" => true}})

      assert {:error, :invalid_request} = Message.validate_message(message, V2026_07_28)
    end

    test "preserves unmodeled _meta keys alongside the subscription id" do
      meta = %{@subscription_id => 4, "com.example/tenant" => "acme"}
      message = stream_notification("notifications/tools/list_changed", meta)

      assert {:ok, validated} = Message.validate_message(message, V2026_07_28)
      assert validated["params"]["_meta"] == meta
    end
  end

  describe "request params schemas" do
    test "every request method has a map schema so _meta is always required" do
      for method <- V2026_07_28.request_methods() do
        assert is_map(V2026_07_28.request_params_schema(method)),
               "#{method} has no params schema, so its mandatory _meta would be dropped"
      end
    end

    test "a stateless branch cannot be built from an open schema" do
      assert_raise ArgumentError, ~r/must be a map/, fn ->
        Schema.stateless_request_branch("some/method", :map)
      end
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

  describe "request_result_schema/1" do
    @discover_result %{
      "resultType" => "complete",
      "supportedVersions" => ["2026-07-28"],
      "capabilities" => %{"tools" => %{}},
      "ttlMs" => 0,
      "cacheScope" => "private"
    }

    @input_required_examples [
      ~S"""
      {
        "resultType": "input_required",
        "inputRequests": {
          "github_login": {
            "method": "elicitation/create",
            "params": {
              "message": "Please provide your GitHub username",
              "requestedSchema": {
                "type": "object",
                "properties": {
                  "name": {
                    "type": "string"
                  }
                },
                "required": ["name"]
              }
            }
          },
          "capital_of_france": {
            "method": "sampling/createMessage",
            "params": {
              "messages": [
                {
                  "role": "user",
                  "content": {
                    "type": "text",
                    "text": "What is the capital of France?"
                  }
                }
              ],
              "maxTokens": 100
            }
          }
        },
        "requestState": "eyJsb2NhdGlvbiI6Ik5ldyBZb3JrIn0"
      }
      """,
      ~S"""
      {
        "resultType": "input_required",
        "requestState": "eyJwcm9ncmVzcyI6IjUwJSIsInN0YXRlIjoicHJvY2Vzc2luZyJ9"
      }
      """
    ]

    @published_examples %{
      "server/discover" => [
        ~S"""
        {
          "resultType": "complete",
          "supportedVersions": ["2026-07-28"],
          "capabilities": {
            "tools": {},
            "resources": {}
          },
          "_meta": {
            "io.modelcontextprotocol/serverInfo": {
              "name": "ExampleServer",
              "version": "1.0.0"
            }
          },
          "instructions": "This server provides weather and resource utilities. Prefer `get_weather` for forecast lookups.",
          "ttlMs": 3600000,
          "cacheScope": "public"
        }
        """
      ],
      "subscriptions/listen" => [
        ~S"""
        {
          "resultType": "complete",
          "_meta": {
            "io.modelcontextprotocol/subscriptionId": "listen-1"
          }
        }
        """
      ],
      "resources/list" => [
        ~S"""
        {
          "resultType": "complete",
          "resources": [
            {
              "uri": "file:///project/src/main.rs",
              "name": "main.rs",
              "title": "Rust Software Application Main File",
              "description": "Primary application entry point",
              "mimeType": "text/x-rust",
              "icons": [
                {
                  "src": "https://example.com/rust-file-icon.png",
                  "mimeType": "image/png",
                  "sizes": ["48x48"]
                }
              ]
            }
          ],
          "nextCursor": "eyJwYWdlIjogM30=",
          "ttlMs": 600000,
          "cacheScope": "private"
        }
        """
      ],
      "resources/templates/list" => [
        ~S"""
        {
          "resultType": "complete",
          "resourceTemplates": [
            {
              "uriTemplate": "file:///{path}",
              "name": "Project Files",
              "title": "📁 Project Files",
              "description": "Access files in the project directory",
              "mimeType": "application/octet-stream",
              "icons": [
                {
                  "src": "https://example.com/folder-icon.png",
                  "mimeType": "image/png",
                  "sizes": ["48x48"]
                }
              ]
            }
          ],
          "nextCursor": "next-page-cursor",
          "ttlMs": 3600000,
          "cacheScope": "public"
        }
        """
      ],
      "resources/read" =>
        [
          ~S"""
          {
            "resultType": "complete",
            "contents": [
              {
                "uri": "file:///project/src/main.rs",
                "mimeType": "text/x-rust",
                "text": "fn main() {\n    println!(\"Hello world!\");\n}"
              }
            ],
            "ttlMs": 60000,
            "cacheScope": "private"
          }
          """
        ] ++ @input_required_examples,
      "prompts/get" =>
        [
          ~S"""
          {
            "resultType": "complete",
            "description": "Code review prompt",
            "messages": [
              {
                "role": "user",
                "content": {
                  "type": "text",
                  "text": "Please review this Python code:\ndef hello():\n    print('world')"
                }
              }
            ]
          }
          """
        ] ++ @input_required_examples,
      "prompts/list" => [
        ~S"""
        {
          "resultType": "complete",
          "prompts": [
            {
              "name": "code_review",
              "title": "Request Code Review",
              "description": "Asks the LLM to analyze code quality and suggest improvements",
              "arguments": [
                {
                  "name": "code",
                  "description": "The code to review",
                  "required": true
                }
              ],
              "icons": [
                {
                  "src": "https://example.com/review-icon.svg",
                  "mimeType": "image/svg+xml",
                  "sizes": ["any"]
                }
              ]
            }
          ],
          "nextCursor": "next-page-cursor",
          "ttlMs": 600000,
          "cacheScope": "public"
        }
        """
      ],
      "tools/call" =>
        [
          ~S"""
          {
            "resultType": "complete",
            "content": [
              {
                "type": "text",
                "text": "Invalid departure date: must be in the future. Current date is 08/08/2025."
              }
            ],
            "isError": true
          }
          """,
          ~S"""
          {
            "resultType": "complete",
            "content": [
              {
                "type": "text",
                "text": "Found 2 users: Alice (alice@example.com) and Bob (bob@example.com)."
              }
            ],
            "structuredContent": [
              { "id": "1", "name": "Alice", "email": "alice@example.com" },
              { "id": "2", "name": "Bob", "email": "bob@example.com" }
            ]
          }
          """,
          ~S"""
          {
            "resultType": "complete",
            "content": [
              {
                "type": "text",
                "text": "{\"temperature\": 22.5, \"conditions\": \"Partly cloudy\", \"humidity\": 65}"
              }
            ],
            "structuredContent": {
              "temperature": 22.5,
              "conditions": "Partly cloudy",
              "humidity": 65
            }
          }
          """,
          ~S"""
          {
            "resultType": "complete",
            "content": [
              {
                "type": "text",
                "text": "Current weather in New York:\nTemperature: 72°F\nConditions: Partly cloudy"
              }
            ],
            "isError": false
          }
          """
        ] ++ @input_required_examples,
      "tools/list" => [
        ~S"""
        {
          "resultType": "complete",
          "tools": [
            {
              "name": "get_weather",
              "title": "Weather Information Provider",
              "description": "Get current weather information for a location",
              "inputSchema": {
                "type": "object",
                "properties": {
                  "location": {
                    "type": "string",
                    "description": "City name or zip code"
                  }
                },
                "required": ["location"]
              },
              "icons": [
                {
                  "src": "https://example.com/weather-icon.png",
                  "mimeType": "image/png",
                  "sizes": ["48x48"]
                }
              ]
            }
          ],
          "nextCursor": "next-page-cursor",
          "ttlMs": 300000,
          "cacheScope": "public"
        }
        """
      ]
    }

    test "server/discover models the result this revision requires" do
      schema = V2026_07_28.request_result_schema("server/discover")

      assert {:ok, _} = Peri.validate(schema, @discover_result)
      assert {:ok, _} = Peri.validate(schema, Map.put(@discover_result, "instructions", "hi"))
    end

    test "rejects a discover result missing a mandatory field" do
      schema = V2026_07_28.request_result_schema("server/discover")

      for key <- ~w(resultType supportedVersions capabilities ttlMs cacheScope) do
        assert {:error, _} = Peri.validate(schema, Map.delete(@discover_result, key))
      end
    end

    test "rejects a negative cache lifetime and an unknown cache scope" do
      schema = V2026_07_28.request_result_schema("server/discover")

      assert {:error, _} = Peri.validate(schema, Map.put(@discover_result, "ttlMs", -1))
      assert {:error, _} = Peri.validate(schema, Map.put(@discover_result, "cacheScope", "shared"))
    end

    test "models the result of every request method except completion/complete" do
      for method <- V2026_07_28.request_methods(), method != "completion/complete" do
        assert V2026_07_28.request_result_schema(method), "#{method} has no result schema"
      end

      assert is_nil(V2026_07_28.request_result_schema("completion/complete"))
    end

    test "the spec's published examples validate unchanged" do
      for {method, examples} <- @published_examples, json <- examples do
        example = JSON.decode!(json)

        assert Peri.validate(V2026_07_28.request_result_schema(method), example) == {:ok, example},
               "#{method} did not accept the spec example unchanged:\n#{json}"
      end
    end

    test "an input-required result carries input requests or request state" do
      for method <- ~w(tools/call prompts/get resources/read) do
        schema = V2026_07_28.request_result_schema(method)

        assert {:error, _} = Peri.validate(schema, %{"resultType" => "input_required"})
      end
    end

    test "input requests are sampling, elicitation or roots requests with their params" do
      schema = V2026_07_28.request_result_schema("tools/call")
      url_elicitation = %{"mode" => "url", "message" => "Sign in", "url" => "https://example.com/login"}

      assert {:ok, _} = Peri.validate(schema, input_required(%{"method" => "roots/list"}))

      assert {:ok, _} =
               Peri.validate(schema, input_required(%{"method" => "elicitation/create", "params" => url_elicitation}))

      assert {:error, _} = Peri.validate(schema, input_required(%{"method" => "sampling/createMessage"}))
      assert {:error, _} = Peri.validate(schema, input_required(%{"method" => "tools/call", "params" => %{}}))
    end

    test "an unrecognized result type is invalid" do
      schema = V2026_07_28.request_result_schema("tools/call")

      assert {:error, _} = Peri.validate(schema, %{"resultType" => "pending", "content" => []})
    end

    test "only tools/call, prompts/get and resources/read may ask for input" do
      result = %{"resultType" => "input_required", "requestState" => "state"}
      excluded = ~w(tools/call prompts/get resources/read completion/complete)

      for method <- V2026_07_28.request_methods(), method not in excluded do
        assert {:error, _} = Peri.validate(V2026_07_28.request_result_schema(method), result)
      end
    end

    test "list results carry cache hints" do
      schema = V2026_07_28.request_result_schema("tools/list")
      result = %{"resultType" => "complete", "tools" => [], "ttlMs" => 0, "cacheScope" => "private"}

      assert {:ok, ^result} = Peri.validate(schema, result)

      for key <- ~w(ttlMs cacheScope) do
        assert {:error, _} = Peri.validate(schema, Map.delete(result, key))
      end
    end

    test "the listen result is tagged with its subscription" do
      schema = V2026_07_28.request_result_schema("subscriptions/listen")

      assert {:ok, _} = Peri.validate(schema, %{"resultType" => "complete", "_meta" => %{@subscription_id => 7}})
      assert {:error, _} = Peri.validate(schema, %{"resultType" => "complete", "_meta" => %{}})
      assert {:error, _} = Peri.validate(schema, %{"resultType" => "complete"})
    end
  end

  describe "era-aware decoding" do
    @discover ~s({"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"VERSION","io.modelcontextprotocol/clientCapabilities":{}}}}\n)

    defp discover_request(version), do: String.replace(@discover, "VERSION", version)

    test "decode/1 validates a message against the version it declares" do
      [stateless | _] = Registry.stateless_versions()

      assert {:ok, [decoded]} = Message.decode(discover_request(stateless))
      assert decoded["method"] == "server/discover"
      assert decoded["params"]["_meta"][Schema.protocol_version_key()] == stateless
    end

    test "decode/1 still rejects a stateless method that declares no version" do
      without_meta = ~s({"jsonrpc":"2.0","id":1,"method":"server/discover","params":{}}\n)

      assert {:error, :method_not_found} = Message.decode(without_meta)
    end

    test "decode/1 lets an unregistered version through so the peer can answer -32022" do
      assert {:ok, [%{"method" => "server/discover"}]} = Message.decode(discover_request("1900-01-01"))
    end

    test "decode/1 keeps validating handshake-era messages against the latest legacy version" do
      initialize =
        ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"c","version":"1.0"}}}\n)

      assert {:ok, [%{"method" => "initialize"}]} = Message.decode(initialize)
      assert {:error, :method_not_found} = Message.decode(discover_request("2025-11-25"), V2025_11_25)
    end
  end
end
