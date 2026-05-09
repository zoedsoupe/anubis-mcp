defmodule Anubis.Server.Handlers.Tools do
  @moduledoc false

  alias Anubis.MCP.Error
  alias Anubis.Server.Component.Schema
  alias Anubis.Server.Component.Tool
  alias Anubis.Server.Frame
  alias Anubis.Server.Handlers
  alias Anubis.Server.Response

  @spec handle_list(map, Frame.t(), module()) ::
          {:reply, map(), Frame.t()} | {:error, Error.t(), Frame.t()}
  def handle_list(request, frame, server_module) do
    tools = Handlers.get_server_tools(server_module, frame)
    limit = frame.pagination_limit
    {tools, cursor} = Handlers.maybe_paginate(request, tools, limit)

    {:reply,
     then(
       %{"tools" => tools},
       &if(cursor, do: Map.put(&1, "nextCursor", cursor), else: &1)
     ), frame}
  end

  @spec handle_call(map(), Frame.t(), module()) ::
          {:reply, map(), Frame.t()} | {:error, Error.t(), Frame.t()}
  def handle_call(%{"params" => %{"name" => tool_name, "arguments" => params}} = request, frame, server) do
    registered_tools = Handlers.get_server_tools(server, frame)

    if tool = find_tool_module(registered_tools, tool_name) do
      with :ok <- check_task_policy(tool, request, frame),
           {:ok, params} <- validate_params(params, tool, frame),
           do: forward_to(server, tool, params, frame)
    else
      payload = %{message: "Tool not found: #{tool_name}"}
      {:error, Error.protocol(:invalid_params, payload), frame}
    end
  end

  def handle_call(%{"params" => %{"name" => tool_name}} = request, frame, server) do
    registered_tools = Handlers.get_server_tools(server, frame)

    if tool = find_tool_module(registered_tools, tool_name) do
      with :ok <- check_task_policy(tool, request, frame),
           {:ok, params} <- validate_params(%{}, tool, frame),
           do: forward_to(server, tool, params, frame)
    else
      payload = %{message: "Tool not found: #{tool_name}"}
      {:error, Error.protocol(:invalid_params, payload), frame}
    end
  end

  # Private functions

  defp find_tool_module(tools, name), do: Enum.find(tools, &(&1.name == name))

  # Spec 2025-11-25: tool with execution.taskSupport == "required" MUST be
  # invoked as a task. Direct (non-augmented) calls return -32601. Augmented
  # calls reach this handler only via the task worker path, where
  # `Frame.task_id` is set, so we use that as the discriminator.
  defp check_task_policy(%Tool{task_support: :required}, _request, %Frame{task_id: nil} = frame) do
    {:error,
     Error.protocol(:method_not_found, %{
       message: "Tool requires task augmentation (execution.taskSupport == \"required\")"
     }), frame}
  end

  defp check_task_policy(%Tool{task_support: :forbidden}, %{"params" => %{"task" => _}}, frame) do
    {:error,
     Error.protocol(:method_not_found, %{
       message: "Tool does not support task augmentation (execution.taskSupport == \"forbidden\")"
     }), frame}
  end

  defp check_task_policy(_tool, _request, _frame), do: :ok

  defp validate_params(_, %Tool{validate_input: nil}, _), do: {:ok, %{}}

  defp validate_params(params, %Tool{} = tool, frame) do
    with {:error, errors} <- tool.validate_input.(params) do
      message = Schema.format_errors(errors)
      {:error, Error.protocol(:invalid_params, %{message: message}), frame}
    end
  end

  defp forward_to(server, %Tool{handler: nil} = tool, params, frame) do
    case server.handle_tool_call(tool.name, params, frame) do
      {:reply, %Response{} = response, frame} ->
        maybe_validate_output_schema(tool, response, frame)

      {:noreply, frame} ->
        {:reply, %{"content" => [], "isError" => false}, frame}

      {:error, %Error{} = error, frame} ->
        {:error, error, frame}
    end
  end

  defp forward_to(_server, %Tool{handler: handler} = tool, params, frame) do
    case handler.execute(params, frame) do
      {:reply, %Response{} = response, frame} ->
        maybe_validate_output_schema(tool, response, frame)

      {:noreply, frame} ->
        {:reply, %{"content" => [], "isError" => false}, frame}

      {:error, %Error{} = error, frame} ->
        {:error, error, frame}
    end
  end

  @output_schema_err "Tool doesnt conform for it output schema"

  defp maybe_validate_output_schema(%Tool{output_schema: nil}, resp, frame) do
    {:reply, Response.to_protocol(resp), frame}
  end

  defp maybe_validate_output_schema(_tool, %Response{isError: true} = resp, frame) do
    {:reply, Response.to_protocol(resp), frame}
  end

  defp maybe_validate_output_schema(%Tool{} = tool, %Response{structured_content: nil}, frame) do
    metadata = %{tool_name: tool.name}
    {:error, Error.execution(@output_schema_err, metadata), frame}
  end

  defp maybe_validate_output_schema(%Tool{} = tool, %Response{} = resp, frame) do
    case tool.validate_output.(resp.structured_content) do
      {:ok, _} -> {:reply, Response.to_protocol(resp), frame}
      {:error, errors} -> {:error, Error.execution(@output_schema_err, %{errors: errors}), frame}
    end
  end
end
