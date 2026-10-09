# credo:disable-for-this-file Credo.Check.Readability.ModuleNames
defmodule Anubis.Protocol.V2026_07_28 do
  @moduledoc """
  Protocol implementation for MCP specification version 2026-07-28.

  The first version in the `:stateless` era. Rather than building on
  2025-11-25, it reshapes the protocol around per-request metadata:

  - Removes the `initialize` / `notifications/initialized` handshake. Every
    request carries `io.modelcontextprotocol/protocolVersion` and
    `io.modelcontextprotocol/clientCapabilities` in `_meta`.
  - Adds `server/discover`, which servers must implement to advertise their
    supported versions, capabilities and identity.
  - Replaces `resources/subscribe` / `resources/unsubscribe` with
    `subscriptions/listen`, a single opt-in notification stream whose
    messages are tagged with `io.modelcontextprotocol/subscriptionId`.
  - Removes `ping` and `logging/setLevel`; log verbosity is requested
    per-request via `io.modelcontextprotocol/logLevel`.
  - Removes server-initiated requests. `roots/list`,
    `sampling/createMessage` and `elicitation/create` are no longer
    JSON-RPC methods; they are carried inside an `InputRequiredResult`
    under the multi round-trip requests pattern.
  - Gives every result a `resultType`: `complete`, or `input_required` when
    `tools/call`, `prompts/get` or `resources/read` returns an
    `InputRequiredResult`. Complete results of cacheable methods carry
    `ttlMs` and `cacheScope`.
  - Moves tasks out of the core protocol into the
    `io.modelcontextprotocol/tasks` extension, advertised under the new
    `extensions` capability.
  """

  @behaviour Anubis.Protocol.Behaviour

  alias Anubis.Protocol.Schema
  alias Anubis.Protocol.V2025_06_18

  @version "2026-07-28"

  @era :stateless

  @transport_rules %{batching: false, protocol_version_header: true}

  @capability_keys ~w(prompts tools resources completion logging extensions)

  @removed_features [:ping, :roots, :sampling, :elicitation]

  @features [
    :stateless,
    :discovery,
    :subscriptions,
    :extensions
    | V2025_06_18.supported_features() -- @removed_features
  ]

  @request_methods ~w(
    server/discover
    subscriptions/listen
    resources/list resources/templates/list resources/read
    prompts/get prompts/list
    tools/call tools/list
    completion/complete
  )

  @notification_methods ~w(
    notifications/cancelled
    notifications/progress
    notifications/message
    notifications/subscriptions/acknowledged
    notifications/tools/list_changed
    notifications/prompts/list_changed
    notifications/resources/list_changed
    notifications/resources/updated
  )

  @subscription_filter %{
    "toolsListChanged" => :boolean,
    "promptsListChanged" => :boolean,
    "resourcesListChanged" => :boolean,
    "resourceSubscriptions" => {:list, :string}
  }

  @mrtr_params %{
    "inputResponses" => :map,
    "requestState" => :string
  }

  @result %{"resultType" => {:required, {:literal, "complete"}}, "_meta" => :map}

  @cacheable_result Map.merge(@result, %{
                      "ttlMs" => {:required, {:integer, {:gte, 0}}},
                      "cacheScope" => {:required, {:enum, ~w(public private)}}
                    })

  @list_result Map.put(@cacheable_result, "nextCursor", :string)

  @input_request_params %{
    "elicitation/create" => {:required, :map},
    "sampling/createMessage" => {:required, :map},
    "roots/list" => :map
  }

  @input_request {:multi, :method,
                  Map.new(@input_request_params, fn {method, params} ->
                    {method, %{"method" => {:required, {:literal, method}}, "params" => params}}
                  end)}

  @input_required_fields %{
    "resultType" => {:required, {:literal, "input_required"}},
    "_meta" => :map,
    "inputRequests" => {:map, :string, @input_request},
    "requestState" => :string
  }

  # The spec requires at least one of inputRequests and requestState.
  @input_required_result {:either,
                          {%{@input_required_fields | "inputRequests" => {:required, {:map, :string, @input_request}}},
                           %{@input_required_fields | "requestState" => {:required, :string}}}}

  @discover_result_schema Map.merge(@cacheable_result, %{
                            "supportedVersions" => {:required, {:list, :string}},
                            "capabilities" => {:required, :map},
                            "instructions" => :string
                          })

  @listen_result_schema Map.merge(@result, Schema.subscription_meta())

  @list_tools_result_schema Map.put(@list_result, "tools", {:required, {:list, :map}})
  @list_prompts_result_schema Map.put(@list_result, "prompts", {:required, {:list, :map}})
  @list_resources_result_schema Map.put(@list_result, "resources", {:required, {:list, :map}})
  @list_resource_templates_result_schema Map.put(@list_result, "resourceTemplates", {:required, {:list, :map}})

  @read_resource_result_schema {:multi, :resultType,
                                %{
                                  "complete" => Map.put(@cacheable_result, "contents", {:required, {:list, :map}}),
                                  "input_required" => @input_required_result
                                }}

  @call_tool_result_schema {:multi, :resultType,
                            %{
                              "complete" =>
                                Map.merge(@result, %{
                                  "content" => {:required, {:list, :map}},
                                  "structuredContent" => :any,
                                  "isError" => :boolean
                                }),
                              "input_required" => @input_required_result
                            }}

  @get_prompt_result_schema {:multi, :resultType,
                             %{
                               "complete" =>
                                 Map.merge(@result, %{
                                   "description" => :string,
                                   "messages" => {:required, {:list, :map}}
                                 }),
                               "input_required" => @input_required_result
                             }}

  @impl true
  def era, do: @era

  @impl true
  def version, do: @version

  @impl true
  def supported_features, do: @features

  @impl true
  def supports_feature?(feature), do: feature in @features

  @impl true
  def transport_rules, do: @transport_rules

  @impl true
  def server_capabilities(capabilities) when is_map(capabilities) do
    Map.take(capabilities, @capability_keys)
  end

  @impl true
  def request_methods, do: @request_methods

  @impl true
  def notification_methods, do: @notification_methods

  @impl true
  def progress_params_schema, do: V2025_06_18.progress_params_schema()

  @impl true
  def request_result_schema("server/discover"), do: @discover_result_schema
  def request_result_schema("subscriptions/listen"), do: @listen_result_schema
  def request_result_schema("tools/list"), do: @list_tools_result_schema
  def request_result_schema("prompts/list"), do: @list_prompts_result_schema
  def request_result_schema("resources/list"), do: @list_resources_result_schema
  def request_result_schema("resources/templates/list"), do: @list_resource_templates_result_schema
  def request_result_schema("resources/read"), do: @read_resource_result_schema
  def request_result_schema("tools/call"), do: @call_tool_result_schema
  def request_result_schema("prompts/get"), do: @get_prompt_result_schema

  # completion/complete stays unmodeled until its values go out as strings, as the spec requires.
  def request_result_schema(_method), do: nil

  @impl true
  def request_message_schema do
    {:multi, :method,
     Map.new(@request_methods, fn method ->
       {method, Schema.stateless_request_branch(method, request_params_schema(method))}
     end)}
  end

  @impl true
  def notification_message_schema do
    {:multi, :method,
     Map.new(@notification_methods, fn method ->
       {method, Schema.notification_branch(method, notification_params_schema(method))}
     end)}
  end

  @impl true
  def request_params_schema("server/discover"), do: %{}

  def request_params_schema("subscriptions/listen"), do: %{"notifications" => @subscription_filter}

  def request_params_schema("resources/list"), do: %{"cursor" => :string}
  def request_params_schema("resources/templates/list"), do: %{"cursor" => :string}
  def request_params_schema("prompts/list"), do: %{"cursor" => :string}
  def request_params_schema("tools/list"), do: %{"cursor" => :string}

  def request_params_schema("resources/read") do
    Map.put(@mrtr_params, "uri", {:required, :string})
  end

  def request_params_schema(method) when method in ~w(prompts/get tools/call) do
    Map.merge(@mrtr_params, %{"name" => {:required, :string}, "arguments" => :map})
  end

  def request_params_schema("completion/complete") do
    V2025_06_18.request_params_schema("completion/complete")
  end

  def request_params_schema(method) when method in @request_methods, do: %{}

  def request_params_schema(_method), do: :map

  @impl true
  def notification_params_schema("notifications/cancelled") do
    V2025_06_18.notification_params_schema("notifications/cancelled")
  end

  def notification_params_schema("notifications/progress"), do: progress_params_schema()

  def notification_params_schema("notifications/message") do
    V2025_06_18.notification_params_schema("notifications/message")
  end

  def notification_params_schema("notifications/subscriptions/acknowledged") do
    Map.put(Schema.subscription_meta(), "notifications", @subscription_filter)
  end

  def notification_params_schema("notifications/resources/updated") do
    Map.put(Schema.subscription_meta(), "uri", {:required, :string})
  end

  def notification_params_schema(method) when method in ~w(
        notifications/tools/list_changed
        notifications/prompts/list_changed
        notifications/resources/list_changed
      ) do
    Schema.subscription_meta()
  end

  def notification_params_schema(_method), do: :map
end
