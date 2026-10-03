defmodule Anubis.Server.Component.IconsTest do
  use Anubis.MCP.Case, async: true

  alias Anubis.MCP.Message
  alias Anubis.Server.Component
  alias Anubis.Server.Component.Prompt
  alias Anubis.Server.Component.Resource
  alias Anubis.Server.Component.Tool
  alias Anubis.Server.Registry
  alias Anubis.Server.Session

  @moduletag capture_log: true

  @tool_icons [
    %{src: "https://example.com/tool-48.png", mimeType: "image/png", sizes: ["48x48"]},
    %{src: "data:image/svg+xml;base64,PHN2Zz48L3N2Zz4=", sizes: ["any"]}
  ]

  defmodule ToolWithIcons do
    @moduledoc "A tool with icons"

    use Component,
      type: :tool,
      icons: [
        %{src: "https://example.com/tool-48.png", mimeType: "image/png", sizes: ["48x48"]},
        %{src: "data:image/svg+xml;base64,PHN2Zz48L3N2Zz4=", sizes: ["any"]}
      ]

    alias Anubis.Server.Response

    schema do
      field(:input, {:required, :string}, description: "Input value")
    end

    @impl true
    def execute(%{input: input}, frame) do
      {:reply, Response.text(Response.tool(), "ok: #{input}"), frame}
    end
  end

  defmodule ResourceWithIcons do
    @moduledoc "A resource with icons"

    use Component,
      type: :resource,
      uri: "file:///icons/readme.md",
      icons: [
        %{src: "https://example.com/resource.png", mimeType: "image/png", sizes: ["32x32", "64x64"]}
      ]

    alias Anubis.Server.Response

    @impl true
    def read(_params, frame) do
      {:reply, Response.text(Response.resource(), "content"), frame}
    end
  end

  defmodule ResourceTemplateWithIcons do
    @moduledoc "A resource template with icons"

    use Component,
      type: :resource,
      uri_template: "file:///icons/{path}",
      icons: [%{src: "https://example.com/template.png"}]

    alias Anubis.Server.Response

    @impl true
    def read(_params, frame) do
      {:reply, Response.text(Response.resource(), "content"), frame}
    end
  end

  defmodule PromptWithIcons do
    @moduledoc "A prompt with icons"

    use Component,
      type: :prompt,
      icons: [%{src: "https://example.com/prompt.png", sizes: ["any"]}]

    alias Anubis.Server.Response

    schema do
      field(:topic, {:required, :string}, description: "Prompt topic")
    end

    @impl true
    def get_messages(_params, frame) do
      {:reply, Response.user_message(Response.prompt(), "hello"), frame}
    end
  end

  defmodule ToolWithInvalidIcons do
    @moduledoc "A tool with malformed icons"

    use Component,
      type: :tool,
      icons: [%{mimeType: "image/png"}]

    alias Anubis.Server.Response

    schema do
      field(:input, {:required, :string}, description: "Input value")
    end

    @impl true
    def execute(%{input: input}, frame) do
      {:reply, Response.text(Response.tool(), "ok: #{input}"), frame}
    end
  end

  describe "icons DSL option" do
    setup do
      Code.ensure_loaded!(ToolWithIcons)
      Code.ensure_loaded!(ResourceWithIcons)
      Code.ensure_loaded!(ResourceTemplateWithIcons)
      Code.ensure_loaded!(PromptWithIcons)
      Code.ensure_loaded!(ToolWithoutAnnotations)
      :ok
    end

    test "icons callback is optional" do
      assert function_exported?(ToolWithIcons, :icons, 0)
      assert function_exported?(ResourceWithIcons, :icons, 0)
      assert function_exported?(ResourceTemplateWithIcons, :icons, 0)
      assert function_exported?(PromptWithIcons, :icons, 0)
      refute function_exported?(ToolWithoutAnnotations, :icons, 0)
    end

    test "icons returns the configured value" do
      assert ToolWithIcons.icons() == [
               %{src: "https://example.com/tool-48.png", mimeType: "image/png", sizes: ["48x48"]},
               %{src: "data:image/svg+xml;base64,PHN2Zz48L3N2Zz4=", sizes: ["any"]}
             ]

      assert ResourceWithIcons.icons() == [
               %{src: "https://example.com/resource.png", mimeType: "image/png", sizes: ["32x32", "64x64"]}
             ]

      assert ResourceTemplateWithIcons.icons() == [%{src: "https://example.com/template.png"}]
      assert PromptWithIcons.icons() == [%{src: "https://example.com/prompt.png", sizes: ["any"]}]
    end
  end

  describe "icons validation" do
    alias Anubis.Server.Component.Icons

    test "accepts well-formed icons" do
      assert {:ok, [%{src: "https://example.com/icon.png"}]} =
               Icons.icons([%{src: "https://example.com/icon.png"}])

      assert {:ok, [%{src: _, mimeType: "image/png", sizes: ["48x48", "any"]}]} =
               Icons.icons([
                 %{src: "https://example.com/icon.png", mimeType: "image/png", sizes: ["48x48", "any"]}
               ])

      assert {:ok, [%{src: "data:image/svg+xml;base64,PHN2Zz48L3N2Zz4="}]} =
               Icons.icons([%{src: "data:image/svg+xml;base64,PHN2Zz48L3N2Zz4="}])
    end

    test "rejects icons that are not a list of maps" do
      assert {:error, _} = Icons.icons("https://example.com/icon.png")
    end

    test "rejects an icon without :src" do
      assert {:error, _} = Icons.icons([%{mimeType: "image/png"}])
    end

    test "rejects an icon with a non-string :src" do
      assert {:error, _} = Icons.icons([%{src: 42}])
    end

    test "rejects an icon whose :src is not a URI" do
      assert {:error, _} = Icons.icons([%{src: "example.com/icon.png"}])
    end

    test "keeps the optional theme and validates its value" do
      assert {:ok, [%{src: _, theme: "dark"}]} =
               Icons.icons([%{src: "https://example.com/icon.png", theme: "dark"}])

      assert {:ok, [%{src: _, theme: "light"}]} =
               Icons.icons([%{src: "https://example.com/icon.png", theme: "light"}])

      assert {:error, _} = Icons.icons([%{src: "https://example.com/icon.png", theme: "blue"}])
    end

    test "rejects an icon with a non-string :mimeType" do
      assert {:error, _} = Icons.icons([%{src: "https://example.com/icon.png", mimeType: :png}])
    end

    test "rejects malformed :sizes entries" do
      assert {:error, _} = Icons.icons([%{src: "https://example.com/icon.png", sizes: "48x48"}])
      assert {:error, _} = Icons.icons([%{src: "https://example.com/icon.png", sizes: [48]}])
      assert {:error, _} = Icons.icons([%{src: "https://example.com/icon.png", sizes: ["large"]}])
    end

    test "parse_components rejects a component with malformed icons" do
      assert_raise ArgumentError, ~r/invalid icons for .*ToolWithInvalidIcons/, fn ->
        Anubis.Server.parse_components([{ToolWithInvalidIcons, []}])
      end
    end
  end

  describe "icons JSON encoding" do
    test "tool with icons includes icons in JSON output" do
      tool = %Tool{
        name: "test_tool",
        description: "A test tool",
        input_schema: %{"type" => "object", "properties" => %{}},
        icons: @tool_icons
      }

      decoded = tool |> JSON.encode!() |> JSON.decode!()

      assert decoded["icons"] == [
               %{
                 "src" => "https://example.com/tool-48.png",
                 "mimeType" => "image/png",
                 "sizes" => ["48x48"]
               },
               %{"src" => "data:image/svg+xml;base64,PHN2Zz48L3N2Zz4=", "sizes" => ["any"]}
             ]
    end

    test "tool without icons does not include icons in JSON output" do
      tool = %Tool{
        name: "test_tool",
        description: "A test tool",
        input_schema: %{"type" => "object", "properties" => %{}}
      }

      decoded = tool |> JSON.encode!() |> JSON.decode!()

      refute Map.has_key?(decoded, "icons")
    end

    test "resource with icons includes icons in JSON output" do
      resource = %Resource{
        uri: "file:///readme.md",
        name: "readme",
        mime_type: "text/markdown",
        icons: [%{src: "https://example.com/resource.png", mimeType: "image/png", sizes: ["32x32"]}]
      }

      decoded = resource |> JSON.encode!() |> JSON.decode!()

      assert decoded["icons"] == [
               %{
                 "src" => "https://example.com/resource.png",
                 "mimeType" => "image/png",
                 "sizes" => ["32x32"]
               }
             ]
    end

    test "resource without icons does not include icons in JSON output" do
      resource = %Resource{uri: "file:///readme.md", name: "readme", mime_type: "text/markdown"}

      decoded = resource |> JSON.encode!() |> JSON.decode!()

      refute Map.has_key?(decoded, "icons")
    end

    test "resource template with icons includes icons in JSON output" do
      template = %Resource{
        uri_template: "file:///{path}",
        name: "template",
        mime_type: "text/plain",
        icons: [%{src: "https://example.com/template.png"}]
      }

      decoded = template |> JSON.encode!() |> JSON.decode!()

      assert decoded["uriTemplate"] == "file:///{path}"
      assert decoded["icons"] == [%{"src" => "https://example.com/template.png"}]
    end

    test "resource template without icons does not include icons in JSON output" do
      template = %Resource{uri_template: "file:///{path}", name: "template", mime_type: "text/plain"}

      decoded = template |> JSON.encode!() |> JSON.decode!()

      refute Map.has_key?(decoded, "icons")
    end

    test "prompt with icons includes icons in JSON output" do
      prompt = %Prompt{
        name: "test_prompt",
        description: "A test prompt",
        icons: [%{src: "https://example.com/prompt.png", sizes: ["any"]}]
      }

      decoded = prompt |> JSON.encode!() |> JSON.decode!()

      assert decoded["icons"] == [%{"src" => "https://example.com/prompt.png", "sizes" => ["any"]}]
    end

    test "prompt without icons does not include icons in JSON output" do
      prompt = %Prompt{name: "test_prompt", description: "A test prompt"}

      decoded = prompt |> JSON.encode!() |> JSON.decode!()

      refute Map.has_key?(decoded, "icons")
    end
  end

  describe "list responses with icons" do
    defmodule ServerWithIconComponents do
      @moduledoc false
      use Anubis.Server,
        name: "Test Server with Icons",
        version: "1.0.0",
        capabilities: [:tools, :resources, :prompts]

      component(ToolWithIcons)
      component(ToolWithoutAnnotations)
      component(ResourceWithIcons)
      component(ResourceTemplateWithIcons)
      component(PromptWithIcons)

      @impl true
      def init(_arg, frame), do: {:ok, frame}

      @impl true
      def handle_notification(_notification, frame), do: {:noreply, frame}
    end

    setup do
      transport_name = Registry.transport_name(ServerWithIconComponents, StubTransport)
      start_supervised!({StubTransport, name: transport_name})

      task_sup = Registry.task_supervisor_name(ServerWithIconComponents)
      start_supervised!({Task.Supervisor, name: task_sup})

      session_id = "test-session-icons"
      session_name = Registry.session_name(ServerWithIconComponents, session_id)

      session =
        start_supervised!(
          {Session,
           session_id: session_id,
           server_module: ServerWithIconComponents,
           name: session_name,
           transport: [layer: StubTransport, name: transport_name],
           task_supervisor: task_sup}
        )

      request =
        init_request("2025-03-26", %{"name" => "TestClient", "version" => "1.0.0"})

      assert {:ok, _} = GenServer.call(session, {:mcp_request, request, %{}})
      notification = build_notification("notifications/initialized", %{})
      assert :ok = GenServer.cast(session, {:mcp_notification, notification, %{}})
      Process.sleep(30)

      %{server: session}
    end

    test "tools/list includes icons when defined", %{server: server} do
      request = build_request("tools/list", %{})

      {:ok, response_string} =
        GenServer.call(server, {:mcp_request, request, %{}})

      {:ok, [response]} = Message.decode(response_string)

      tools = response["result"]["tools"]

      tool_with_icons = Enum.find(tools, &(&1["name"] == "tool_with_icons"))

      assert tool_with_icons["icons"] == [
               %{
                 "src" => "https://example.com/tool-48.png",
                 "mimeType" => "image/png",
                 "sizes" => ["48x48"]
               },
               %{"src" => "data:image/svg+xml;base64,PHN2Zz48L3N2Zz4=", "sizes" => ["any"]}
             ]

      tool_without_icons = Enum.find(tools, &(&1["name"] == "tool_without_annotations"))

      refute Map.has_key?(tool_without_icons, "icons")
    end

    test "resources/list includes icons when defined", %{server: server} do
      request = build_request("resources/list", %{})

      {:ok, response_string} =
        GenServer.call(server, {:mcp_request, request, %{}})

      {:ok, [response]} = Message.decode(response_string)

      resources = response["result"]["resources"]

      resource_with_icons = Enum.find(resources, &(&1["name"] == "readme.md"))

      assert resource_with_icons["icons"] == [
               %{
                 "src" => "https://example.com/resource.png",
                 "mimeType" => "image/png",
                 "sizes" => ["32x32", "64x64"]
               }
             ]
    end

    test "resources/templates/list includes icons when defined", %{server: server} do
      request = build_request("resources/templates/list", %{})

      {:ok, response_string} =
        GenServer.call(server, {:mcp_request, request, %{}})

      {:ok, [response]} = Message.decode(response_string)

      templates = response["result"]["resourceTemplates"]

      template_with_icons =
        Enum.find(templates, &(&1["name"] == "resource_template_with_icons"))

      assert template_with_icons["icons"] == [
               %{"src" => "https://example.com/template.png"}
             ]
    end

    test "prompts/list includes icons when defined", %{server: server} do
      request = build_request("prompts/list", %{})

      {:ok, response_string} =
        GenServer.call(server, {:mcp_request, request, %{}})

      {:ok, [response]} = Message.decode(response_string)

      prompts = response["result"]["prompts"]

      prompt_with_icons = Enum.find(prompts, &(&1["name"] == "prompt_with_icons"))

      assert prompt_with_icons["icons"] == [
               %{"src" => "https://example.com/prompt.png", "sizes" => ["any"]}
             ]
    end
  end
end
