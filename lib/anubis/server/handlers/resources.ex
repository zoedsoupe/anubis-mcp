defmodule Anubis.Server.Handlers.Resources do
  @moduledoc false

  alias Anubis.MCP.Error
  alias Anubis.Server.Component.Resource
  alias Anubis.Server.Frame
  alias Anubis.Server.Handlers
  alias Anubis.Server.Response

  @spec handle_list(map, Frame.t(), module()) ::
          {:reply, map(), Frame.t()} | {:error, Error.t(), Frame.t()}
  def handle_list(request, frame, server_module) do
    resources = Handlers.get_server_resources(server_module, frame)
    limit = frame.private[:pagination_limit]
    {resources, cursor} = Handlers.maybe_paginate(request, resources, limit)

    {:reply,
     then(
       %{"resources" => resources},
       &if(cursor, do: Map.put(&1, "nextCursor", cursor), else: &1)
     ), frame}
  end

  @spec handle_templates_list(map, Frame.t(), module()) ::
          {:reply, map(), Frame.t()} | {:error, Error.t(), Frame.t()}
  def handle_templates_list(request, frame, server_module) do
    templates = Handlers.get_server_resource_templates(server_module, frame)
    limit = frame.private[:pagination_limit]
    {templates, cursor} = Handlers.maybe_paginate(request, templates, limit)

    {:reply,
     then(
       %{"resourceTemplates" => templates},
       &if(cursor, do: Map.put(&1, "nextCursor", cursor), else: &1)
     ), frame}
  end

  @spec handle_read(map(), Frame.t(), module()) ::
          {:reply, map(), Frame.t()} | {:error, Error.t(), Frame.t()}
  def handle_read(%{"params" => %{"uri" => uri}}, frame, server) when is_binary(uri) do
    resources = Handlers.get_server_resources(server, frame)
    templates = Handlers.get_server_resource_templates(server, frame)

    case find_static_resource(resources, uri) do
      %Resource{} = resource ->
        read_single_resource(server, resource, uri, frame)

      nil ->
        try_resource_templates(templates, server, uri, frame)
    end
  end

  # Private functions

  defp find_static_resource(resources, uri), do: Enum.find(resources, &(&1.uri == uri))

  defp try_resource_templates([], _server, uri, frame) do
    payload = %{message: "Resource not found: #{uri}"}
    error = Error.resource(:not_found, payload)
    {:error, error, frame}
  end

  defp try_resource_templates([template | rest], server, uri, frame) do
    case read_single_resource(server, template, uri, frame) do
      {:error, %Error{code: -32_002}, _frame} ->
        # Try templates sequentially until one matches or all fail
        try_resource_templates(rest, server, uri, frame)

      result ->
        # Either success or a different error (e.g., permission denied)
        # Return immediately - don't try other templates
        result
    end
  end

  defp read_single_resource(server, %Resource{handler: nil, mime_type: mime_type}, uri, frame) do
    case server.handle_resource_read(uri, frame) do
      {:reply, %Response{} = response, frame} ->
        content = Response.to_protocol(response, uri, mime_type)
        {:reply, %{"contents" => [content]}, frame}

      {:noreply, frame} ->
        content = %{"uri" => uri, "mimeType" => mime_type, "text" => ""}
        {:reply, %{"contents" => [content]}, frame}

      {:error, %Error{} = error, frame} ->
        {:error, error, frame}
    end
  end

  defp read_single_resource(_server, %Resource{handler: handler, mime_type: mime_type}, uri, frame) do
    case handler.read(%{"uri" => uri}, frame) do
      {:reply, %Response{} = response, frame} ->
        content = Response.to_protocol(response, uri, mime_type)
        {:reply, %{"contents" => [content]}, frame}

      {:noreply, frame} ->
        content = %{"uri" => uri, "mimeType" => mime_type, "text" => ""}
        {:reply, %{"contents" => [content]}, frame}

      {:error, %Error{} = error, frame} ->
        {:error, error, frame}
    end
  end
end
