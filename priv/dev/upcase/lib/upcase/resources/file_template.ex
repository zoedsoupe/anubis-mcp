defmodule Upcase.Resources.FileTemplate do
  @moduledoc "Resource template for accessing project files dynamically"

  use Anubis.Server.Component,
    type: :resource,
    uri_template: "file:///{path}",
    name: "project_files",
    description: "Access files in the project directory",
    mime_type: "text/plain"

  alias Anubis.MCP.Error
  alias Anubis.Server.Response

  @impl true
  def read(%{"uri" => "file:///" <> path}, frame) do
    file_path = Path.join(["priv", path])

    case File.read(file_path) do
      {:ok, content} ->
        {:reply, Response.text(Response.resource(), content), frame}

      {:error, :enoent} ->
        {:error, Error.resource(:not_found, %{path: path}), frame}

      {:error, reason} ->
        {:error, Error.execution("Failed to read file: #{inspect(reason)}"), frame}
    end
  end

  def read(%{"uri" => uri}, frame) do
    {:error, Error.resource(:not_found, %{message: "URI does not match template file:///{path}", uri: uri}), frame}
  end
end
