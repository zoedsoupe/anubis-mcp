defmodule Anubis.Server.Component.ToolAnnotationsTest do
  use Anubis.MCP.Case, async: true

  alias Anubis.MCP.Message
  alias Anubis.Server.Session

  describe "tool annotations" do
    test "annotations callback is optional" do
      assert function_exported?(ToolWithAnnotations, :annotations, 0)
      refute function_exported?(ToolWithoutAnnotations, :annotations, 0)
      assert function_exported?(ToolWithCustomAnnotations, :annotations, 0)
    end
  end

  describe "tool output schemas" do
    test "output_schema callback is optional" do
      assert function_exported?(ToolWithOutputSchema, :output_schema, 0)
      refute function_exported?(ToolWithAnnotations, :output_schema, 0)
      refute function_exported?(ToolWithoutAnnotations, :output_schema, 0)
    end

    test "output schema is properly defined" do
      output_schema = ToolWithOutputSchema.output_schema()
      assert output_schema["type"] == "object"
      output_required = output_schema["required"]
      assert "query_time_ms" in output_required
      assert "results" in output_required
      assert "total_count" in output_required

      results_schema = output_schema["properties"]["results"]
      assert results_schema["type"] == "array"
      assert results_schema["description"] == "Search results"

      item_schema = results_schema["items"]
      assert item_schema["type"] == "object"
      assert item_schema["required"] == ["id", "title", "score"]
    end
  end

  describe "tools/list with annotations" do
    defmodule ServerWithAnnotatedTools do
      @moduledoc false
      use Anubis.Server,
        name: "Test Server with Annotations",
        version: "1.0.0",
        capabilities: [:tools]

      component(ToolWithAnnotations)
      component(ToolWithoutAnnotations)
      component(ToolWithCustomAnnotations)
      component(ToolWithOutputSchema)
      component(ToolWithInvalidOutput)
      component(ToolWithoutRequiredParams)

      @impl true
      def init(_arg, frame), do: {:ok, frame}

      @impl true
      def handle_notification(_notification, frame), do: {:noreply, frame}
    end

    setup do
      registry = Anubis.Server.Registry
      start_supervised!(registry)

      transport_name = registry.transport(ServerWithAnnotatedTools, StubTransport)
      start_supervised!({StubTransport, name: transport_name})

      task_sup = registry.task_supervisor(ServerWithAnnotatedTools)
      start_supervised!({Task.Supervisor, name: task_sup})

      session_id = "test-session"
      session_name = registry.server_session(ServerWithAnnotatedTools, session_id)

      session =
        start_supervised!(
          {Session,
           session_id: session_id,
           server_module: ServerWithAnnotatedTools,
           name: session_name,
           transport: [layer: StubTransport, name: transport_name],
           registry: registry,
           task_supervisor: task_sup}
        )

      request =
        init_request("2025-03-26", %{"name" => "TestClient", "version" => "1.0.0"})

      assert {:ok, _} = GenServer.call(session, {:mcp_request, request, %{}})
      notification = build_notification("notifications/initialized", %{})
      assert :ok = GenServer.cast(session, {:mcp_notification, notification, %{}})
      Process.sleep(30)

      %{server: session, session_id: session_id}
    end

    test "lists tools with and without annotations", %{
      server: server
    } do
      request = build_request("tools/list", %{})

      {:ok, response_string} =
        GenServer.call(server, {:mcp_request, request, %{}})

      {:ok, [response]} = Message.decode(response_string)

      assert response["result"]
      tools = response["result"]["tools"]

      tool_with_annotations =
        Enum.find(tools, &(&1["name"] == "tool_with_annotations"))

      assert tool_with_annotations["annotations"]["confidence"] == 0.95
      assert tool_with_annotations["annotations"]["category"] == "text-processing"

      assert tool_with_annotations["annotations"]["tags"] == [
               "nlp",
               "text",
               "analysis"
             ]

      tool_without_annotations =
        Enum.find(tools, &(&1["name"] == "tool_without_annotations"))

      refute Map.has_key?(tool_without_annotations, "annotations")

      tool_with_custom =
        Enum.find(tools, &(&1["name"] == "tool_with_custom_annotations"))

      assert tool_with_custom["annotations"]["version"] == "2.0"
      assert tool_with_custom["annotations"]["experimental"]
      assert tool_with_custom["annotations"]["capabilities"]["batch"]
      refute tool_with_custom["annotations"]["capabilities"]["streaming"]
    end

    test "lists tools with output schemas", %{
      server: server
    } do
      request = build_request("tools/list", %{})

      {:ok, response_string} =
        GenServer.call(server, {:mcp_request, request, %{}})

      {:ok, [response]} = Message.decode(response_string)

      assert response["result"]
      tools = response["result"]["tools"]

      tool_with_output =
        Enum.find(tools, &(&1["name"] == "tool_with_output_schema"))

      assert tool_with_output["outputSchema"]
      assert tool_with_output["outputSchema"]["type"] == "object"

      output_required = tool_with_output["outputSchema"]["required"]
      assert "query_time_ms" in output_required
      assert "results" in output_required
      assert "total_count" in output_required

      tool_without_output =
        Enum.find(tools, &(&1["name"] == "tool_without_annotations"))

      refute Map.has_key?(tool_without_output, "outputSchema")
    end
  end

  describe "tools/call with output schema validation" do
    defmodule ServerWithOutputSchemaTools do
      @moduledoc false
      use Anubis.Server,
        name: "Test Server with Output Schema Tools",
        version: "1.0.0",
        capabilities: [:tools]

      component(ToolWithOutputSchema)
      component(ToolWithInvalidOutput)
      component(ToolWithoutAnnotations)
      component(ToolWithoutRequiredParams)

      @impl true
      def init(_arg, frame), do: {:ok, frame}

      @impl true
      def handle_notification(_notification, frame), do: {:noreply, frame}
    end

    setup do
      registry = Anubis.Server.Registry
      start_supervised!(registry)

      transport_name = registry.transport(ServerWithOutputSchemaTools, StubTransport)
      start_supervised!({StubTransport, name: transport_name})

      task_sup = registry.task_supervisor(ServerWithOutputSchemaTools)
      start_supervised!({Task.Supervisor, name: task_sup})

      session_id = "test-session-output"
      session_name = registry.server_session(ServerWithOutputSchemaTools, session_id)

      session =
        start_supervised!(
          {Session,
           session_id: session_id,
           server_module: ServerWithOutputSchemaTools,
           name: session_name,
           transport: [layer: StubTransport, name: transport_name],
           registry: registry,
           task_supervisor: task_sup},
          id: :output_session
        )

      request =
        init_request("2025-03-26", %{"name" => "TestClient", "version" => "1.0.0"})

      assert {:ok, _} = GenServer.call(session, {:mcp_request, request, %{}})
      notification = build_notification("notifications/initialized", %{})
      assert :ok = GenServer.cast(session, {:mcp_notification, notification, %{}})
      Process.sleep(30)

      %{server: session, session_id: session_id}
    end

    test "tool with valid output schema returns structured content", %{
      server: server
    } do
      request =
        build_request("tools/call", %{
          "name" => "tool_with_output_schema",
          "arguments" => %{"query" => "test search", "limit" => 5}
        })

      {:ok, response_string} =
        GenServer.call(server, {:mcp_request, request, %{}})

      {:ok, [response]} = Message.decode(response_string)

      assert response["result"]
      result = response["result"]

      # Check structured content
      assert result["structuredContent"]
      structured = result["structuredContent"]
      assert structured["total_count"] == 2
      assert structured["query_time_ms"] == 12.5
      assert length(structured["results"]) == 2
      assert hd(structured["results"])["title"] == "Result for test search"

      # Check backward compatibility - content includes JSON
      assert result["content"]
      text_content = Enum.find(result["content"], &(&1["type"] == "text"))
      assert text_content
      decoded = JSON.decode!(text_content["text"])
      assert decoded == structured

      assert result["isError"] == false
    end

    test "tool error response skips output schema validation", %{
      server: server
    } do
      request =
        build_request("tools/call", %{
          "name" => "tool_with_output_schema",
          "arguments" => %{"query" => "tool error"}
        })

      {:ok, response_string} =
        GenServer.call(server, {:mcp_request, request, %{}})

      assert {:ok, [%{"result" => %{"isError" => true}}]} = Message.decode(response_string)
    end

    test "tool without output schema works normally", %{
      server: server
    } do
      request =
        build_request("tools/call", %{
          "name" => "tool_without_annotations",
          "arguments" => %{"input" => "test"}
        })

      {:ok, response_string} =
        GenServer.call(server, {:mcp_request, request, %{}})

      {:ok, [response]} = Message.decode(response_string)

      assert response["result"]
      result = response["result"]

      # No structured content for tools without output schema
      refute Map.has_key?(result, "structuredContent")

      # Regular content is present
      assert result["content"]
      text_content = Enum.find(result["content"], &(&1["type"] == "text"))
      assert text_content["text"] == "Result: test"
      assert result["isError"] == false
    end

    test "tool with invalid output fails validation", %{
      server: server
    } do
      request =
        build_request("tools/call", %{
          "name" => "tool_with_invalid_output",
          "arguments" => %{"input" => "test"}
        })

      {:ok, response_string} =
        GenServer.call(server, {:mcp_request, request, %{}})

      {:ok, [response]} = Message.decode(response_string)

      assert response["error"]
      error = response["error"]
      assert error["code"] == -32_000
      assert error["message"] == "Tool doesnt conform for it output schema"
      assert error["data"]["errors"]
    end

    test "tool call with missing arguments parameter should not crash server", %{
      server: server
    } do
      request =
        build_request("tools/call", %{
          "name" => "tool_without_annotations"
        })

      {:ok, response_string} =
        GenServer.call(server, {:mcp_request, request, %{}})

      {:ok, [response]} = Message.decode(response_string)

      # Should return proper validation error, not crash
      assert response["error"]
      error = response["error"]
      assert error["code"] == -32_602
      assert error["message"] == "Invalid params"
      assert error["data"]["message"] =~ "input: is required"
    end

    test "tool call with missing arguments parameter works for tools without required params", %{
      server: server
    } do
      request =
        build_request("tools/call", %{
          "name" => "tool_without_required_params"
        })

      {:ok, response_string} =
        GenServer.call(server, {:mcp_request, request, %{}})

      {:ok, [response]} = Message.decode(response_string)

      # Should succeed with default behavior
      assert response["result"]
      result = response["result"]
      assert result["content"]
      text_content = Enum.find(result["content"], &(&1["type"] == "text"))
      assert text_content["text"] == "Tool executed: default message"
      assert result["isError"] == false
    end
  end
end
