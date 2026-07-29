# credo:disable-for-this-file Credo.Check.Readability.ModuleNames
defmodule Anubis.Protocol.V2025_06_18 do
  @moduledoc """
  Protocol implementation for MCP specification version 2025-06-18.

  Builds on 2025-03-26, adding:
  - Elicitation support
  - Structured tool output (`structuredContent`)
  - Tool output schemas
  - Model preferences in sampling
  - Embedded resources in prompts and tools
  - `resource_link` content type
  - `MCP-Protocol-Version` header required
  - Removed JSON-RPC batching
  """

  @behaviour Anubis.Protocol.Behaviour

  alias Anubis.Protocol.Schema
  alias Anubis.Protocol.V2025_03_26

  @version "2025-06-18"

  @transport_rules %{batching: false, protocol_version_header: true}

  @base_features V2025_03_26.supported_features()

  @features [
    :elicitation,
    :structured_tool_results,
    :tool_output_schemas,
    :model_preferences,
    :embedded_resources_in_prompts,
    :embedded_resources_in_tools
    | @base_features
  ]

  @request_methods ["elicitation/create" | V2025_03_26.request_methods()]

  @notification_methods V2025_03_26.notification_methods()

  @elicitation_create_params %{
    "message" => {:required, :string},
    "requestedSchema" => {:required, {:custom, &Anubis.MCP.ElicitationSchema.validate/1}}
  }

  @elicitation_result_schema %{
    "action" => {:required, {:enum, ~w(accept decline cancel)}},
    "content" => :map
  }

  @impl true
  def era, do: V2025_03_26.era()

  @impl true
  def version, do: @version

  @impl true
  def supported_features, do: @features

  @impl true
  def supports_feature?(feature), do: feature in @features

  @impl true
  def transport_rules, do: @transport_rules

  @impl true
  def server_capabilities(capabilities), do: V2025_03_26.server_capabilities(capabilities)

  @impl true
  def request_methods, do: @request_methods

  @impl true
  def notification_methods, do: @notification_methods

  @impl true
  def progress_params_schema do
    V2025_03_26.progress_params_schema()
  end

  @impl true
  def request_result_schema("elicitation/create"), do: @elicitation_result_schema

  def request_result_schema(method), do: V2025_03_26.request_result_schema(method)

  @impl true
  def request_message_schema do
    {:multi, :method, branches} = V2025_03_26.request_message_schema()

    elicitation_branch =
      Schema.request_branch("elicitation/create", Schema.with_progress_meta(@elicitation_create_params))

    {:multi, :method, Map.put(branches, "elicitation/create", elicitation_branch)}
  end

  @impl true
  def notification_message_schema, do: V2025_03_26.notification_message_schema()

  @impl true
  def request_params_schema("elicitation/create"), do: @elicitation_create_params

  def request_params_schema(method) do
    V2025_03_26.request_params_schema(method)
  end

  @impl true
  def notification_params_schema(method) do
    V2025_03_26.notification_params_schema(method)
  end
end
