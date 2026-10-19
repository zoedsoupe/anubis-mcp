defmodule Anubis.Server.Component.ResourceMetaTest do
  use ExUnit.Case, async: true

  alias Anubis.Server.Component
  alias Anubis.Server.Frame
  alias Anubis.Server.Handlers
  alias Anubis.Server.Response

  @ui_meta %{"ui" => %{"csp" => %{"connectDomains" => ["https://api.example.com"]}, "prefersBorder" => true}}

  defmodule DashboardResource do
    @moduledoc "Interactive dashboard"

    use Component,
      type: :resource,
      uri: "ui://example/dashboard",
      name: "dashboard",
      mime_type: "text/html;profile=mcp-app",
      meta: %{"ui" => %{"prefersBorder" => true}}

    @impl true
    def read(_params, frame) do
      response =
        Response.resource()
        |> Response.text("<!DOCTYPE html><html></html>")
        |> Response.meta(%{
          "ui" => %{"csp" => %{"connectDomains" => ["https://api.example.com"]}, "prefersBorder" => true}
        })

      {:reply, response, frame}
    end
  end

  defmodule ReportTemplate do
    @moduledoc "Report by id"

    use Component,
      type: :resource,
      uri_template: "reports:///{id}",
      name: "report",
      meta: %{"source" => "test"}

    @impl true
    def read(_params, frame), do: {:reply, Response.text(Response.resource(), "report"), frame}
  end

  defmodule PlainResource do
    @moduledoc "No meta"

    use Component, type: :resource, uri: "file:///plain.txt"

    @impl true
    def read(_params, frame), do: {:reply, Response.text(Response.resource(), "plain"), frame}
  end

  defmodule Server do
    @moduledoc false

    use Anubis.Server, name: "Meta Server", version: "1.0.0", capabilities: [:resources]

    component(DashboardResource)
    component(ReportTemplate)
    component(PlainResource)
  end

  defp list(method, key, frame \\ Frame.new()) do
    {:reply, response, _frame} = Handlers.handle(%{"method" => method, "params" => %{}}, Server, frame)
    response[key] |> JSON.encode!() |> JSON.decode!()
  end

  test "component :meta defines meta/0 for resources" do
    assert DashboardResource.meta() == %{"ui" => %{"prefersBorder" => true}}
    refute function_exported?(PlainResource, :meta, 0)
  end

  test "resources/list carries _meta only for resources that declare it" do
    resources = list("resources/list", "resources")

    assert %{"_meta" => %{"ui" => %{"prefersBorder" => true}}} =
             Enum.find(resources, &(&1["uri"] == "ui://example/dashboard"))

    refute Map.has_key?(Enum.find(resources, &(&1["uri"] == "file:///plain.txt")), "_meta")
  end

  test "resources/templates/list carries _meta" do
    assert [%{"uriTemplate" => "reports:///{id}", "_meta" => %{"source" => "test"}}] =
             list("resources/templates/list", "resourceTemplates")
  end

  test "runtime-registered resources and templates carry _meta" do
    frame =
      Frame.new()
      |> Frame.register_resource("ui://example/runtime", mime_type: "text/html;profile=mcp-app", meta: @ui_meta)
      |> Frame.register_resource_template("runtime:///{id}", name: "runtime", meta: @ui_meta)

    assert %{"_meta" => @ui_meta} =
             Enum.find(list("resources/list", "resources", frame), &(&1["uri"] == "ui://example/runtime"))

    assert %{"_meta" => @ui_meta} =
             Enum.find(list("resources/templates/list", "resourceTemplates", frame), &(&1["name"] == "runtime"))
  end

  test "resources/read carries _meta on the contents" do
    request = %{"method" => "resources/read", "params" => %{"uri" => "ui://example/dashboard"}}

    assert {:reply, %{"contents" => [content]}, _frame} = Handlers.handle(request, Server, Frame.new())

    assert content == %{
             "uri" => "ui://example/dashboard",
             "mimeType" => "text/html;profile=mcp-app",
             "text" => "<!DOCTYPE html><html></html>",
             "_meta" => @ui_meta
           }
  end
end
