defmodule Hermes.Client.SessionManager do
  @moduledoc false

  use Hermes.Logging

  import Peri

  alias Hermes.Client.Session
  alias Hermes.MCP.ID
  alias Hermes.MCP.Error
  alias Hermes.MCP.Message
  alias Hermes.Protocol

  @default_protocol_version Protocol.latest_version()

  @type state :: :disconnected | :connected | :initializing | :initialized

  @type session_data :: %{
          state: state(),
          session: Session.t() | nil,
          client_info: map(),
          client_capabilities: map(),
          protocol_version: String.t(),
          initialize_request_id: String.t() | nil
        }

  @spec new(map()) :: session_data()
  def new(opts \\ %{}) do
    %{
      state: :disconnected,
      session: nil,
      client_info: opts[:client_info] || %{name: "hermes-mcp-client", version: "1.0.0"},
      client_capabilities: opts[:capabilities] || %{},
      protocol_version: opts[:protocol_version] || @default_protocol_version,
      initialize_request_id: nil
    }
  end

  @doc """
  Handles transport connection event.
  """
  @spec on_connected(session_data()) :: session_data()
  def on_connected(session_data) do
    %{session_data | state: :connected}
  end

  @doc """
  Initiates the initialization handshake with the server.

  Returns the initialize request message and updated session data.
  """
  @spec start_initialization(session_data()) ::
          {:ok, map(), session_data()} | {:error, Error.t()}
  def start_initialization(%{state: :connected} = session_data) do
    request_id = ID.generate_request_id()

    params = %{
      "protocolVersion" => session_data.protocol_version,
      "capabilities" => session_data.client_capabilities,
      "clientInfo" => session_data.client_info
    }

    case Message.encode_request("initialize", params, request_id) do
      {:ok, message} ->
        updated_data = %{
          session_data
          | state: :initializing,
            initialize_request_id: request_id
        }

        {:ok, message, updated_data}

      error ->
        error
    end
  end

  def start_initialization(%{state: state}) do
    {:error, Error.invalid_request("Cannot initialize from state: #{state}")}
  end

  @doc """
  Handles the initialize response from the server.

  Validates the response, extracts server info and capabilities, and creates
  the session object.
  """
  @spec handle_initialize_response(map(), session_data()) ::
          {:ok, Session.t(), session_data()} | {:error, Error.t()}
  def handle_initialize_response(response, %{state: :initializing} = session_data) do
    with :ok <- validate_initialize_response(response),
         {:ok, server_info} <- extract_server_info(response),
         {:ok, server_capabilities} <- extract_server_capabilities(response),
         {:ok, negotiated_version} <- negotiate_protocol_version(response, session_data) do
      session = %Session{
        # Will be true after sending initialized notification
        initialized: false,
        assigns: %{},
        private: %{
          session_id: ID.generate_request_id(),
          server_info: server_info,
          server_capabilities: server_capabilities,
          protocol_version: negotiated_version
        }
      }

      updated_data = %{
        session_data
        | session: session,
          protocol_version: negotiated_version
      }

      {:ok, session, updated_data}
    end
  end

  def handle_initialize_response(_response, %{state: state}) do
    {:error, Error.invalid_request("Unexpected initialize response in state: #{state}")}
  end

  @doc """
  Completes initialization by sending the initialized notification.

  Returns the initialized notification message and marks the session as initialized.
  """
  @spec complete_initialization(session_data()) ::
          {:ok, map(), Session.t(), session_data()} | {:error, Error.t()}
  def complete_initialization(%{session: session} = session_data) when session != nil do
    case Message.encode_notification("initialized", %{}) do
      {:ok, message} ->
        initialized_session = %{session | initialized: true}

        updated_data = %{
          session_data
          | state: :initialized,
            session: initialized_session
        }

        {:ok, message, initialized_session, updated_data}

      error ->
        error
    end
  end

  def complete_initialization(_) do
    {:error, Error.invalid_request("No session to complete initialization")}
  end

  @doc """
  Checks if the session is initialized and ready for operations.
  """
  @spec initialized?(session_data()) :: boolean()
  def initialized?(%{state: :initialized, session: %{initialized: true}}), do: true
  def initialized?(_), do: false

  @doc """
  Gets the current session if initialized.
  """
  @spec get_session(session_data()) :: {:ok, Session.t()} | {:error, :not_initialized}
  def get_session(%{state: :initialized, session: session}) when session != nil do
    {:ok, session}
  end

  def get_session(_) do
    {:error, :not_initialized}
  end

  @doc """
  Validates if a capability is supported by the server.
  """
  @spec validate_capability(session_data(), String.t()) :: :ok | {:error, Error.t()}
  def validate_capability(%{session: %{private: %{server_capabilities: caps}}}, capability) do
    if capability_supported?(caps, capability) do
      :ok
    else
      {:error, Error.invalid_request("Server does not support capability: #{capability}")}
    end
  end

  def validate_capability(_, _) do
    {:error, Error.invalid_request("Session not initialized")}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp validate_initialize_response(response) do
    # Validate response structure using Peri
    schema =
      defschema(%{
        "protocolVersion" => string(required: true),
        "capabilities" => map(required: true),
        "serverInfo" => map(required: true)
      })

    case Peri.validate(schema, response) do
      {:ok, _} ->
        :ok

      {:error, errors} ->
        {:error, Error.invalid_params("Invalid initialize response", %{errors: errors})}
    end
  end

  defp extract_server_info(response) do
    server_info = response["serverInfo"] || %{}

    schema =
      defschema(%{
        "name" => string(required: true),
        "version" => string(required: false)
      })

    case Peri.validate(schema, server_info) do
      {:ok, validated} ->
        {:ok, validated}

      {:error, errors} ->
        {:error, Error.invalid_params("Invalid server info", %{errors: errors})}
    end
  end

  defp extract_server_capabilities(response) do
    {:ok, response["capabilities"] || %{}}
  end

  defp negotiate_protocol_version(response, session_data) do
    server_version = response["protocolVersion"]
    client_version = session_data.protocol_version

    if server_version == client_version do
      {:ok, server_version}
    else
      {:error,
       Error.invalid_request(
         "Protocol version mismatch. Client: #{client_version}, Server: #{server_version}"
       )}
    end
  end

  defp capability_supported?(server_capabilities, capability) do
    # Parse capability path (e.g., "tools/call" -> ["tools", "call"])
    parts = String.split(capability, "/")

    # Navigate through the capability map
    get_in(server_capabilities, parts) != nil
  end
end
