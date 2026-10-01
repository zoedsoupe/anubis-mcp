defmodule StubTransport do
  @moduledoc """
  Simple mock transport for MCP protocol testing.
  Records all messages sent through it for inspection in tests.
  """

  @behaviour Anubis.Transport.Behaviour

  use GenServer

  alias Anubis.MCP.Builders
  alias Anubis.MCP.ID
  alias Anubis.MCP.Message
  alias Anubis.Server.Transport.Session

  require Message

  @type state :: %{
          messages: [String.t()],
          session_id: String.t(),
          test_pid: pid() | nil
        }

  @doc """
  Starts the mock transport.

  ## Options
  - `:name` - Process name (defaults to __MODULE__)
  """
  @impl true
  def start_link(opts \\ []) do
    state = %{messages: [], test_pid: nil}

    if name = opts[:name] do
      GenServer.start_link(__MODULE__, state, name: name)
    else
      GenServer.start_link(__MODULE__, state)
    end
  end

  @doc """
  Gets all messages sent through this transport.
  """
  def get_messages(transport \\ __MODULE__) do
    GenServer.call(transport, :get_messages)
  end

  @doc """
  Sets the test process to receive message notifications.
  """
  def set_test_pid(transport \\ __MODULE__, test_pid) do
    GenServer.call(transport, {:set_test_pid, test_pid})
  end

  @doc """
  Clears all recorded messages.
  """
  def clear(transport \\ __MODULE__) do
    GenServer.call(transport, :clear)
  end

  @impl true
  def send_message(transport \\ __MODULE__, message, _opts \\ []) do
    GenServer.call(transport, {:send_message, message})
  end

  @impl true
  def shutdown(transport \\ __MODULE__) do
    GenServer.call(transport, :shutdown)
  end

  @impl true
  def supported_protocol_versions, do: :all

  @impl true
  def init(state) do
    {:ok, Map.put(state, :session_id, ID.generate_session_id())}
  end

  @impl true
  def handle_call(:get_messages, _from, state) do
    {:reply, state.messages |> Enum.reverse() |> Enum.map(&decode_message/1), state}
  end

  def handle_call(:clear, _from, state) do
    {:reply, :ok, %{state | messages: []}}
  end

  def handle_call({:set_test_pid, test_pid}, _from, state) do
    {:reply, :ok, %{state | test_pid: test_pid}}
  end

  def handle_call({:send_message, message}, _from, state) do
    new_messages = [message | state.messages]

    if state.test_pid do
      send(state.test_pid, {:send_message, message})
    end

    if is_binary(message) do
      message = decode_message(message)
      forward_to_session(message, state)
    else
      forward_to_session(message, state)
    end

    {:reply, :ok, %{state | messages: new_messages}}
  end

  def handle_call(:shutdown, _from, state) do
    {:stop, :normal, :ok, state}
  end

  defp decode_message(message) when is_binary(message) do
    %{} = message = Builders.decode_message(message)
    message
  end

  defp forward_to_session(message, state) when Message.is_request(message) do
    if message["method"] in ~w(sampling/createMessage elicitation/create roots/list) do
      :ok
    else
      session_name =
        Anubis.Server.Registry.session_name(StubServer, state.session_id)

      {:ok, _response} = Session.dispatch_request(session_name, message, %{})
      :ok
    end
  end

  defp forward_to_session(message, state) when Message.is_response(message) or Message.is_error(message) do
    session_name =
      Anubis.Server.Registry.session_name(StubServer, state.session_id)

    Session.dispatch_response(session_name, message, %{})
  end

  defp forward_to_session(message, state) when Message.is_notification(message) do
    session_name =
      Anubis.Server.Registry.session_name(StubServer, state.session_id)

    :ok = Session.dispatch_notification(session_name, message, %{})
  end
end
