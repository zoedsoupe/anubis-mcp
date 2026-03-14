defmodule Anubis.Server do
  @moduledoc """
  Build MCP servers that extend language model capabilities.

  MCP servers are specialized processes that provide three core primitives to AI assistants:
  **Resources** (contextual data like files or schemas), **Tools** (actions the model can invoke),
  and **Prompts** (user-selectable templates). They operate in a secure, isolated architecture
  where clients maintain 1:1 connections with servers, enabling composable functionality while
  maintaining strict security boundaries.

  ## Quick Start

  Create a server in three steps:

      defmodule MyServer do
        use Anubis.Server,
          name: "my-server",
          version: "1.0.0",
          capabilities: [:tools]

        component MyServer.Calculator
      end

      defmodule MyServer.Calculator do
        @moduledoc "Add two numbers"

        use Anubis.Server.Component, type: :tool

        schema do
          field :a, :number, required: true
          field :b, :number, required: true
        end

        def execute(%{a: a, b: b}, _frame) do
          {:ok, a + b}
        end
      end

      # In your supervision tree
      children = [Anubis.Server.Registry, {MyServer, transport: :stdio}]
      Supervisor.start_link(children, strategy: :one_for_one)

  Your server is now a living process that AI assistants can connect to, discover available
  tools, and execute calculations through a secure protocol boundary.

  ## Capabilities

  Declare what your server can do:

  - **`:tools`** - Execute functions with structured inputs and outputs
  - **`:resources`** - Provide data that models can read (files, APIs, databases)
  - **`:prompts`** - Offer reusable templates for common interactions
  - **`:logging`** - Allow clients to configure verbosity levels

  Configure capabilities with options:

      use Anubis.Server,
        capabilities: [
          :tools,
          {:resources, subscribe?: true},      # Enable resource update subscriptions
          {:prompts, list_changed?: true}      # Notify when prompts change
        ]

  ## Components

  Register tools, resources, and prompts as components:

      component MyServer.FileReader           # Auto-named as "file_reader"
      component MyServer.ApiClient, name: "api"   # Custom name

  Components are modules that implement specific behaviors
  and are automatically discovered by clients through the protocol.

  ## Server Lifecycle

  Your server follows a predictable lifecycle with callbacks you can hook into:

  1. **`init/2`** - Set up initial state when the server starts
  2. **`handle_request/2`** - Process MCP protocol requests from clients
  3. **`handle_notification/2`** - React to one-way client messages
  4. **`handle_info/2`** - Bridge external events into MCP notifications

  Most protocol handling is automatic - you typically only implement `init/2` for setup
  and occasionally override other callbacks for custom behavior.

  ## Sending Notifications

  Notification functions use `send(self(), ...)` and must be called from within the
  Session process (i.e., inside callbacks). For sending from external processes or tasks,
  use `send/2` with the session PID directly.

      # Inside a callback:
      def handle_info(:data_changed, frame) do
        Anubis.Server.send_tools_list_changed()
        {:noreply, frame}
      end
  """

  alias Anubis.Server.Component
  alias Anubis.Server.Component.Prompt
  alias Anubis.Server.Component.Resource
  alias Anubis.Server.Component.Tool
  alias Anubis.Server.ConfigurationError
  alias Anubis.Server.Frame
  alias Anubis.Server.Handlers
  alias Anubis.Server.Response

  @server_capabilities ~w(prompts tools resources logging completion)a
  @protocol_versions Anubis.Protocol.Registry.supported_versions()

  @type request :: map()
  @type response :: map()
  @type notification :: map()
  @type mcp_error :: Anubis.MCP.Error.t()
  @type server_info :: map()
  @type server_capabilities :: map()

  @doc """
  Called after a client requests a `initialize` request.

  This callback is invoked while the MCP handshake starts and so the client may not sent
  the `notifications/initialized` message yet. For checking if the notification was already sent
  and the MCP handshake was successfully completed, you can check the `context.initialized` field
  in the frame.

  It receives the client's information and
  the current frame, allowing you to perform client-specific setup, validate capabilities,
  or prepare resources based on the connected client.
  """
  @callback init(client_info :: map(), Frame.t()) :: {:ok, Frame.t()}

  @doc """
  Handles a tool call request.

  This callback is invoked when a client calls a specific tool. It receives the tool name,
  the arguments provided by the client, and the current frame.
  """
  @callback handle_tool_call(name :: String.t(), arguments :: map(), Frame.t()) ::
              {:reply, result :: term(), Frame.t()}
              | {:error, mcp_error(), Frame.t()}

  @doc """
  Handles a resource read request.
  """
  @callback handle_resource_read(uri :: String.t(), Frame.t()) ::
              {:reply, content :: map(), Frame.t()}
              | {:error, mcp_error(), Frame.t()}

  @doc """
  Handles a prompt get request.
  """
  @callback handle_prompt_get(name :: String.t(), arguments :: map(), Frame.t()) ::
              {:reply, messages :: list(), Frame.t()}
              | {:error, mcp_error(), Frame.t()}

  @doc """
  Low-level handler for any MCP request.

  When implemented, it bypasses automatic routing to specific handlers.
  """
  @callback handle_request(request :: request(), state :: Frame.t()) ::
              {:reply, response :: response(), new_state :: Frame.t()}
              | {:noreply, new_state :: Frame.t()}
              | {:error, error :: mcp_error(), new_state :: Frame.t()}

  @doc """
  Handles incoming MCP notifications from clients.
  """
  @callback handle_notification(notification :: notification(), state :: Frame.t()) ::
              {:noreply, new_state :: Frame.t()}
              | {:error, error :: mcp_error(), new_state :: Frame.t()}

  @callback server_info :: server_info()
  @callback server_capabilities :: server_capabilities()
  @callback supported_protocol_versions() :: [String.t()]

  @callback handle_info(event :: term, Frame.t()) ::
              {:noreply, Frame.t()}
              | {:noreply, Frame.t(), timeout() | :hibernate | {:continue, arg :: term}}
              | {:stop, reason :: term, Frame.t()}

  @callback handle_call(request :: term, from :: GenServer.from(), Frame.t()) ::
              {:reply, reply :: term, Frame.t()}
              | {:reply, reply :: term, Frame.t(), timeout() | :hibernate | {:continue, arg :: term}}
              | {:noreply, Frame.t()}
              | {:noreply, Frame.t(), timeout() | :hibernate | {:continue, arg :: term}}
              | {:stop, reason :: term, reply :: term, Frame.t()}
              | {:stop, reason :: term, Frame.t()}

  @callback handle_cast(request :: term, Frame.t()) ::
              {:noreply, Frame.t()}
              | {:noreply, Frame.t(), timeout() | :hibernate | {:continue, arg :: term}}
              | {:stop, reason :: term, Frame.t()}

  @callback terminate(reason :: term, Frame.t()) :: term

  @callback handle_sampling(
              response :: map(),
              request_id :: String.t(),
              Frame.t()
            ) ::
              {:noreply, Frame.t()}
              | {:stop, reason :: term(), Frame.t()}

  @callback handle_completion(ref :: String.t(), argument :: map(), Frame.t()) ::
              {:reply, Response.t() | map(), Frame.t()}
              | {:error, mcp_error(), Frame.t()}

  @callback handle_roots(
              roots :: list(map()),
              request_id :: String.t(),
              Frame.t()
            ) ::
              {:noreply, Frame.t()}
              | {:stop, reason :: term(), Frame.t()}

  @optional_callbacks handle_notification: 2,
                      handle_info: 2,
                      handle_call: 3,
                      handle_cast: 2,
                      terminate: 2,
                      handle_tool_call: 3,
                      handle_resource_read: 2,
                      handle_prompt_get: 3,
                      handle_request: 2,
                      init: 2,
                      handle_sampling: 3,
                      handle_completion: 3,
                      handle_roots: 3

  @doc false
  defguard is_server_capability(capability) when capability in @server_capabilities

  @doc false
  defguard is_supported_capability(capabilities, capability)
           when is_map_key(capabilities, capability)

  @doc false
  defmacro __using__(opts) do
    quote do
      @behaviour Anubis.Server

      import Anubis.Server
      import Anubis.Server.Component, only: [field: 3]
      import Anubis.Server.Frame

      require Anubis.MCP.Message

      Module.register_attribute(__MODULE__, :components, accumulate: true)
      Module.register_attribute(__MODULE__, :anubis_server_opts, persist: true)
      Module.put_attribute(__MODULE__, :anubis_server_opts, unquote(opts))

      @before_compile Anubis.Server
      @after_compile Anubis.Server

      def child_spec(opts) do
        %{
          id: __MODULE__,
          start: {Anubis.Server.Supervisor, :start_link, [__MODULE__, opts]},
          type: :supervisor,
          restart: :permanent
        }
      end

      defoverridable child_spec: 1
    end
  end

  @doc """
  Registers a component (tool, prompt, or resource) with the server.
  """
  defmacro component(module, opts \\ []) do
    quote bind_quoted: [module: module, opts: opts] do
      if not Component.component?(module) do
        raise CompileError,
          description:
            "Module #{to_string(module)} is not a valid component. " <>
              "Use `use Anubis.Server.Component, type: :tool/:prompt/:resource`"
      end

      @components {Component.get_type(module), opts[:name] || Anubis.Server.__derive_component_name__(module), module}
    end
  end

  @doc false
  def __derive_component_name__(module) do
    defined? = Anubis.exported?(module, :name, 0)
    name = if defined?, do: module.name()

    if is_nil(name) do
      module
      |> Module.split()
      |> List.last()
      |> Macro.underscore()
    else
      name
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    components = Module.get_attribute(env.module, :components, [])
    opts = get_server_opts(env.module)

    quote do
      def __components__, do: Anubis.Server.parse_components(unquote(Macro.escape(components)))
      def __components__(:tool), do: Enum.filter(__components__(), &match?(%Tool{}, &1))
      def __components__(:prompt), do: Enum.filter(__components__(), &match?(%Prompt{}, &1))
      def __components__(:resource), do: Enum.filter(__components__(), &match?(%Resource{}, &1))

      @impl Anubis.Server
      def handle_request(%{} = request, frame) do
        Handlers.handle(request, __MODULE__, frame)
      end

      unquote(maybe_define_server_info(env.module, opts[:name], opts[:version]))
      unquote(maybe_define_server_capabilities(env.module, opts[:capabilities]))
      unquote(maybe_define_protocol_versions(env.module, opts[:protocol_versions]))

      defoverridable handle_request: 2
    end
  end

  @doc false
  def parse_components(components) when is_list(components) do
    components
    |> Enum.flat_map(&parse_components/1)
    |> Enum.sort_by(& &1.name)
  end

  def parse_components({:tool, name, mod}) do
    annotations = if Anubis.exported?(mod, :annotations, 0), do: mod.annotations()
    meta = if Anubis.exported?(mod, :meta, 0), do: mod.meta()
    output_schema = if Anubis.exported?(mod, :output_schema, 0), do: mod.output_schema()
    title = if Anubis.exported?(mod, :title, 0), do: mod.title(), else: name
    title = determine_tool_title(annotations, title)

    validate_output =
      if output_schema do
        fn params ->
          mod.__mcp_output_schema__()
          |> Component.__clean_schema_for_peri__()
          |> Peri.validate(params)
        end
      end

    if Anubis.exported?(mod, :input_schema, 0) do
      validate_input = fn params ->
        mod.__mcp_raw_schema__()
        |> Component.__clean_schema_for_peri__()
        |> Peri.validate(params)
      end

      [
        %Tool{
          name: name,
          title: title,
          description: Component.get_description(mod),
          input_schema: mod.input_schema(),
          output_schema: output_schema,
          annotations: annotations,
          meta: meta,
          handler: mod,
          validate_input: validate_input,
          validate_output: validate_output
        }
      ]
    else
      []
    end
  end

  def parse_components({:prompt, name, mod}) do
    title = if Anubis.exported?(mod, :title, 0), do: mod.title(), else: name

    if Anubis.exported?(mod, :arguments, 0) do
      validate_input = fn params ->
        mod.__mcp_raw_schema__()
        |> Component.__clean_schema_for_peri__()
        |> Peri.validate(params)
      end

      [
        %Prompt{
          name: name,
          title: title,
          description: Component.get_description(mod),
          arguments: mod.arguments(),
          handler: mod,
          validate_input: validate_input
        }
      ]
    else
      []
    end
  end

  def parse_components({:resource, name, mod}) do
    title = if Anubis.exported?(mod, :title, 0), do: mod.title(), else: name
    has_uri = Anubis.exported?(mod, :uri, 0)
    has_uri_template = Anubis.exported?(mod, :uri_template, 0)

    cond do
      has_uri ->
        [
          %Resource{
            uri: mod.uri(),
            name: name,
            title: title,
            description: Component.get_description(mod),
            mime_type: mod.mime_type(),
            handler: mod
          }
        ]

      has_uri_template ->
        [
          %Resource{
            uri_template: mod.uri_template(),
            name: name,
            title: title,
            description: Component.get_description(mod),
            mime_type: mod.mime_type(),
            handler: mod
          }
        ]

      true ->
        []
    end
  end

  defp determine_tool_title(%{"title" => title}, _) when is_binary(title), do: title
  defp determine_tool_title(%{title: title}, _) when is_binary(title), do: title
  defp determine_tool_title(_, title) when is_binary(title), do: title

  defp get_server_opts(module) do
    case Module.get_attribute(module, :anubis_server_opts, []) do
      [opts] when is_list(opts) -> opts
      opts when is_list(opts) -> opts
      _ -> []
    end
  end

  defp maybe_define_server_info(module, name, version) do
    if not Module.defines?(module, {:server_info, 0}) or is_nil(name) or
         is_nil(version) do
      quote do
        @impl Anubis.Server
        def server_info,
          do: %{"name" => unquote(name), "version" => unquote(version)}
      end
    end
  end

  defp maybe_define_server_capabilities(module, capabilities_config) do
    if not Module.defines?(module, {:server_capabilities, 0}) do
      capabilities = Enum.reduce(capabilities_config || [], %{}, &parse_capability/2)

      quote do
        @impl Anubis.Server
        def server_capabilities, do: unquote(Macro.escape(capabilities))
      end
    end
  end

  defp maybe_define_protocol_versions(module, protocol_versions) do
    if not Module.defines?(module, {:supported_protocol_versions, 0}) do
      versions = protocol_versions || @protocol_versions

      quote do
        @impl Anubis.Server
        def supported_protocol_versions, do: unquote(versions)
      end
    end
  end

  @doc false
  def parse_capability(capability, %{} = capabilities) when is_server_capability(capability) do
    Map.put(capabilities, to_string(capability), %{})
  end

  def parse_capability({:resources, opts}, %{} = capabilities) do
    subscribe? = opts[:subscribe?]
    list_changed? = opts[:list_changed?]

    resources_config =
      %{}
      |> then(&if(is_nil(subscribe?), do: &1, else: Map.put(&1, :subscribe, subscribe?)))
      |> then(&if(is_nil(list_changed?), do: &1, else: Map.put(&1, :listChanged, list_changed?)))

    Map.put(capabilities, "resources", resources_config)
  end

  def parse_capability({capability, opts}, %{} = capabilities) when is_server_capability(capability) do
    list_changed? = opts[:list_changed?]

    capability_config = if is_nil(list_changed?), do: %{}, else: %{listChanged: list_changed?}

    Map.put(capabilities, to_string(capability), capability_config)
  end

  @doc false
  def __after_compile__(env, _bytecode) do
    module = env.module

    opts =
      case Module.get_attribute(module, :anubis_server_opts, []) do
        [opts] when is_list(opts) -> opts
        opts when is_list(opts) -> opts
        _ -> []
      end

    name = opts[:name]
    version = opts[:version]

    if not Module.defines?(env.module, {:server_info, 0}) do
      validate_server_info!(module, name, version)
    end
  end

  @doc false
  def validate_server_info!(module, nil, nil) do
    raise ConfigurationError, module: module, missing_key: :both
  end

  def validate_server_info!(module, nil, _) do
    raise ConfigurationError, module: module, missing_key: :name
  end

  def validate_server_info!(module, _, nil) do
    raise ConfigurationError, module: module, missing_key: :version
  end

  def validate_server_info!(_, name, version) when is_binary(name) and is_binary(version), do: :ok

  # Notification Functions — all use send(self(), ...) to the current Session process

  @doc """
  Sends a resources list changed notification.

  **Must be called from within a Session callback** — the current process must be
  the Session GenServer. Calling from outside a callback will silently lose the message.

  For external processes, use `send(session_pid, {:send_notification, "notifications/resources/list_changed", %{}})`.
  """
  @spec send_resources_list_changed :: :ok
  def send_resources_list_changed do
    send(self(), {:send_notification, "notifications/resources/list_changed", %{}})
    :ok
  end

  @doc """
  Sends a resource updated notification for a specific resource.

  **Must be called from within a Session callback** — see `send_resources_list_changed/0` for details.
  """
  @spec send_resource_updated(uri :: String.t(), timestamp :: DateTime.t() | nil) :: :ok
  def send_resource_updated(uri, timestamp \\ nil) do
    params = %{"uri" => uri}
    params = if timestamp, do: Map.put(params, "timestamp", timestamp), else: params
    send(self(), {:send_notification, "notifications/resources/updated", params})
    :ok
  end

  @doc """
  Sends a prompts list changed notification.

  **Must be called from within a Session callback** — see `send_resources_list_changed/0` for details.
  """
  @spec send_prompts_list_changed :: :ok
  def send_prompts_list_changed do
    send(self(), {:send_notification, "notifications/prompts/list_changed", %{}})
    :ok
  end

  @doc """
  Sends a tools list changed notification.

  **Must be called from within a Session callback** — see `send_resources_list_changed/0` for details.
  """
  @spec send_tools_list_changed :: :ok
  def send_tools_list_changed do
    send(self(), {:send_notification, "notifications/tools/list_changed", %{}})
    :ok
  end

  @doc """
  Sends a log message to the client.

  **Must be called from within a Session callback** — see `send_resources_list_changed/0` for details.
  """
  @spec send_log_message(level :: Logger.level(), message :: String.t(), metadata :: map() | nil) :: :ok
  def send_log_message(level, message, data \\ nil) do
    params = %{"level" => level, "message" => message}
    params = if data, do: Map.put(params, "data", data), else: params
    send(self(), {:send_notification, "notifications/log/message", params})
    :ok
  end

  @type progress_token :: String.t() | non_neg_integer
  @type progress_step :: number
  @type progress_total :: number

  @doc """
  Sends a progress notification for an ongoing operation.
  """
  @spec send_progress(progress_token, progress_step, opts) :: :ok
        when opts: list({:total, progress_total} | {:message, String.t()})
  def send_progress(progress_token, progress, opts \\ []) do
    total = opts[:total]
    message = opts[:message]
    params = %{"progressToken" => progress_token, "progress" => progress}
    params = if total, do: Map.put(params, "total", total), else: params
    params = if message, do: Map.put(params, "message", message), else: params
    send(self(), {:send_notification, "notifications/progress", params})
    :ok
  end

  @doc """
  Sends a sampling/createMessage request to the client.

  This is an asynchronous operation. The response will be delivered to your
  `handle_sampling/3` callback.
  """
  @spec send_sampling_request(list(map()), configuration) :: :ok
        when configuration:
               list(
                 {:model_preferences, map() | nil}
                 | {:system_prompt, String.t() | nil}
                 | {:max_tokens, non_neg_integer() | nil}
                 | {:timeout, non_neg_integer() | nil}
               )
  def send_sampling_request(messages, opts \\ []) when is_list(messages) do
    params = %{"messages" => messages}

    params =
      opts
      |> Keyword.take([:model_preferences, :system_prompt, :max_tokens])
      |> Enum.reduce(params, fn
        {:model_preferences, prefs}, acc -> Map.put(acc, "modelPreferences", prefs)
        {:system_prompt, prompt}, acc -> Map.put(acc, "systemPrompt", prompt)
        {:max_tokens, max}, acc -> Map.put(acc, "maxTokens", max)
      end)

    timeout = Keyword.get(opts, :timeout, 30_000)
    send(self(), {:send_sampling_request, params, timeout})
    :ok
  end

  @doc """
  Sends a roots/list request to the client.
  """
  @spec send_roots_request(list({:timeout, non_neg_integer() | nil})) :: :ok
  def send_roots_request(opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    send(self(), {:send_roots_request, timeout})
    :ok
  end
end
