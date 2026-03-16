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

  @impl true
  def version, do: @version

  @impl true
  def supported_features, do: @features

  @impl true
  def request_methods, do: @request_methods

  @impl true
  def notification_methods, do: @notification_methods

  @impl true
  def progress_params_schema, do: @progress_params_schema

  @impl true
  def request_params_schema("sampling/createMessage") do
    text_content = %{
      "type" => {:required, {:literal, "text"}},
      "text" => {:required, :string}
    }

    image_content = %{
      "type" => {:required, {:literal, "image"}},
      "data" => {:required, :string},
      "mimeType" => {:required, :string}
    }

    audio_content = %{
      "type" => {:required, {:literal, "audio"}},
      "data" => {:required, :string},
      "mimeType" => {:required, :string}
    }

    message_schema = %{
      "role" => {:required, {:enum, ~w(user assistant system)}},
      "content" => {:required, {:oneof, [text_content, image_content, audio_content]}}
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
