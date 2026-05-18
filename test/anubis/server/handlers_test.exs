defmodule Anubis.Server.HandlersTest do
  use ExUnit.Case, async: true

  alias Anubis.Server.Component
  alias Anubis.Server.Component.Prompt
  alias Anubis.Server.Component.Resource
  alias Anubis.Server.Component.Tool
  alias Anubis.Server.Frame
  alias Anubis.Server.Handlers

  defmodule MockServer do
    @moduledoc false
    def __components__(:tool) do
      [
        %Tool{name: "tool_a", description: "Tool A"},
        %Tool{name: "tool_b", description: "Tool B"},
        %Tool{name: "tool_c", description: "Tool C"},
        %Tool{name: "tool_d", description: "Tool D"}
      ]
    end

    def __components__(:prompt) do
      [
        %Prompt{name: "prompt_1", description: "Prompt 1"},
        %Prompt{name: "prompt_2", description: "Prompt 2"},
        %Prompt{name: "prompt_3", description: "Prompt 3"}
      ]
    end

    def __components__(:resource) do
      [
        %Resource{uri: "resource://a", name: "resource_a", mime_type: "text/plain"},
        %Resource{uri: "resource://b", name: "resource_b", mime_type: "text/plain"},
        %Resource{uri: "resource://c", name: "resource_c", mime_type: "text/plain"},
        %Resource{uri: "resource://d", name: "resource_d", mime_type: "text/plain"},
        %Resource{uri: "resource://e", name: "resource_e", mime_type: "text/plain"},
        # Resource templates
        %Resource{
          uri_template: "file:///{path}",
          name: "template_1",
          title: "Project Files",
          description: "Access project files",
          mime_type: "application/octet-stream"
        },
        %Resource{
          uri_template: "db:///{table}/{id}",
          name: "template_2",
          title: "Database Records",
          mime_type: "application/json"
        }
      ]
    end
  end

  defmodule SubscribingServer do
    @moduledoc false
    def __components__(:resource), do: []
    def server_capabilities, do: %{"resources" => %{subscribe: true}}
  end

  defmodule NonSubscribingServer do
    @moduledoc false
    def __components__(:resource), do: []
    def server_capabilities, do: %{"resources" => %{}}
  end

  describe "maybe_paginate/3" do
    test "returns all items when limit is nil" do
      components = [
        %Tool{name: "a"},
        %Tool{name: "b"},
        %Tool{name: "c"}
      ]

      assert {^components, nil} = Handlers.maybe_paginate(%{}, components, nil)
    end

    test "paginates items when limit is set" do
      components = [
        %Tool{name: "a"},
        %Tool{name: "b"},
        %Tool{name: "c"},
        %Tool{name: "d"}
      ]

      {items, cursor} = Handlers.maybe_paginate(%{}, components, 2)
      assert length(items) == 2
      assert [%Tool{name: "a"}, %Tool{name: "b"}] = items
      assert cursor == Base.encode64("b", padding: false)
    end

    test "returns nil cursor when items don't exceed limit" do
      components = [
        %Tool{name: "a"},
        %Tool{name: "b"}
      ]

      {items, cursor} = Handlers.maybe_paginate(%{}, components, 5)
      assert length(items) == 2
      assert cursor == nil
    end

    test "handles cursor-based pagination" do
      components = [
        %Tool{name: "a"},
        %Tool{name: "b"},
        %Tool{name: "c"},
        %Tool{name: "d"}
      ]

      cursor = Base.encode64("b", padding: false)
      request = %{"params" => %{"cursor" => cursor}}

      {items, next_cursor} = Handlers.maybe_paginate(request, components, 2)
      assert length(items) == 2
      assert [%Tool{name: "c"}, %Tool{name: "d"}] = items
      refute next_cursor
    end

    test "returns empty list when cursor is beyond all items" do
      components = [
        %Tool{name: "a"},
        %Tool{name: "b"}
      ]

      cursor = Base.encode64("z", padding: false)
      request = %{"params" => %{"cursor" => cursor}}

      {items, next_cursor} = Handlers.maybe_paginate(request, components, 2)
      assert items == []
      assert next_cursor == nil
    end
  end

  describe "tools/list with pagination" do
    setup do
      frame = Frame.new()
      {:ok, frame: frame}
    end

    test "returns paginated tools when limit is set", %{frame: frame} do
      frame = Frame.put_pagination_limit(frame, 2)
      request = %{"method" => "tools/list", "params" => %{}}

      {:reply, response, _frame} = Handlers.handle(request, MockServer, frame)

      assert length(response["tools"]) == 2
      assert response["nextCursor"]
      assert [%{name: "tool_a"}, %{name: "tool_b"}] = response["tools"]
    end

    test "returns all tools when no limit is set", %{frame: frame} do
      request = %{"method" => "tools/list", "params" => %{}}

      {:reply, response, _frame} = Handlers.handle(request, MockServer, frame)

      assert length(response["tools"]) == 4
      refute Map.has_key?(response, "nextCursor")
    end

    test "handles cursor-based pagination", %{frame: frame} do
      frame = Frame.put_pagination_limit(frame, 2)
      cursor = Base.encode64("tool_b", padding: false)
      request = %{"method" => "tools/list", "params" => %{"cursor" => cursor}}

      {:reply, response, _frame} = Handlers.handle(request, MockServer, frame)

      assert length(response["tools"]) == 2
      refute response["nextCursor"]
      assert [%{name: "tool_c"}, %{name: "tool_d"}] = response["tools"]
    end
  end

  describe "prompts/list with pagination" do
    setup do
      frame = Frame.new()
      {:ok, frame: frame}
    end

    test "returns paginated prompts when limit is set", %{frame: frame} do
      frame = Frame.put_pagination_limit(frame, 2)
      request = %{"method" => "prompts/list", "params" => %{}}

      {:reply, response, _frame} = Handlers.handle(request, MockServer, frame)

      assert length(response["prompts"]) == 2
      assert response["nextCursor"]
      assert [%{name: "prompt_1"}, %{name: "prompt_2"}] = response["prompts"]
    end

    test "returns all prompts when no limit is set", %{frame: frame} do
      request = %{"method" => "prompts/list", "params" => %{}}

      {:reply, response, _frame} = Handlers.handle(request, MockServer, frame)

      assert length(response["prompts"]) == 3
      refute Map.has_key?(response, "nextCursor")
    end

    test "handles last page correctly", %{frame: frame} do
      frame = Frame.put_pagination_limit(frame, 2)
      cursor = Base.encode64("prompt_2", padding: false)
      request = %{"method" => "prompts/list", "params" => %{"cursor" => cursor}}

      {:reply, response, _frame} = Handlers.handle(request, MockServer, frame)

      assert length(response["prompts"]) == 1
      refute Map.has_key?(response, "nextCursor")
      assert [%{name: "prompt_3"}] = response["prompts"]
    end
  end

  describe "resources/list with pagination" do
    setup do
      frame = Frame.new()
      {:ok, frame: frame}
    end

    test "returns paginated resources when limit is set", %{frame: frame} do
      frame = Frame.put_pagination_limit(frame, 3)
      request = %{"method" => "resources/list", "params" => %{}}

      {:reply, response, _frame} = Handlers.handle(request, MockServer, frame)

      assert length(response["resources"]) == 3
      assert response["nextCursor"]

      assert [
               %{name: "resource_a"},
               %{name: "resource_b"},
               %{name: "resource_c"}
             ] = response["resources"]
    end

    test "returns all resources when no limit is set", %{frame: frame} do
      request = %{"method" => "resources/list", "params" => %{}}

      {:reply, response, _frame} = Handlers.handle(request, MockServer, frame)

      assert length(response["resources"]) == 5
      refute Map.has_key?(response, "nextCursor")
    end

    test "handles multiple pages", %{frame: frame} do
      frame = Frame.put_pagination_limit(frame, 2)

      request1 = %{"method" => "resources/list", "params" => %{}}
      {:reply, response1, _frame} = Handlers.handle(request1, MockServer, frame)

      assert length(response1["resources"]) == 2
      assert response1["nextCursor"]

      request2 = %{
        "method" => "resources/list",
        "params" => %{"cursor" => response1["nextCursor"]}
      }

      {:reply, response2, _frame} = Handlers.handle(request2, MockServer, frame)

      assert length(response2["resources"]) == 2
      assert response2["nextCursor"]

      request3 = %{
        "method" => "resources/list",
        "params" => %{"cursor" => response2["nextCursor"]}
      }

      {:reply, response3, _frame} = Handlers.handle(request3, MockServer, frame)

      assert length(response3["resources"]) == 1
      refute Map.has_key?(response3, "nextCursor")
    end
  end

  describe "resources/templates/list" do
    setup do
      frame = Frame.new()
      {:ok, frame: frame}
    end

    test "returns only resource templates", %{frame: frame} do
      request = %{"method" => "resources/templates/list", "params" => %{}}

      {:reply, response, _frame} = Handlers.handle(request, MockServer, frame)

      assert length(response["resourceTemplates"]) == 2
      refute Map.has_key?(response, "nextCursor")

      assert [
               %{uri_template: "file:///{path}", name: "template_1", title: "Project Files"},
               %{
                 uri_template: "db:///{table}/{id}",
                 name: "template_2",
                 title: "Database Records"
               }
             ] = response["resourceTemplates"]
    end

    test "returns paginated resource templates when limit is set", %{frame: frame} do
      frame = Frame.put_pagination_limit(frame, 1)
      request = %{"method" => "resources/templates/list", "params" => %{}}

      {:reply, response, _frame} = Handlers.handle(request, MockServer, frame)

      assert length(response["resourceTemplates"]) == 1
      assert response["nextCursor"]
      assert [%{name: "template_1"}] = response["resourceTemplates"]
    end

    test "handles cursor-based pagination for templates", %{frame: frame} do
      frame = Frame.put_pagination_limit(frame, 1)
      cursor = Base.encode64("template_1", padding: false)
      request = %{"method" => "resources/templates/list", "params" => %{"cursor" => cursor}}

      {:reply, response, _frame} = Handlers.handle(request, MockServer, frame)

      assert length(response["resourceTemplates"]) == 1
      refute Map.has_key?(response, "nextCursor")
      assert [%{name: "template_2"}] = response["resourceTemplates"]
    end
  end

  describe "get_server_resource_templates/2" do
    test "returns only templates, not static resources" do
      frame = Frame.new()
      templates = Handlers.get_server_resource_templates(MockServer, frame)

      assert length(templates) == 2
      assert Enum.all?(templates, & &1.uri_template)
      assert Enum.all?(templates, &is_nil(&1.uri))
    end
  end

  describe "resources/read with templates" do
    defmodule TestResourceTemplate do
      @moduledoc "Test resource template component"

      use Component,
        type: :resource,
        uri_template: "test:///{category}/{id}",
        name: "test_template",
        description: "Test resource template",
        mime_type: "application/json"

      alias Anubis.MCP.Error
      alias Anubis.Server.Response

      @impl true
      def read(%{"uri" => "test:///" <> rest}, frame) do
        case String.split(rest, "/") do
          [category, id] ->
            data = %{category: category, id: id}
            {:reply, Response.json(Response.resource(), data), frame}

          _ ->
            {:error, Error.resource(:not_found, %{message: "Invalid URI format"}), frame}
        end
      end

      def read(_params, frame) do
        {:error, Error.resource(:not_found, %{message: "URI doesn't match template"}), frame}
      end
    end

    defmodule TestServer do
      @moduledoc false

      use Anubis.Server,
        name: "Test Server",
        version: "1.0.0",
        capabilities: [:resources]

      component(TestResourceTemplate)
    end

    setup do
      frame = Frame.new()
      {:ok, frame: frame}
    end

    test "matches URI against template and calls handler", %{frame: frame} do
      request = %{
        "method" => "resources/read",
        "params" => %{"uri" => "test:///products/123"}
      }

      {:reply, response, _frame} = Handlers.handle(request, TestServer, frame)

      assert response["contents"]
      assert [content] = response["contents"]
      assert content["uri"] == "test:///products/123"
      assert content["mimeType"] == "application/json"

      assert String.contains?(content["text"], ~s("category":"products"))
      assert String.contains?(content["text"], ~s("id":"123"))
    end

    test "returns not_found when URI doesn't match template", %{frame: frame} do
      request = %{
        "method" => "resources/read",
        "params" => %{"uri" => "other:///something"}
      }

      {:error, error, _frame} = Handlers.handle(request, TestServer, frame)

      assert error.code == -32_002
      assert error.reason == :resource_not_found
    end
  end

  describe "multiple templates" do
    defmodule FileTemplate do
      @moduledoc false
      use Component,
        type: :resource,
        uri_template: "file:///{path}",
        name: "files"

      alias Anubis.MCP.Error
      alias Anubis.Server.Response

      @impl true
      def read(%{"uri" => "file:///" <> path}, frame) do
        {:reply, Response.text(Response.resource(), "File: #{path}"), frame}
      end

      def read(_params, frame) do
        {:error, Error.resource(:not_found, %{}), frame}
      end
    end

    defmodule DbTemplate do
      @moduledoc false
      use Component,
        type: :resource,
        uri_template: "db:///{table}/{id}",
        name: "database"

      alias Anubis.MCP.Error
      alias Anubis.Server.Response

      @impl true
      def read(%{"uri" => "db:///" <> rest}, frame) do
        {:reply, Response.text(Response.resource(), "DB: #{rest}"), frame}
      end

      def read(_params, frame) do
        {:error, Error.resource(:not_found, %{}), frame}
      end
    end

    defmodule MultiTemplateServer do
      @moduledoc false
      use Anubis.Server,
        name: "Multi Template Server",
        version: "1.0.0",
        capabilities: [:resources]

      component(FileTemplate)
      component(DbTemplate)
    end

    setup do
      frame = Frame.new()
      {:ok, frame: frame}
    end

    test "tries templates sequentially until one matches", %{frame: frame} do
      request = %{
        "method" => "resources/read",
        "params" => %{"uri" => "file:///README.md"}
      }

      {:reply, response, _frame} = Handlers.handle(request, MultiTemplateServer, frame)

      assert [content] = response["contents"]
      assert content["text"] == "File: README.md"
    end

    test "tries next template when first doesn't match", %{frame: frame} do
      request = %{
        "method" => "resources/read",
        "params" => %{"uri" => "db:///users/456"}
      }

      {:reply, response, _frame} = Handlers.handle(request, MultiTemplateServer, frame)

      assert [content] = response["contents"]
      assert content["text"] == "DB: users/456"
    end

    defmodule FallbackServer do
      @moduledoc false
      def __components__(:resource) do
        [
          %Resource{
            uri_template: "shared:///{id}",
            name: "scoped_first",
            mime_type: "text/plain",
            scopes: ["resources:admin"],
            handler: __MODULE__.ScopedHandler
          },
          %Resource{
            uri_template: "shared:///{id}",
            name: "public_second",
            mime_type: "text/plain",
            scopes: [],
            handler: __MODULE__.PublicHandler
          }
        ]
      end

      def server_capabilities, do: %{}

      defmodule ScopedHandler do
        @moduledoc false
        alias Anubis.Server.Response

        def read(_params, frame) do
          {:reply, Response.text(Response.resource(), "SCOPED"), frame}
        end
      end

      defmodule PublicHandler do
        @moduledoc false
        alias Anubis.Server.Response

        def read(_params, frame) do
          {:reply, Response.text(Response.resource(), "PUBLIC"), frame}
        end
      end
    end

    test "falls back to later matching template when earlier one fails scope check" do
      request = %{"method" => "resources/read", "params" => %{"uri" => "shared:///42"}}

      assert {:reply, response, _frame} = Handlers.handle(request, FallbackServer, Frame.new())
      assert [content] = response["contents"]
      assert content["text"] == "PUBLIC"
    end

    test "returns insufficient_scope when no later template matches" do
      defmodule OnlyScopedServer do
        @moduledoc false
        def __components__(:resource) do
          [
            %Resource{
              uri_template: "scoped:///{id}",
              name: "only_scoped",
              mime_type: "text/plain",
              scopes: ["resources:admin"],
              handler: FallbackServer.ScopedHandler
            }
          ]
        end

        def server_capabilities, do: %{}
      end

      request = %{"method" => "resources/read", "params" => %{"uri" => "scoped:///42"}}

      assert {:error, error, _frame} = Handlers.handle(request, OnlyScopedServer, Frame.new())
      assert error.message == "insufficient_scope" or error.reason == :insufficient_scope
    end
  end

  describe "edge cases" do
    setup do
      frame = Frame.new()
      {:ok, frame: frame}
    end

    test "handles empty component lists", %{frame: frame} do
      defmodule EmptyServer do
        @moduledoc false
        def __components__(_), do: []
      end

      frame = Frame.put_pagination_limit(frame, 10)

      for method <- ["tools/list", "prompts/list", "resources/list"] do
        request = %{"method" => method, "params" => %{}}
        {:reply, response, _frame} = Handlers.handle(request, EmptyServer, frame)

        key = method |> String.split("/") |> List.first()
        assert response[key] == []
        refute Map.has_key?(response, "nextCursor")
      end
    end

    test "handles single item with pagination", %{frame: frame} do
      defmodule SingleItemServer do
        @moduledoc false
        def __components__(:tool), do: [%Tool{name: "only_tool"}]
        def __components__(:prompt), do: []
        def __components__(:resource), do: []
      end

      frame = Frame.put_pagination_limit(frame, 1)
      request = %{"method" => "tools/list", "params" => %{}}

      {:reply, response, _frame} = Handlers.handle(request, SingleItemServer, frame)

      assert length(response["tools"]) == 1
      refute Map.has_key?(response, "nextCursor")
    end

    test "handles invalid cursor gracefully", %{frame: frame} do
      frame = Frame.put_pagination_limit(frame, 2)

      request = %{"method" => "tools/list", "params" => %{"cursor" => "invalid!!!"}}

      assert_raise ArgumentError, fn ->
        Handlers.handle(request, MockServer, frame)
      end
    end
  end

  describe "resources/subscribe routing" do
    test "subscribes when capability is declared" do
      request = %{"method" => "resources/subscribe", "params" => %{"uri" => "file:///x"}}

      assert {:reply, %{}, frame} = Handlers.handle(request, SubscribingServer, Frame.new())
      assert Frame.resource_subscribed?(frame, "file:///x")
    end

    test "returns method_not_found when capability is not declared" do
      request = %{"method" => "resources/subscribe", "params" => %{"uri" => "file:///x"}}

      assert {:error, error, _frame} =
               Handlers.handle(request, NonSubscribingServer, Frame.new())

      assert error.code == -32_601
    end

    test "subscribing to a URI not registered as a resource still succeeds" do
      request = %{"method" => "resources/subscribe", "params" => %{"uri" => "ghost:///nowhere"}}

      assert {:reply, %{}, frame} = Handlers.handle(request, SubscribingServer, Frame.new())
      assert Frame.resource_subscribed?(frame, "ghost:///nowhere")
    end
  end

  describe "resources/unsubscribe routing" do
    test "removes a previously-recorded subscription" do
      starting_frame = Frame.subscribe_resource(Frame.new(), "file:///x")
      request = %{"method" => "resources/unsubscribe", "params" => %{"uri" => "file:///x"}}

      assert {:reply, %{}, frame} =
               Handlers.handle(request, SubscribingServer, starting_frame)

      refute Frame.resource_subscribed?(frame, "file:///x")
    end

    test "returns method_not_found when capability is not declared" do
      request = %{"method" => "resources/unsubscribe", "params" => %{"uri" => "file:///x"}}

      assert {:error, error, _frame} =
               Handlers.handle(request, NonSubscribingServer, Frame.new())

      assert error.code == -32_601
    end
  end

  describe "unknown sub-action routing (Phase 0 regression)" do
    test "resources/<unknown> returns method_not_found instead of crashing" do
      request = %{"method" => "resources/foo", "params" => %{}}

      assert {:error, error, _frame} =
               Handlers.handle(request, SubscribingServer, Frame.new())

      assert error.code == -32_601
    end

    test "tools/<unknown> returns method_not_found instead of crashing" do
      request = %{"method" => "tools/nonexistent", "params" => %{}}

      assert {:error, error, _frame} = Handlers.handle(request, MockServer, Frame.new())
      assert error.code == -32_601
    end

    test "prompts/<unknown> returns method_not_found instead of crashing" do
      request = %{"method" => "prompts/nope", "params" => %{}}

      assert {:error, error, _frame} = Handlers.handle(request, MockServer, Frame.new())
      assert error.code == -32_601
    end
  end

  describe "list operations filter by scopes" do
    defmodule ScopedServer do
      @moduledoc false
      def __components__(:tool) do
        [
          %Tool{name: "public_tool", scopes: []},
          %Tool{name: "read_tool", scopes: ["tools:read"]},
          %Tool{name: "admin_tool", scopes: ["tools:admin"]}
        ]
      end

      def __components__(:prompt) do
        [
          %Prompt{name: "public_prompt", scopes: []},
          %Prompt{name: "scoped_prompt", scopes: ["prompts:read"]}
        ]
      end

      def __components__(:resource) do
        [
          %Resource{uri: "res://public", name: "public_res", mime_type: "text/plain", scopes: []},
          %Resource{uri: "res://secret", name: "secret_res", mime_type: "text/plain", scopes: ["resources:read"]},
          %Resource{
            uri_template: "tpl://{id}",
            name: "public_tpl",
            mime_type: "text/plain",
            scopes: []
          },
          %Resource{
            uri_template: "secret_tpl://{id}",
            name: "secret_tpl",
            mime_type: "text/plain",
            scopes: ["resources:admin"]
          }
        ]
      end

      def server_capabilities, do: %{"resources" => %{}}
    end

    defp frame_with_scopes(scopes) do
      %{Frame.new() | context: %Anubis.Server.Context{auth: %{scopes: scopes}}}
    end

    test "tools/list hides tools whose scopes are not granted" do
      frame = frame_with_scopes(["tools:read"])
      request = %{"method" => "tools/list", "params" => %{}}

      assert {:reply, %{"tools" => tools}, _} = Handlers.handle(request, ScopedServer, frame)
      names = Enum.map(tools, & &1.name)
      assert "public_tool" in names
      assert "read_tool" in names
      refute "admin_tool" in names
    end

    test "tools/list with no granted scopes returns only public tools" do
      request = %{"method" => "tools/list", "params" => %{}}

      assert {:reply, %{"tools" => tools}, _} = Handlers.handle(request, ScopedServer, Frame.new())
      assert Enum.map(tools, & &1.name) == ["public_tool"]
    end

    test "prompts/list hides scoped prompts" do
      request = %{"method" => "prompts/list", "params" => %{}}

      assert {:reply, %{"prompts" => prompts}, _} = Handlers.handle(request, ScopedServer, Frame.new())
      assert Enum.map(prompts, & &1.name) == ["public_prompt"]
    end

    test "resources/list hides scoped resources" do
      request = %{"method" => "resources/list", "params" => %{}}

      assert {:reply, %{"resources" => resources}, _} = Handlers.handle(request, ScopedServer, Frame.new())
      assert Enum.map(resources, & &1.name) == ["public_res"]
    end

    test "resources/templates/list hides scoped templates" do
      request = %{"method" => "resources/templates/list", "params" => %{}}

      assert {:reply, %{"resourceTemplates" => templates}, _} = Handlers.handle(request, ScopedServer, Frame.new())
      assert Enum.map(templates, & &1.name) == ["public_tpl"]
    end

    test "tools/list reveals tools when scopes are granted" do
      frame = frame_with_scopes(["tools:read", "tools:admin"])
      request = %{"method" => "tools/list", "params" => %{}}

      assert {:reply, %{"tools" => tools}, _} = Handlers.handle(request, ScopedServer, frame)
      assert Enum.sort(Enum.map(tools, & &1.name)) == ["admin_tool", "public_tool", "read_tool"]
    end

    test "prompts/list reveals scoped prompts when granted" do
      frame = frame_with_scopes(["prompts:read"])
      request = %{"method" => "prompts/list", "params" => %{}}

      assert {:reply, %{"prompts" => prompts}, _} = Handlers.handle(request, ScopedServer, frame)
      assert Enum.sort(Enum.map(prompts, & &1.name)) == ["public_prompt", "scoped_prompt"]
    end

    test "resources/list reveals scoped resources when granted" do
      frame = frame_with_scopes(["resources:read"])
      request = %{"method" => "resources/list", "params" => %{}}

      assert {:reply, %{"resources" => resources}, _} = Handlers.handle(request, ScopedServer, frame)
      assert Enum.sort(Enum.map(resources, & &1.name)) == ["public_res", "secret_res"]
    end

    test "resources/templates/list reveals scoped templates when granted" do
      frame = frame_with_scopes(["resources:admin"])
      request = %{"method" => "resources/templates/list", "params" => %{}}

      assert {:reply, %{"resourceTemplates" => templates}, _} = Handlers.handle(request, ScopedServer, frame)
      assert Enum.sort(Enum.map(templates, & &1.name)) == ["public_tpl", "secret_tpl"]
    end
  end

  describe "resources/subscribe scope enforcement" do
    defmodule ScopedSubscribingServer do
      @moduledoc false
      def __components__(:resource) do
        [
          %Resource{
            uri: "res://public",
            name: "public_res",
            mime_type: "text/plain",
            scopes: []
          },
          %Resource{
            uri: "res://secret",
            name: "secret_res",
            mime_type: "text/plain",
            scopes: ["resources:read"]
          },
          %Resource{
            uri_template: "secret_tpl://{id}",
            name: "secret_tpl",
            mime_type: "text/plain",
            scopes: ["resources:admin"]
          }
        ]
      end

      def server_capabilities, do: %{"resources" => %{subscribe: true}}
    end

    test "rejects subscribe to a scoped static resource without grant" do
      request = %{"method" => "resources/subscribe", "params" => %{"uri" => "res://secret"}}

      assert {:error, error, frame} = Handlers.handle(request, ScopedSubscribingServer, Frame.new())
      assert error.reason == :insufficient_scope or error.message == "insufficient_scope"
      refute Frame.resource_subscribed?(frame, "res://secret")
    end

    test "allows subscribe to scoped static resource when granted" do
      frame = frame_with_scopes(["resources:read"])
      request = %{"method" => "resources/subscribe", "params" => %{"uri" => "res://secret"}}

      assert {:reply, %{}, frame} = Handlers.handle(request, ScopedSubscribingServer, frame)
      assert Frame.resource_subscribed?(frame, "res://secret")
    end

    test "rejects subscribe to scoped template match without grant" do
      request = %{"method" => "resources/subscribe", "params" => %{"uri" => "secret_tpl://42"}}

      assert {:error, error, frame} = Handlers.handle(request, ScopedSubscribingServer, Frame.new())
      assert error.message == "insufficient_scope" or error.reason == :insufficient_scope
      refute Frame.resource_subscribed?(frame, "secret_tpl://42")
    end

    test "allows subscribe to unknown URI (future resource)" do
      request = %{"method" => "resources/subscribe", "params" => %{"uri" => "ghost:///unknown"}}

      assert {:reply, %{}, frame} = Handlers.handle(request, ScopedSubscribingServer, Frame.new())
      assert Frame.resource_subscribed?(frame, "ghost:///unknown")
    end

    test "allows subscribe to public resource without grant" do
      request = %{"method" => "resources/subscribe", "params" => %{"uri" => "res://public"}}

      assert {:reply, %{}, frame} = Handlers.handle(request, ScopedSubscribingServer, Frame.new())
      assert Frame.resource_subscribed?(frame, "res://public")
    end
  end
end
