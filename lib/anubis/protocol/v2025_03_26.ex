# credo:disable-for-this-file Credo.Check.Readability.ModuleNames
defmodule Anubis.Protocol.V2025_03_26 do
  @moduledoc """
  Protocol implementation for MCP specification version 2025-03-26.

  Builds on 2024-11-05, adding:
  - Streamable HTTP transport
  - Authorization framework
  - Audio content type
  - Tool annotations
  - Progress notification `message` field
  - Completion capability
  """

  @behaviour Anubis.Protocol.Behaviour

  alias Anubis.Protocol.Schema
  alias Anubis.Protocol.V2024_11_05

  @version "2025-03-26"

  @base_features V2024_11_05.supported_features()

  @features [
    :authorization,
    :audio_content,
    :tool_annotations,
    :progress_messages,
    :completion_capability
    | @base_features
  ]

  @request_methods V2024_11_05.request_methods()

  @notification_methods V2024_11_05.notification_methods()

  @progress_params_schema %{
    "progressToken" => {:required, {:either, {:string, :integer}}},
    "progress" => {:required, {:either, {:float, :integer}}},
    "total" => {:either, {:float, :integer}},
    "message" => :string
  }

  @text_content_schema %{
    "type" => {:required, {:literal, "text"}},
    "text" => {:required, :string}
  }

  @image_content_schema %{
    "type" => {:required, {:literal, "image"}},
    "data" => {:required, :string},
    "mimeType" => {:required, :string}
  }

  @audio_content_schema %{
    "type" => {:required, {:literal, "audio"}},
    "data" => {:required, :string},
    "mimeType" => {:required, :string}
  }

  @sampling_result_schema %{
    "role" => {:required, {:literal, "assistant"}},
    "content" => {:required, {:oneof, [@text_content_schema, @image_content_schema, @audio_content_schema]}},
    "model" => {:required, :string},
    "stopReason" => {:string, {:default, "endTurn"}}
  }

  @impl true
  def era, do: V2024_11_05.era()

  @impl true
  def version, do: @version

  @impl true
  def supported_features, do: @features

  @impl true
  def supports_feature?(feature), do: feature in @features

  @impl true
  def transport_rules, do: V2024_11_05.transport_rules()

  @impl true
  def server_capabilities(capabilities), do: V2024_11_05.server_capabilities(capabilities)

  @impl true
  def request_methods, do: @request_methods

  @impl true
  def notification_methods, do: @notification_methods

  @impl true
  def progress_params_schema, do: @progress_params_schema

  @impl true
  def request_result_schema("sampling/createMessage"), do: @sampling_result_schema

  def request_result_schema(method), do: V2024_11_05.request_result_schema(method)

  @impl true
  def request_message_schema do
    {:multi, :method, branches} = V2024_11_05.request_message_schema()

    sampling_branch =
      Schema.request_branch(
        "sampling/createMessage",
        Schema.with_progress_meta(request_params_schema("sampling/createMessage"))
      )

    {:multi, :method, Map.put(branches, "sampling/createMessage", sampling_branch)}
  end

  @impl true
  def notification_message_schema do
    {:multi, :method, branches} = V2024_11_05.notification_message_schema()

    progress_branch = Schema.notification_branch("notifications/progress", @progress_params_schema)

    {:multi, :method, Map.put(branches, "notifications/progress", progress_branch)}
  end

  @impl true
  def request_params_schema("sampling/createMessage") do
    message_schema = %{
      "role" => {:required, {:enum, ~w(user assistant system)}},
      "content" => {:required, {:oneof, [@text_content_schema, @image_content_schema, @audio_content_schema]}}
    }

    model_preferences = %{
      "intelligencePriority" => :float,
      "speedPriority" => :float,
      "costPriority" => :float,
      "hints" => {:list, %{"name" => :string}}
    }

    %{
      "messages" => {:list, message_schema},
      "modelPreferences" => model_preferences,
      "systemPrompt" => :string,
      "maxTokens" => :integer
    }
  end

  def request_params_schema(method) do
    V2024_11_05.request_params_schema(method)
  end

  @impl true
  def notification_params_schema("notifications/progress"), do: @progress_params_schema

  def notification_params_schema(method) do
    V2024_11_05.notification_params_schema(method)
  end
end
