defmodule Anubis.Server.Handlers.Resources do
  @moduledoc false

  alias Anubis.MCP.Error
  alias Anubis.Server.Component.Resource
  alias Anubis.Server.Component.URITemplate
  alias Anubis.Server.Frame
  alias Anubis.Server.Handlers
  alias Anubis.Server.Response

  @spec handle_list(map, Frame.t(), module()) ::
          {:reply, map(), Frame.t()} | {:error, Error.t(), Frame.t()}
  def handle_list(request, frame, server_module) do
    resources =
      server_module
      |> Handlers.get_server_resources(frame)
      |> Enum.filter(&visible?(&1, frame))

    limit = frame.pagination_limit
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
    templates =
      server_module
      |> Handlers.get_server_resource_templates(frame)
      |> Enum.filter(&visible?(&1, frame))

    limit = frame.pagination_limit
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
        with :ok <- check_scopes(resource, frame) do
          read_single_resource(server, resource, uri, frame)
        end

      nil ->
        try_resource_templates(templates, server, uri, frame)
    end
  end

  @spec handle_subscribe(map(), Frame.t(), module()) ::
          {:reply, map(), Frame.t()} | {:error, Error.t(), Frame.t()}
  def handle_subscribe(%{"params" => %{"uri" => uri}}, frame, server) when is_binary(uri) do
    if subscribe_enabled?(server) do
      {:reply, %{}, Frame.subscribe_resource(frame, uri)}
    else
      {:error, Error.protocol(:method_not_found, %{method: "resources/subscribe"}), frame}
    end
  end

  @spec handle_unsubscribe(map(), Frame.t(), module()) ::
          {:reply, map(), Frame.t()} | {:error, Error.t(), Frame.t()}
  def handle_unsubscribe(%{"params" => %{"uri" => uri}}, frame, server) when is_binary(uri) do
    if subscribe_enabled?(server) do
      {:reply, %{}, Frame.unsubscribe_resource(frame, uri)}
    else
      {:error, Error.protocol(:method_not_found, %{method: "resources/unsubscribe"}), frame}
    end
  end

  # Private functions

  defp check_scopes(%Resource{scopes: []}, _frame), do: :ok

  defp check_scopes(%Resource{scopes: required}, frame) do
    granted = Frame.scopes(frame)
    missing = Enum.reject(required, &(&1 in granted))

    if missing == [] do
      :ok
    else
      {:error, Error.execution("insufficient_scope", %{required: required, granted: granted}), frame}
    end
  end

  defp visible?(%Resource{scopes: []}, _frame), do: true
  defp visible?(%Resource{scopes: required}, frame), do: Frame.has_all_scopes?(frame, required)

  defp subscribe_enabled?(server) do
    get_in(server.server_capabilities(), ["resources", :subscribe]) == true
  end

  defp find_static_resource(resources, uri), do: Enum.find(resources, &(&1.uri == uri))

  defp try_resource_templates([], _server, uri, frame) do
    payload = %{message: "Resource not found: #{uri}"}
    error = Error.resource(:not_found, payload)
    {:error, error, frame}
  end

  defp try_resource_templates([template | rest], server, uri, frame) do
    case URITemplate.match(template.uri_template, uri) do
      {:ok, vars} ->
        with :ok <- check_scopes(template, frame),
             {:error, %Error{reason: :resource_not_found}, _frame} <-
               read_single_resource(server, template, uri, frame, vars),
             do: try_resource_templates(rest, server, uri, frame)

      :error ->
        try_resource_templates(rest, server, uri, frame)
    end
  end

  defp read_single_resource(server, resource, uri, frame, vars \\ %{})

  defp read_single_resource(server, %Resource{handler: nil, mime_type: mime_type}, uri, frame, _vars) do
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

  defp read_single_resource(_server, %Resource{handler: handler, mime_type: mime_type}, uri, frame, vars) do
    case handler.read(%{"uri" => uri, "params" => vars}, frame) do
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
