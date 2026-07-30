defmodule Anubis.MCP.Message do
  @moduledoc """
  Handles parsing and validation of MCP (Model Context Protocol) messages using the Peri library.

  Message validation and encoding are version-aware: request and notification
  schemas come from the negotiated protocol version module (see
  `Anubis.Protocol.Behaviour`). Functions that take no protocol module default
  to the latest registered version, which preserves the previous superset
  behavior. Removing a feature from a version means deleting it from that
  version's module; nothing here changes.
  """

  alias Anubis.Protocol.Registry
  alias Anubis.Protocol.V2024_11_05
  alias Anubis.Protocol.V2025_03_26

  @log_levels ~w(debug info notice warning error critical alert emergency)

  # Progress notification schemas exposed for the encode helpers, single-sourced
  # from the protocol version modules.
  @progress_notif_params_schema V2024_11_05.progress_params_schema()
  @progress_notif_params_schema_2025 V2025_03_26.progress_params_schema()

  # Response and error envelopes are version-independent; request and
  # notification envelopes come from the protocol version modules.
  @response_schema %{
    "jsonrpc" => {:required, {:string, {:eq, "2.0"}}},
    "result" => {:required, :any},
    "id" => {:required, {:either, {:string, :integer}}}
  }

  @error_schema %{
    "jsonrpc" => {:required, {:string, {:eq, "2.0"}}},
    "error" =>
      {:required,
       %{
         "code" => {:required, :integer},
         "message" => {:required, :string},
         "data" => :any
       }},
    "id" => {:required, {:either, {:string, :integer}}}
  }

  # generic guards

  @doc """
  Guard to determine if a JSON-RPC message is a request.

  A message is considered a request if it contains both "method" and "id" fields.

  ## Examples

      iex> message = %{"jsonrpc" => "2.0", "method" => "ping", "id" => 1}
      iex> is_request(message)
      true

      iex> notification = %{"jsonrpc" => "2.0", "method" => "notification"}
      iex> is_request(notification)
      false
  """
  defguard is_request(data)
           when is_map_key(data, "method") and is_map_key(data, "id")

  @doc """
  Guard to determine if a JSON-RPC message is a notification.

  A message is considered a notification if it contains a "method" field but no "id" field.

  ## Examples

      iex> message = %{"jsonrpc" => "2.0", "method" => "notification"}
      iex> is_notification(message)
      true

      iex> request = %{"jsonrpc" => "2.0", "method" => "ping", "id" => 1}
      iex> is_notification(request)
      false
  """
  defguard is_notification(data)
           when is_map_key(data, "method") and not is_map_key(data, "id")

  @doc """
  Guard to determine if a JSON-RPC message is a response.

  A message is considered a response if it contains both "result" and "id" fields.

  ## Examples

      iex> message = %{"jsonrpc" => "2.0", "result" => %{}, "id" => 1}
      iex> is_response(message)
      true
  """
  defguard is_response(data)
           when is_map_key(data, "result") and is_map_key(data, "id")

  @doc """
  Guard to determine if a JSON-RPC message is an error.

  A message is considered an error if it contains both "error" and "id" fields.

  ## Examples

      iex> message = %{"jsonrpc" => "2.0", "error" => %{"code" => -32600}, "id" => 1}
      iex> is_error(message)
      true
  """
  defguard is_error(data) when is_map_key(data, "error") and is_map_key(data, "id")

  # request guards

  @doc """
  Guard to check if a request is a ping request.

  ## Examples

      iex> message = %{"jsonrpc" => "2.0", "method" => "ping", "id" => 1}
      iex> is_ping(message)
      true
  """
  defguard is_ping(data)
           when is_request(data) and :erlang.map_get("method", data) == "ping"

  @doc """
  Guard to check if a request is an initialize request.

  ## Examples

      iex> message = %{"jsonrpc" => "2.0", "method" => "initialize", "id" => 1, "params" => %{}}
      iex> is_initialize(message)
      true
  """
  defguard is_initialize(data)
           when is_request(data) and :erlang.map_get("method", data) == "initialize"

  @doc """
  Guard to check if a message is part of the initialization lifecycle.

  This includes both the initialize request and the notifications/initialized notification.

  ## Examples

      iex> init_request = %{"jsonrpc" => "2.0", "method" => "initialize", "id" => 1, "params" => %{}}
      iex> is_initialize_lifecycle(init_request)
      true

      iex> init_notification = %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
      iex> is_initialize_lifecycle(init_notification)
      true

      iex> other_message = %{"jsonrpc" => "2.0", "method" => "tools/list", "id" => 2}
      iex> is_initialize_lifecycle(other_message)
      false
  """
  defguard is_initialize_lifecycle(data)
           when (is_request(data) and :erlang.map_get("method", data) == "initialize") or
                  (is_notification(data) and
                     :erlang.map_get("method", data) == "notifications/initialized")

  # Version-aware schemas

  @doc """
  Returns the full request message schema for a protocol version module.

  Defaults to the latest registered protocol version.

  ## Examples

      iex> {:multi, :method, branches} = Message.request_schema(Anubis.Protocol.V2025_11_25)
      iex> Map.has_key?(branches, "tasks/get")
      true

      iex> {:multi, :method, branches} = Message.request_schema(Anubis.Protocol.V2025_03_26)
      iex> Map.has_key?(branches, "elicitation/create")
      false
  """
  @spec request_schema() :: term()
  def request_schema, do: request_schema(Registry.latest_module())

  @spec request_schema(module()) :: term()
  def request_schema(protocol_module), do: protocol_module.request_message_schema()

  @doc """
  Returns the full notification message schema for a protocol version module.

  Defaults to the latest registered protocol version.
  """
  @spec notification_schema() :: term()
  def notification_schema, do: notification_schema(Registry.latest_module())

  @spec notification_schema(module()) :: term()
  def notification_schema(protocol_module), do: protocol_module.notification_message_schema()

  @doc """
  Returns the Peri schema registered under `name`.

  Kept for backwards compatibility: these schemas used to be defined in this
  module and are now resolved from the latest registered protocol version.
  """
  @spec get_schema(atom()) :: term()
  def get_schema(:request_schema), do: request_schema()
  def get_schema(:notification_schema), do: notification_schema()
  def get_schema(:response_schema), do: @response_schema
  def get_schema(:error_schema), do: @error_schema
  def get_schema(:mcp_message_schema), do: mcp_message_schema(Registry.latest_module())

  def get_schema(:sampling_result_schema) do
    Registry.latest_module().request_result_schema("sampling/createMessage")
  end

  def get_schema(:elicitation_result_schema) do
    Registry.latest_module().request_result_schema("elicitation/create")
  end

  def get_schema(:sampling_response_schema) do
    result_response_schema(get_schema(:sampling_result_schema))
  end

  def get_schema(:elicitation_response_schema) do
    result_response_schema(get_schema(:elicitation_result_schema))
  end

  defp mcp_message_schema(protocol_module) do
    {:oneof,
     [
       request_schema(protocol_module),
       notification_schema(protocol_module),
       @response_schema,
       @error_schema
     ]}
  end

  defp result_response_schema(nil), do: @response_schema
  defp result_response_schema(result_schema), do: Map.put(@response_schema, "result", result_schema)

  @doc """
  Decodes raw data (possibly containing multiple messages) into JSON-RPC messages.

  Messages are validated against the latest registered protocol version.
  Returns either:
  - `{:ok, messages}` where messages is a list of parsed JSON-RPC messages
  - `{:error, reason}` if parsing fails
  """
  def decode(data), do: decode(data, Registry.latest_module())

  @doc """
  Decodes raw data, validating each message against the given protocol
  version module.

  Returns the same shapes as `decode/1`.
  """
  def decode(data, protocol_module) when is_binary(data) do
    data
    |> String.split("\n", trim: true)
    |> decode_lines(protocol_module)
  end

  defp decode_lines(lines, protocol_module) do
    lines
    |> Enum.flat_map(&decode_line/1)
    |> validate_all_messages(protocol_module)
  end

  defp decode_line(line) do
    case JSON.decode(line) do
      {:ok, message} when is_map(message) -> [message]
      {:ok, _} -> [{:invalid, :invalid_request}]
      {:error, _} -> [{:invalid, :parse_error}]
    end
  end

  defp validate_all_messages(messages, protocol_module) do
    messages
    |> Enum.reduce_while({:ok, []}, fn
      {:invalid, reason}, _acc ->
        {:halt, {:error, reason}}

      message, {:ok, acc} ->
        case validate_message(message, protocol_module) do
          {:ok, validated} -> {:cont, {:ok, [validated | acc]}}
          error -> {:halt, error}
        end
    end)
    |> case do
      {:ok, validated} -> {:ok, Enum.reverse(validated)}
      error -> error
    end
  end

  @doc """
  Validates a decoded JSON message against the latest registered protocol version.
  """
  def validate_message(message), do: validate_message(message, Registry.latest_module())

  @doc """
  Validates a decoded JSON message against the given protocol version module.

  A message whose method is not part of the version fails with
  `{:error, :method_not_found}`; malformed messages fail with
  `{:error, :invalid_request}`.
  """
  def validate_message(message, protocol_module) when is_map(message) do
    with :ok <- validate_jsonrpc_envelope(message),
         {:ok, validated} <- Peri.validate(mcp_message_schema(protocol_module), message) do
      {:ok, validated}
    else
      {:error, reason} when reason in [:invalid_request, :parse_error, :method_not_found] ->
        {:error, reason}

      {:error, _} ->
        classify_schema_failure(message, protocol_module)
    end
  end

  defp classify_schema_failure(message, protocol_module) do
    method = Map.get(message, "method")

    cond do
      jsonrpc_request_envelope?(message) and is_binary(method) and
          method not in protocol_module.request_methods() ->
        {:error, :method_not_found}

      is_notification(message) and is_binary(method) and
          method not in protocol_module.notification_methods() ->
        {:error, :method_not_found}

      true ->
        {:error, :invalid_request}
    end
  end

  defp validate_jsonrpc_envelope(message) when is_map(message) do
    cond do
      Map.get(message, "jsonrpc") != "2.0" ->
        {:error, :invalid_request}

      is_request(message) ->
        if is_binary(message["method"]), do: :ok, else: {:error, :invalid_request}

      is_notification(message) ->
        if is_binary(message["method"]), do: :ok, else: {:error, :invalid_request}

      is_response(message) or is_error(message) ->
        :ok

      true ->
        {:error, :invalid_request}
    end
  end

  defp jsonrpc_request_envelope?(message) when is_map(message) do
    Map.get(message, "jsonrpc") == "2.0" and is_request(message) and
      is_binary(message["method"])
  end

  @doc """
  Encodes a request message to a JSON-RPC 2.0 compliant string.

  The request is validated against the latest registered protocol version.
  Returns the encoded string with a newline character appended.
  """
  def encode_request(request, id) do
    encode_request(request, id, request_schema())
  end

  @doc """
  Encodes a request message using a custom schema.

  Use `request_schema/1` to derive the schema for a negotiated protocol
  version module.

  ## Parameters

    * `request` - The request map containing method and params
    * `id` - The request ID
    * `schema` - The Peri schema to use for validation

  Returns the encoded string with a newline character appended.
  """
  def encode_request(request, id, schema) do
    request
    |> Map.put("jsonrpc", "2.0")
    |> Map.put("id", id)
    |> encode_message(schema)
  end

  @doc """
  Encodes a notification message to a JSON-RPC 2.0 compliant string.

  The notification is validated against the latest registered protocol
  version. Returns the encoded string with a newline character appended.
  """
  def encode_notification(notification) do
    encode_notification(notification, notification_schema())
  end

  @doc """
  Encodes a notification message using a custom schema.

  Use `notification_schema/1` to derive the schema for a negotiated protocol
  version module.

  ## Parameters

    * `notification` - The notification map containing method and params
    * `schema` - The Peri schema to use for validation

  Returns the encoded string with a newline character appended.
  """
  def encode_notification(notification, schema) do
    notification
    |> Map.put("jsonrpc", "2.0")
    |> encode_message(schema)
  end

  @doc """
  Encodes a progress notification message to a JSON-RPC 2.0 compliant string.

  ## Parameters

    * `params` - Map containing progress parameters:
      * `"progressToken"` - The token that was provided in the original request (string or integer)
      * `"progress"` - The current progress value (number)
      * `"total"` - Optional total value for the operation (number)
      * `"message"` - Optional descriptive message (string, for 2025-03-26)
    * `params_schema` - Optional Peri schema for params validation (defaults to @progress_notif_params_schema)

  Returns the encoded string with a newline character appended.
  """
  @spec encode_progress_notification(map(), term() | nil) ::
          {:ok, String.t()} | {:error, term()}
  def encode_progress_notification(params, params_schema \\ @progress_notif_params_schema) when is_map(params) do
    # Validate params against the provided schema
    case Peri.validate(params_schema, params) do
      {:ok, validated_params} ->
        encode_notification(%{
          "method" => "notifications/progress",
          "params" => validated_params
        })

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Legacy function for progress notifications with individual parameters.

  **Deprecated**: Prefer using `encode_progress_notification/2` with a params map.

  This function will be removed in a future release. Update your code to use the newer function:

      encode_progress_notification(%{
        "progressToken" => progress_token,
        "progress" => progress,
        "total" => total
      })
  """
  @deprecated "Use encode_progress_notification/2 with a params map. This function will be removed in a future release."
  @spec encode_progress_notification(
          String.t() | integer(),
          number(),
          number() | nil
        ) ::
          {:ok, String.t()} | {:error, term()}
  def encode_progress_notification(progress_token, progress, total)
      when (is_binary(progress_token) or is_integer(progress_token)) and is_number(progress) do
    params = %{
      "progressToken" => progress_token,
      "progress" => progress
    }

    params = if total, do: Map.put(params, "total", total), else: params
    encode_progress_notification(params)
  end

  @doc """
  Encodes a response message to a JSON-RPC 2.0 compliant string.

  Returns the encoded string with a newline character appended.
  """
  def encode_response(response, id) do
    encode_response(response, id, @response_schema)
  end

  @doc """
  Encodes a sampling response, validating the result against the latest
  registered protocol version.
  """
  def encode_sampling_response(response, id) do
    encode_sampling_response(response, id, Registry.latest_module())
  end

  @doc """
  Encodes a sampling response, validating the result against the given
  protocol version module.
  """
  def encode_sampling_response(response, id, protocol_module) do
    result_schema = protocol_module.request_result_schema("sampling/createMessage")
    encode_response(response, id, result_response_schema(result_schema))
  end

  @doc """
  Encodes an elicitation response, validating the result against the latest
  registered protocol version.
  """
  def encode_elicitation_response(response, id) do
    encode_elicitation_response(response, id, Registry.latest_module())
  end

  @doc """
  Encodes an elicitation response, validating the result against the given
  protocol version module.
  """
  def encode_elicitation_response(response, id, protocol_module) do
    result_schema = protocol_module.request_result_schema("elicitation/create")
    encode_response(response, id, result_response_schema(result_schema))
  end

  @doc """
  Encodes a response message using a custom schema.

  ## Parameters

    * `response` - The response map containing result
    * `id` - The response ID
    * `schema` - The Peri schema to use for validation

  Returns the encoded string with a newline character appended.
  """
  def encode_response(response, id, schema) do
    response
    |> Map.put("jsonrpc", "2.0")
    |> Map.put("id", id)
    |> encode_message(schema)
  end

  @doc """
  Encodes an error message to a JSON-RPC 2.0 compliant string.

  Returns the encoded string with a newline character appended.
  """
  def encode_error(response, id) do
    response
    |> Map.put("jsonrpc", "2.0")
    |> Map.put("id", id)
    |> encode_message(@error_schema)
  end

  defp encode_message(data, schema) do
    encoder = {schema, {:transform, fn data -> JSON.encode!(data) <> "\n" end}}
    Peri.validate(encoder, data)
  end

  @doc """
  Encodes a log message notification to be sent to the client.

  ## Parameters

    * `level` - The log level (debug, info, notice, warning, error, critical, alert, emergency)
    * `data` - The data to be logged (any JSON-serializable value)
    * `logger` - Optional name of the logger issuing the message

  Returns the encoded notification string with a newline character appended.
  """
  @spec encode_log_message(String.t(), term(), String.t() | nil) ::
          {:ok, String.t()} | {:error, term()}
  def encode_log_message(level, data, logger \\ nil) when level in @log_levels do
    params = maybe_add_logger(%{"level" => level, "data" => data}, logger)

    encode_notification(%{
      "method" => "notifications/message",
      "params" => params
    })
  end

  defp maybe_add_logger(params, nil), do: params

  defp maybe_add_logger(params, logger) when is_binary(logger), do: Map.put(params, "logger", logger)

  @doc """
  Returns the progress notification parameters schema for 2025-03-26 (with message field).
  """
  def progress_params_schema_2025, do: @progress_notif_params_schema_2025

  @doc """
  Returns the standard progress notification parameters schema for 2024-11-05.
  """
  def progress_params_schema, do: @progress_notif_params_schema

  @doc """
  Returns the progress notification parameters schema for a given protocol version.

  Delegates to the version module via `Anubis.Protocol.Registry`.

  ## Examples

      iex> Message.progress_params_schema_for("2024-11-05")
      %{"progressToken" => {:required, {:either, {:string, :integer}}}, ...}

      iex> Message.progress_params_schema_for("2025-03-26")
      %{"progressToken" => ..., "message" => :string}
  """
  @spec progress_params_schema_for(String.t()) :: {:ok, map()} | :error
  def progress_params_schema_for(version) do
    Registry.progress_params_schema(version)
  end

  @doc """
  Builds a response message map without encoding to JSON.

  ## Examples

      iex> Message.build_response(%{"value" => 42}, "req_123")
      %{"jsonrpc" => "2.0", "result" => %{"value" => 42}, "id" => "req_123"}
  """
  @spec build_response(map(), String.t() | integer()) :: map()
  def build_response(result, id) do
    %{"jsonrpc" => "2.0", "result" => result, "id" => id}
  end

  @doc """
  Builds an error message map without encoding to JSON.

  ## Examples

      iex> Message.build_error(%{"code" => -32600, "message" => "Invalid Request"}, "req_123")
      %{"jsonrpc" => "2.0", "error" => %{"code" => -32600, "message" => "Invalid Request"}, "id" => "req_123"}
  """
  @spec build_error(map(), String.t() | integer() | nil) :: map()
  def build_error(error, id) do
    %{"jsonrpc" => "2.0", "error" => error, "id" => id}
  end

  @doc """
  Builds a notification message map without encoding to JSON.

  ## Examples

      iex> Message.build_notification("notifications/message", %{"level" => "info", "data" => "test"})
      %{"jsonrpc" => "2.0", "method" => "notifications/message", "params" => %{"level" => "info", "data" => "test"}}
  """
  @spec build_notification(String.t(), map()) :: map()
  def build_notification(method, params) do
    %{"jsonrpc" => "2.0", "method" => method, "params" => params}
  end
end
