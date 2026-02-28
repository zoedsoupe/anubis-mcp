# credo:disable-for-this-file Credo.Check.Readability.ModuleNames
defmodule Anubis.Protocol.V2024_11_05 do
  @moduledoc """
  Protocol implementation for MCP specification version 2024-11-05.

  This is the initial MCP spec version, supporting:
  - SSE transport
  - Basic tools, resources, and prompts
  - Logging, progress, cancellation
  - Ping, roots, sampling
  """

  @behaviour Anubis.Protocol.Behaviour

  @version "2024-11-05"

  @features [
    :basic_messaging,
    :resources,
    :tools,
    :prompts,
    :logging,
    :progress,
    :cancellation,
    :ping,
    :roots,
    :sampling
  ]

  @request_methods ~w(
    initialize ping
    resources/list resources/templates/list resources/read
    prompts/get prompts/list
    tools/call tools/list
    logging/setLevel completion/complete
    roots/list sampling/createMessage
  )

  @notification_methods ~w(
    notifications/initialized notifications/cancelled
    notifications/progress notifications/message
    notifications/roots/list_changed notifications/log/message
    notifications/tools/list_changed
  )

  @progress_params_schema %{
    "progressToken" => {:required, {:either, {:string, :integer}}},
    "progress" => {:required, {:either, {:float, :integer}}},
    "total" => {:either, {:float, :integer}}
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
  def request_params_schema("initialize") do
    %{
      "protocolVersion" => {:required, :string},
      "capabilities" => {:map, {:default, %{}}},
      "clientInfo" => %{
        "name" => {:required, :string},
        "version" => {:required, :string}
      }
    }
  end

  def request_params_schema("ping"), do: :map
  def request_params_schema("resources/list"), do: %{"cursor" => :string}
  def request_params_schema("resources/templates/list"), do: %{"cursor" => :string}
  def request_params_schema("resources/read"), do: %{"uri" => {:required, :string}}
  def request_params_schema("prompts/list"), do: %{"cursor" => :string}

  def request_params_schema("prompts/get") do
    %{"name" => {:required, :string}, "arguments" => :map}
  end

  def request_params_schema("tools/list"), do: %{"cursor" => :string}

  def request_params_schema("tools/call") do
    %{"name" => {:required, :string}, "arguments" => :map}
  end

  @log_levels ~w(debug info notice warning error critical alert emergency)

  def request_params_schema("logging/setLevel") do
    %{"level" => {:required, {:enum, @log_levels}}}
  end

  def request_params_schema("completion/complete") do
    %{
      "ref" =>
        {:required,
         {:oneof,
          [
            %{
              "type" => {:required, {:string, {:eq, "ref/prompt"}}},
              "name" => {:required, :string}
            },
            %{
              "type" => {:required, {:string, {:eq, "ref/resource"}}},
              "uri" => {:required, :string}
            }
          ]}},
      "argument" =>
        {:required,
         %{
           "name" => {:required, :string},
           "value" => {:required, :string}
         }}
    }
  end

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

    message_schema = %{
      "role" => {:required, {:enum, ~w(user assistant system)}},
      "content" => {:required, {:oneof, [text_content, image_content]}}
    }

    %{
      "messages" => {:list, message_schema},
      "systemPrompt" => :string,
      "maxTokens" => :integer
    }
  end

  def request_params_schema("roots/list"), do: :map
  def request_params_schema(_), do: :map

  @impl true
  def notification_params_schema("notifications/initialized"), do: :map

  def notification_params_schema("notifications/cancelled") do
    %{
      "requestId" => {:required, {:either, {:string, :integer}}},
      "reason" => :string
    }
  end

  def notification_params_schema("notifications/progress"), do: @progress_params_schema

  def notification_params_schema("notifications/message") do
    %{
      "level" => {:required, {:enum, @log_levels}},
      "data" => {:required, :any},
      "logger" => :string
    }
  end

  def notification_params_schema("notifications/roots/list_changed"), do: :map
  def notification_params_schema(_), do: :map
end
