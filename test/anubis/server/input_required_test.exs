defmodule Anubis.Server.InputRequiredTest do
  use Anubis.MCP.Case, async: false

  alias Anubis.Server.Component
  alias Anubis.Server.Frame
  alias Anubis.Server.InputRequired
  alias Anubis.Server.Registry
  alias Anubis.Server.RequestState
  alias Anubis.Server.Session

  @moduletag capture_log: true

  @version "2026-07-28"
  @secret String.duplicate("s", 32)
  @name_schema %{"type" => "object", "properties" => %{"name" => %{"type" => "string"}}, "required" => ["name"]}

  defmodule GreetTool do
    @moduledoc false
    use Component, type: :tool

    alias Anubis.Server.Response

    schema do
    end

    @impl true
    def execute(_params, frame) do
      case Frame.input_response(frame, "user_name") do
        %{"action" => "accept", "content" => %{"name" => name}} ->
          {:reply, Response.text(Response.tool(), "Hello, #{name}"), frame}

        _not_answered ->
          schema = %{"type" => "object", "properties" => %{"name" => %{"type" => "string"}}, "required" => ["name"]}
          {:reply, InputRequired.elicit(InputRequired.new(), "user_name", "Your name?", schema), frame}
      end
    end
  end

  defmodule WizardTool do
    @moduledoc false
    use Component, type: :tool

    alias Anubis.Server.Response

    schema do
    end

    @impl true
    def execute(_params, frame) do
      case {Frame.request_state(frame), Frame.input_responses(frame)} do
        {nil, _} -> {:reply, ask("step1", 1), frame}
        {%{step: 1}, %{"step1" => _}} -> {:reply, ask("step2", 2), frame}
        {%{step: 2}, %{"step2" => _}} -> {:reply, Response.text(Response.tool(), "state-ok"), frame}
      end
    end

    defp ask(key, step) do
      InputRequired.new()
      |> InputRequired.elicit(key, "Go on?", %{"type" => "object"})
      |> InputRequired.state(%{step: step})
    end
  end

  defmodule AskTool do
    @moduledoc false
    use Component, type: :tool

    alias Anubis.Server.Response

    schema do
    end

    @impl true
    def execute(_params, frame) do
      cond do
        Frame.input_responses(frame) != %{} ->
          {:reply, Response.text(Response.tool(), "answered"), frame}

        Frame.client_supports?(frame, "sampling") ->
          sample = %{"messages" => [], "maxTokens" => 10}
          {:reply, InputRequired.sample(InputRequired.new(), "answer", sample), frame}

        true ->
          {:reply, InputRequired.elicit(InputRequired.new(), "answer", "Answer?", %{"type" => "object"}), frame}
      end
    end
  end

  defmodule EmptyTool do
    @moduledoc false
    use Component, type: :tool

    schema do
    end

    @impl true
    def execute(_params, frame), do: {:reply, InputRequired.new(), frame}
  end

  defmodule ContextPrompt do
    @moduledoc false
    use Component, type: :prompt

    alias Anubis.Server.Response

    schema do
    end

    @impl true
    def get_messages(_params, frame) do
      case Frame.input_response(frame, "user_context") do
        %{"content" => %{"context" => context}} ->
          {:reply, Response.user_message(Response.prompt(), "Use #{context}"), frame}

        _not_answered ->
          {:reply, InputRequired.elicit(InputRequired.new(), "user_context", "Context?", %{"type" => "object"}), frame}
      end
    end
  end

  defmodule DraftResource do
    @moduledoc false
    use Component, type: :resource, uri: "notes://draft", mime_type: "text/plain"

    alias Anubis.Server.Response

    @impl true
    def read(_params, frame) do
      case Frame.input_response(frame, "unlock") do
        %{"action" => "accept"} ->
          {:reply, Response.text(Response.resource(), "draft body"), frame}

        _not_answered ->
          {:reply, InputRequired.elicit(InputRequired.new(), "unlock", "Unlock?", %{"type" => "object"}), frame}
      end
    end
  end

  defmodule InputServer do
    @moduledoc false

    use Anubis.Server,
      name: "input-server",
      version: "1.0.0",
      capabilities: [:tools, :prompts, :resources],
      protocol_versions: ["2026-07-28", "2025-11-25"]

    component(GreetTool, name: "greet")
    component(WizardTool, name: "wizard")
    component(AskTool, name: "ask")
    component(EmptyTool, name: "empty")
    component(ContextPrompt, name: "context_prompt")
    component(DraftResource, name: "draft")
  end

  setup do
    Application.put_env(:anubis_mcp, :request_state_secret, @secret)

    on_exit(fn ->
      Application.delete_env(:anubis_mcp, :request_state_secret)
      Application.delete_env(:anubis_mcp, :request_state_ttl)
    end)

    %{session: start_session()}
  end

  describe "tools/call" do
    test "asks through an elicitation, then completes with the answer", %{session: session} do
      assert %{"resultType" => "input_required", "inputRequests" => requests} = result = call(session, "greet")
      refute Map.has_key?(result, "requestState")

      assert %{
               "user_name" => %{
                 "method" => "elicitation/create",
                 "params" => %{"mode" => "form", "message" => "Your name?", "requestedSchema" => @name_schema}
               }
             } = requests

      answer = %{"user_name" => %{"action" => "accept", "content" => %{"name" => "Ada"}}}
      assert %{"resultType" => "complete", "content" => [%{"text" => "Hello, Ada"}]} = call(session, "greet", answer)
    end

    test "asks again when the answer is missing, misnamed or not an object", %{session: session} do
      for responses <- [%{}, %{"other" => %{"action" => "accept"}}, %{"user_name" => "Ada"}] do
        assert %{"resultType" => "input_required"} = call(session, "greet", responses)
      end
    end

    test "ignores responses it did not ask for", %{session: session} do
      answer = %{
        "user_name" => %{"action" => "accept", "content" => %{"name" => "Ada"}},
        "extra" => %{"anything" => true}
      }

      assert %{"content" => [%{"text" => "Hello, Ada"}]} = call(session, "greet", answer)
    end

    test "carries a signed state across rounds", %{session: session} do
      r1 = call(session, "wizard")
      assert %{"resultType" => "input_required", "requestState" => state1} = r1

      r2 = call(session, "wizard", %{"step1" => %{"action" => "accept"}}, state: state1)
      assert %{"resultType" => "input_required", "requestState" => state2} = r2
      assert state2 != state1

      assert %{"content" => [%{"text" => "state-ok"}]} =
               call(session, "wizard", %{"step2" => %{"action" => "accept"}}, state: state2)
    end

    test "offers what the client supports, and refuses a request it cannot answer", %{session: session} do
      assert %{"inputRequests" => %{"answer" => %{"method" => "sampling/createMessage"}}} =
               call(session, "ask", nil, capabilities: %{"sampling" => %{}})

      assert %{"code" => -32_021, "data" => %{"requiredCapabilities" => %{"elicitation" => %{}}}} =
               error(session, "ask", nil, capabilities: %{})
    end

    test "fails a result that asks for nothing", %{session: session} do
      assert %{"code" => -32_603} = error(session, "empty")
    end
  end

  describe "a requestState" do
    test "that was tampered with is refused before the tool runs", %{session: session} do
      %{"requestState" => state} = call(session, "wizard")
      tampered = String.slice(state, 0..-3//1) <> "AA"

      assert %{"code" => -32_602} = error(session, "wizard", %{"step1" => %{}}, state: tampered)
    end

    test "issued for another tool is refused", %{session: session} do
      %{"requestState" => state} = call(session, "wizard")

      assert %{"code" => -32_602} = error(session, "greet", %{}, state: state)
    end

    test "issued to another principal is refused", %{session: session} do
      %{"requestState" => state} = call(session, "wizard", nil, auth: %{sub: "alice"})

      assert %{"code" => -32_602} = error(session, "wizard", %{"step1" => %{}}, state: state, auth: %{sub: "mallory"})
    end

    test "past its TTL is refused", %{session: session} do
      Application.put_env(:anubis_mcp, :request_state_ttl, 0)
      %{"requestState" => state} = call(session, "wizard")

      assert %{"code" => -32_602} = error(session, "wizard", %{"step1" => %{}}, state: state)
    end
  end

  describe "prompts/get and resources/read" do
    test "a prompt asks for input and completes with it", %{session: session} do
      assert %{"resultType" => "input_required"} = request(session, "prompts/get", %{"name" => "context_prompt"})

      params = %{"name" => "context_prompt", "inputResponses" => %{"user_context" => %{"content" => %{"context" => "x"}}}}
      assert %{"resultType" => "complete", "messages" => [_ | _]} = request(session, "prompts/get", params)
    end

    test "a resource asks for input and completes with it", %{session: session} do
      assert %{"resultType" => "input_required"} = request(session, "resources/read", %{"uri" => "notes://draft"})

      params = %{"uri" => "notes://draft", "inputResponses" => %{"unlock" => %{"action" => "accept"}}}
      assert %{"contents" => [%{"text" => "draft body"}]} = request(session, "resources/read", params)
    end
  end

  describe "the handshake era" do
    test "does not receive an InputRequiredResult" do
      session = start_session()
      init = init_request("2025-11-25", %{"name" => "Legacy", "version" => "1.0.0"})
      {:ok, _} = GenServer.call(session, {:mcp_request, init, %{}})
      GenServer.cast(session, {:mcp_notification, build_notification("notifications/initialized"), %{}})
      :sys.get_state(session)

      message = %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/call", "params" => %{"name" => "greet"}}
      {:ok, response} = GenServer.call(session, {:mcp_request, message, %{}})

      assert %{"error" => %{"code" => -32_603}} = JSON.decode!(response)
    end
  end

  describe "RequestState" do
    test "refuses strings it did not sign" do
      frame = Frame.new()

      for token <- ["", "v1", "v1.a.b", "v2.AAAA.AAAA", "not a token"] do
        assert {:error, :invalid} = RequestState.verify(token, frame, {"tools/call", "wizard"})
      end
    end

    test "cannot sign without a secret" do
      Application.delete_env(:anubis_mcp, :request_state_secret)

      assert_raise ArgumentError, ~r/request_state_secret/, fn ->
        RequestState.sign(:state, Frame.new(), {"tools/call", "wizard"})
      end
    end
  end

  test "InputRequired names the capabilities its requests need" do
    input =
      InputRequired.new()
      |> InputRequired.elicit("a", "?", %{})
      |> InputRequired.sample("b", %{})
      |> InputRequired.list_roots("c")

    assert InputRequired.required_capabilities(input) == %{"elicitation" => %{}, "sampling" => %{}, "roots" => %{}}
  end

  defp call(session, tool, responses \\ nil, opts \\ []) do
    request(session, "tools/call", tool_params(tool, responses, opts), opts)
  end

  defp error(session, tool, responses \\ nil, opts \\ []) do
    %{"error" => error} = dispatch(session, "tools/call", tool_params(tool, responses, opts), opts)
    error
  end

  defp tool_params(tool, responses, opts) do
    %{"name" => tool, "arguments" => %{}}
    |> then(&if(responses, do: Map.put(&1, "inputResponses", responses), else: &1))
    |> then(&if(opts[:state], do: Map.put(&1, "requestState", opts[:state]), else: &1))
  end

  defp request(session, method, params, opts \\ []) do
    assert %{"result" => result} = dispatch(session, method, params, opts)
    result
  end

  defp dispatch(session, method, params, opts) do
    meta = %{
      "io.modelcontextprotocol/protocolVersion" => @version,
      "io.modelcontextprotocol/clientInfo" => %{"name" => "Tester", "version" => "1.0.0"},
      "io.modelcontextprotocol/clientCapabilities" => Keyword.get(opts, :capabilities, %{"elicitation" => %{}})
    }

    message = %{
      "jsonrpc" => "2.0",
      "id" => System.unique_integer([:positive]),
      "method" => method,
      "params" => Map.put(params, "_meta", meta)
    }

    context = if auth = opts[:auth], do: %{auth: auth}, else: %{}
    {:ok, response} = GenServer.call(session, {:mcp_request, message, context})
    JSON.decode!(response)
  end

  defp start_session do
    session_id = "input-#{System.unique_integer([:positive])}"
    transport_name = Registry.transport_name(InputServer, StubTransport)
    start_supervised({StubTransport, name: transport_name}, id: transport_name)

    task_sup = Registry.task_supervisor_name(InputServer)
    start_supervised({Task.Supervisor, name: task_sup}, id: task_sup)

    start_supervised!(
      {Session,
       session_id: session_id,
       server_module: InputServer,
       name: Registry.session_name(InputServer, session_id),
       transport: [layer: StubTransport, name: transport_name],
       task_supervisor: task_sup},
      id: session_id
    )
  end
end
