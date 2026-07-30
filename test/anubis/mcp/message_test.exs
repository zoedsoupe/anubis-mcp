defmodule Anubis.MCP.MessageTest do
  use ExUnit.Case, async: true

  alias Anubis.MCP.Message
  alias Anubis.Protocol.V2025_03_26
  alias Anubis.Protocol.V2025_06_18
  alias Anubis.Protocol.V2025_11_25

  require Message

  @moduletag capture_log: true

  describe "version-aware dispatch" do
    @elicitation_request ~s({"jsonrpc":"2.0","id":1,"method":"elicitation/create","params":{"message":"name?","requestedSchema":{"type":"object","properties":{"name":{"type":"string"}}}}}\n)

    test "decode/2 rejects methods the negotiated version does not model" do
      assert {:error, :method_not_found} = Message.decode(@elicitation_request, V2025_03_26)
      assert {:ok, [%{"method" => "elicitation/create"}]} = Message.decode(@elicitation_request, V2025_06_18)
    end

    test "decode/1 defaults to the latest version" do
      assert {:ok, [%{"method" => "elicitation/create"}]} = Message.decode(@elicitation_request)

      tasks_request = ~s({"jsonrpc":"2.0","id":1,"method":"tasks/get","params":{"taskId":"t-1"}}\n)
      assert {:ok, [%{"method" => "tasks/get"}]} = Message.decode(tasks_request)
    end

    test "decode/2 rejects tasks methods before 2025-11-25" do
      tasks_request = ~s({"jsonrpc":"2.0","id":1,"method":"tasks/get","params":{"taskId":"t-1"}}\n)

      assert {:error, :method_not_found} = Message.decode(tasks_request, V2025_06_18)
      assert {:ok, _} = Message.decode(tasks_request, V2025_11_25)
    end

    test "validate_message/2 rejects unknown notification methods for the version" do
      notification = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/tasks/status",
        "params" => %{
          "taskId" => "t-1",
          "status" => "working",
          "createdAt" => "2026-07-29T00:00:00Z",
          "lastUpdatedAt" => "2026-07-29T00:00:00Z"
        }
      }

      assert {:error, :method_not_found} = Message.validate_message(notification, V2025_06_18)
      assert {:ok, _} = Message.validate_message(notification, V2025_11_25)
    end

    test "validate_message/2 filters params to the negotiated version" do
      progress = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/progress",
        "params" => %{"progressToken" => "t", "progress" => 1, "message" => "working"}
      }

      assert {:ok, validated} = Message.validate_message(progress, V2025_03_26)
      assert validated["params"]["message"] == "working"
    end

    test "request_schema/1 and notification_schema/1 reflect the version" do
      assert {:multi, :method, branches} = Message.request_schema(V2025_11_25)
      assert Map.has_key?(branches, "tasks/get")

      assert {:multi, :method, branches} = Message.request_schema(V2025_03_26)
      refute Map.has_key?(branches, "elicitation/create")

      assert {:multi, :method, branches} = Message.notification_schema(V2025_11_25)
      assert Map.has_key?(branches, "notifications/tasks/status")
    end

    test "encode_request/3 with an older version schema rejects newer methods" do
      request = %{"method" => "tasks/get", "params" => %{"taskId" => "t-1"}}

      assert {:error, _} = Message.encode_request(request, 1, Message.request_schema(V2025_06_18))
      assert {:ok, _} = Message.encode_request(request, 1, Message.request_schema(V2025_11_25))
      assert {:ok, _} = Message.encode_request(request, 1)
    end

    test "encode_notification/2 with an older version schema rejects newer notifications" do
      notification = %{
        "method" => "notifications/tasks/status",
        "params" => %{
          "taskId" => "t-1",
          "status" => "working",
          "createdAt" => "2026-07-29T00:00:00Z",
          "lastUpdatedAt" => "2026-07-29T00:00:00Z"
        }
      }

      assert {:error, _} = Message.encode_notification(notification, Message.notification_schema(V2025_06_18))
      assert {:ok, _} = Message.encode_notification(notification)
    end

    test "encode_sampling_response/3 validates result content per version" do
      response = %{
        "result" => %{
          "role" => "assistant",
          "content" => %{"type" => "audio", "data" => "AA==", "mimeType" => "audio/mp3"},
          "model" => "test-model"
        }
      }

      assert {:ok, _} = Message.encode_sampling_response(response, 1, V2025_03_26)
      assert {:ok, _} = Message.encode_sampling_response(response, 1)
    end

    test "get_schema/1 remains available for legacy schema names" do
      assert {:multi, :method, _} = Message.get_schema(:request_schema)
      assert {:multi, :method, _} = Message.get_schema(:notification_schema)
      assert {:oneof, _} = Message.get_schema(:mcp_message_schema)
      assert is_map(Message.get_schema(:response_schema))
      assert is_map(Message.get_schema(:error_schema))
      assert is_map(Message.get_schema(:sampling_result_schema))
      assert is_map(Message.get_schema(:elicitation_result_schema))
      assert is_map(Message.get_schema(:sampling_response_schema))
      assert is_map(Message.get_schema(:elicitation_response_schema))
    end
  end

  describe "decode/1" do
    test "decodes a single valid message" do
      json = ~s({"jsonrpc":"2.0","method":"ping","id":1}\n)

      assert {:ok, [decoded]} = Message.decode(json)
      assert decoded["jsonrpc"] == "2.0"
      assert decoded["method"] == "ping"
      assert decoded["id"] == 1
    end

    test "decodes multiple messages" do
      json =
        ~s({"jsonrpc":"2.0","method":"ping","id":1}\n{"jsonrpc":"2.0","method":"notifications/initialized"}\n)

      assert {:ok, [msg1, msg2]} = Message.decode(json)
      assert msg1["method"] == "ping"
      assert msg2["method"] == "notifications/initialized"
    end

    test "returns error for invalid JSON" do
      json = ~s({"jsonrpc":"2.0","method":broken}\n)

      assert {:error, :parse_error} = Message.decode(json)
    end

    test "returns error for non-compliant message" do
      json = ~s({"method":"unknown_method","id":1}\n)

      assert {:error, :invalid_request} = Message.decode(json)
    end

    test "returns invalid_request for JSON-RPC batch arrays" do
      json = ~s([{"jsonrpc":"2.0","id":1,"method":"tools/list"}]\n)

      assert {:error, :invalid_request} = Message.decode(json)
    end

    test "returns method_not_found for unknown MCP methods" do
      json = ~s({"jsonrpc":"2.0","id":1,"method":"unknown/method","params":{}}\n)

      assert {:error, :method_not_found} = Message.decode(json)
    end

    test "returns method_not_found for unknown MCP notification methods" do
      json = ~s({"jsonrpc":"2.0","method":"notifications/unknown"}\n)

      assert {:error, :method_not_found} = Message.decode(json)
    end
  end

  describe "validate_message/1" do
    test "validates initialize request" do
      msg = %{
        "jsonrpc" => "2.0",
        "method" => "initialize",
        "id" => 1,
        "params" => %{
          "protocolVersion" => "2024-05-01",
          "capabilities" => %{"foo" => "bar"},
          "clientInfo" => %{
            "name" => "TestClient",
            "version" => "1.0.0"
          }
        }
      }

      assert {:ok, _} = Message.validate_message(msg)
    end

    test "preserves _meta on initialize params and clientInfo" do
      msg = %{
        "jsonrpc" => "2.0",
        "method" => "initialize",
        "id" => 1,
        "params" => %{
          "protocolVersion" => "2024-05-01",
          "capabilities" => %{},
          "_meta" => %{"appId" => "acme", "mode" => "batch"},
          "clientInfo" => %{
            "name" => "TestClient",
            "version" => "1.0.0",
            "_meta" => %{"tenant" => "t-1"}
          }
        }
      }

      assert {:ok, validated} = Message.validate_message(msg)
      assert validated["params"]["_meta"] == %{"appId" => "acme", "mode" => "batch"}
      assert validated["params"]["clientInfo"]["_meta"] == %{"tenant" => "t-1"}
    end

    test "validates ping request" do
      msg = %{
        "jsonrpc" => "2.0",
        "method" => "ping",
        "id" => 1
      }

      assert {:ok, _} = Message.validate_message(msg)
    end

    test "validates resources/list request" do
      msg = %{
        "jsonrpc" => "2.0",
        "method" => "resources/list",
        "id" => 1,
        "params" => %{
          "cursor" => "next-page"
        }
      }

      assert {:ok, _} = Message.validate_message(msg)
    end

    test "validates resources/read request" do
      msg = %{
        "jsonrpc" => "2.0",
        "method" => "resources/read",
        "id" => 1,
        "params" => %{
          "uri" => "file:///path/to/file.txt"
        }
      }

      assert {:ok, _} = Message.validate_message(msg)
    end

    test "validates notification message" do
      msg = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/initialized"
      }

      assert {:ok, _} = Message.validate_message(msg)
    end

    test "validates resources/subscribe request" do
      msg = %{
        "jsonrpc" => "2.0",
        "method" => "resources/subscribe",
        "id" => 1,
        "params" => %{"uri" => "file:///watched"}
      }

      assert {:ok, _} = Message.validate_message(msg)
    end

    test "validates resources/unsubscribe request" do
      msg = %{
        "jsonrpc" => "2.0",
        "method" => "resources/unsubscribe",
        "id" => 1,
        "params" => %{"uri" => "file:///watched"}
      }

      assert {:ok, _} = Message.validate_message(msg)
    end

    test "rejects resources/subscribe request missing uri" do
      msg = %{
        "jsonrpc" => "2.0",
        "method" => "resources/subscribe",
        "id" => 1,
        "params" => %{}
      }

      assert {:error, _} = Message.validate_message(msg)
    end

    test "validates notifications/resources/updated notification" do
      msg = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/resources/updated",
        "params" => %{"uri" => "file:///x"}
      }

      assert {:ok, _} = Message.validate_message(msg)
    end

    test "rejects notifications/resources/updated notification missing uri" do
      msg = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/resources/updated",
        "params" => %{}
      }

      assert {:error, _} = Message.validate_message(msg)
    end

    test "validates notifications/resources/list_changed notification" do
      msg = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/resources/list_changed"
      }

      assert {:ok, _} = Message.validate_message(msg)
    end

    test "validates notifications/prompts/list_changed notification" do
      msg = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/prompts/list_changed"
      }

      assert {:ok, _} = Message.validate_message(msg)
    end

    test "validates cancelled notification" do
      msg = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/cancelled",
        "params" => %{
          "requestId" => 123,
          "reason" => "User cancelled"
        }
      }

      assert {:ok, _} = Message.validate_message(msg)
    end

    test "validates response message" do
      msg = %{
        "jsonrpc" => "2.0",
        "result" => %{"status" => "success"},
        "id" => 1
      }

      assert {:ok, _} = Message.validate_message(msg)
    end

    test "validates pong response message" do
      msg = %{
        "jsonrpc" => "2.0",
        "result" => %{},
        "id" => 1
      }

      assert {:ok, _} = Message.validate_message(msg)
    end

    test "validates error message" do
      msg = %{
        "jsonrpc" => "2.0",
        "error" => %{
          "code" => -32_600,
          "message" => "Invalid Request"
        },
        "id" => 1
      }

      assert {:ok, _} = Message.validate_message(msg)
    end

    test "rejects message with invalid method" do
      msg = %{
        "jsonrpc" => "2.0",
        "method" => "unknown_method",
        "id" => 1
      }

      assert {:error, :method_not_found} = Message.validate_message(msg)
    end

    test "rejects message with missing required fields" do
      # Missing protocolVersion in initialize params
      msg = %{
        "jsonrpc" => "2.0",
        "method" => "initialize",
        "id" => 1,
        "params" => %{
          "clientInfo" => %{
            "name" => "TestClient",
            "version" => "1.0.0"
          }
        }
      }

      assert {:error, :invalid_request} = Message.validate_message(msg)
    end
  end

  describe "encode_request/2" do
    test "encodes initialize request" do
      req = %{
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2024-05-01",
          "capabilities" => %{"foo" => "bar"},
          "clientInfo" => %{
            "name" => "TestClient",
            "version" => "1.0.0"
          }
        }
      }

      assert {:ok, encoded} = Message.encode_request(req, 1)
      assert is_binary(encoded)
      assert String.ends_with?(encoded, "\n")

      # Decode to validate
      {:ok, [decoded]} = Message.decode(encoded)
      assert decoded["id"] == 1
      assert decoded["method"] == "initialize"
    end

    test "keeps _meta on initialize through wire encode" do
      req = %{
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2024-05-01",
          "capabilities" => %{},
          "_meta" => %{"appId" => "acme"},
          "clientInfo" => %{
            "name" => "TestClient",
            "version" => "1.0.0",
            "_meta" => %{"tenant" => "t-1"}
          }
        }
      }

      assert {:ok, encoded} = Message.encode_request(req, 1)
      {:ok, [decoded]} = Message.decode(encoded)
      assert decoded["params"]["_meta"] == %{"appId" => "acme"}
      assert decoded["params"]["clientInfo"]["_meta"] == %{"tenant" => "t-1"}
    end

    test "encodes ping request" do
      req = %{"method" => "ping"}

      assert {:ok, encoded} = Message.encode_request(req, "req-123")
      assert is_binary(encoded)

      # Decode to validate
      {:ok, [decoded]} = Message.decode(encoded)
      assert decoded["id"] == "req-123"
      assert decoded["method"] == "ping"
    end

    test "returns error for invalid request" do
      req = %{"method" => "unknown_method"}

      assert {:error, _} = Message.encode_request(req, 1)
    end
  end

  describe "encode_notification/1" do
    test "encodes initialize notification" do
      notif = %{"method" => "notifications/initialized"}

      assert {:ok, encoded} = Message.encode_notification(notif)
      assert is_binary(encoded)
      assert String.ends_with?(encoded, "\n")

      # Decode to validate
      {:ok, [decoded]} = Message.decode(encoded)
      assert decoded["method"] == "notifications/initialized"
      refute Map.has_key?(decoded, "id")
    end

    test "encodes cancelled notification" do
      notif = %{
        "method" => "notifications/cancelled",
        "params" => %{
          "requestId" => 123,
          "reason" => "User cancelled"
        }
      }

      assert {:ok, encoded} = Message.encode_notification(notif)
      assert is_binary(encoded)

      # Decode to validate
      {:ok, [decoded]} = Message.decode(encoded)
      assert decoded["method"] == "notifications/cancelled"
      assert decoded["params"]["requestId"] == 123
    end

    test "returns error for invalid notification" do
      notif = %{"method" => "unknown_method"}

      assert {:error, _} = Message.encode_notification(notif)
    end
  end

  describe "guards" do
    test "is_request/1 correctly identifies request messages" do
      request = %{"jsonrpc" => "2.0", "method" => "ping", "id" => 1}
      not_request = %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}

      assert Message.is_request(request)
      refute Message.is_request(not_request)
    end

    test "is_notification/1 correctly identifies notification messages" do
      notification = %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
      not_notification = %{"jsonrpc" => "2.0", "method" => "ping", "id" => 1}

      assert Message.is_notification(notification)
      refute Message.is_notification(not_notification)
    end

    test "is_response/1 correctly identifies response messages" do
      response = %{"jsonrpc" => "2.0", "result" => %{}, "id" => 1}
      not_response = %{"jsonrpc" => "2.0", "method" => "ping", "id" => 1}

      assert Message.is_response(response)
      refute Message.is_response(not_response)
    end

    test "is_error/1 correctly identifies error messages" do
      error = %{
        "jsonrpc" => "2.0",
        "error" => %{"code" => -32_600, "message" => "Invalid Request"},
        "id" => 1
      }

      not_error = %{"jsonrpc" => "2.0", "result" => %{}, "id" => 1}

      assert Message.is_error(error)
      refute Message.is_error(not_error)
    end
  end

  describe "encode_progress_notification/3" do
    test "encodes a progress notification with a total" do
      {:ok, encoded} =
        Message.encode_progress_notification(%{
          "progressToken" => "abc123",
          "progress" => 50,
          "total" => 100
        })

      decoded = Jason.decode!(encoded)

      assert decoded["jsonrpc"] == "2.0"
      assert decoded["method"] == "notifications/progress"
      assert decoded["params"]["progressToken"] == "abc123"
      assert decoded["params"]["progress"] == 50
      assert decoded["params"]["total"] == 100
    end

    test "encodes a progress notification without a total" do
      {:ok, encoded} =
        Message.encode_progress_notification(%{
          "progressToken" => "abc123",
          "progress" => 50
        })

      decoded = Jason.decode!(encoded)

      assert decoded["jsonrpc"] == "2.0"
      assert decoded["method"] == "notifications/progress"
      assert decoded["params"]["progressToken"] == "abc123"
      assert decoded["params"]["progress"] == 50
      refute Map.has_key?(decoded["params"], "total")
    end
  end

  describe "encode_log_message/3" do
    test "encodes a log message with a logger name" do
      {:ok, encoded} =
        Message.encode_log_message("info", "Test log message", "test-logger")

      decoded = Jason.decode!(encoded)

      assert decoded["jsonrpc"] == "2.0"
      assert decoded["method"] == "notifications/message"
      assert decoded["params"]["level"] == "info"
      assert decoded["params"]["data"] == "Test log message"
      assert decoded["params"]["logger"] == "test-logger"
    end

    test "encodes a log message without a logger name" do
      {:ok, encoded} =
        Message.encode_log_message("error", %{error: "Something went wrong"})

      decoded = Jason.decode!(encoded)

      assert decoded["jsonrpc"] == "2.0"
      assert decoded["method"] == "notifications/message"
      assert decoded["params"]["level"] == "error"
      assert decoded["params"]["data"]["error"] == "Something went wrong"
      refute Map.has_key?(decoded["params"], "logger")
    end

    test "validates log level" do
      assert {:ok, _} = Message.encode_log_message("debug", "Debug message")
      assert {:ok, _} = Message.encode_log_message("info", "Info message")
      assert {:ok, _} = Message.encode_log_message("notice", "Notice message")
      assert {:ok, _} = Message.encode_log_message("warning", "Warning message")
      assert {:ok, _} = Message.encode_log_message("error", "Error message")
      assert {:ok, _} = Message.encode_log_message("critical", "Critical message")
      assert {:ok, _} = Message.encode_log_message("alert", "Alert message")
      assert {:ok, _} = Message.encode_log_message("emergency", "Emergency message")

      assert_raise FunctionClauseError, fn ->
        Message.encode_log_message("invalid", "Invalid message")
      end
    end
  end
end
