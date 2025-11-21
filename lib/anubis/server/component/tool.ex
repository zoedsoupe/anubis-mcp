defmodule Anubis.Server.Component.Tool do
  @moduledoc """
  Defines the behaviour for MCP tools.

  Tools are functions that can be invoked by the client with specific parameters.
  Each tool must define its name, description, and parameter schema, as well as
  implement the execution logic.

  ## Example

      defmodule MyServer.Tools.Calculator do
        @behaviour Anubis.Server.Behaviour.Tool
        
        alias Anubis.Server.Frame
        
        @impl true
        def name, do: "calculator"
        
        @impl true
        def description, do: "Performs basic arithmetic operations"
        
        @impl true
        def input_schema do
          %{
            "type" => "object",
            "properties" => %{
              "operation" => %{
                "type" => "string",
                "enum" => ["add", "subtract", "multiply", "divide"]
              },
              "a" => %{"type" => "number"},
              "b" => %{"type" => "number"}
            },
            "required" => ["operation", "a", "b"]
          }
        end
        
        @impl true
        def execute(%{"operation" => "add", "a" => a, "b" => b}, frame) do
          result = a + b
          
          # Can access frame assigns
          user_id = frame.assigns[:user_id]
          
          # Can return updated frame if needed
          new_frame = Frame.assign(frame, :last_calculation, result)
          
          {:ok, result, new_frame}
        end
        
        @impl true
        def execute(%{"operation" => "divide", "a" => a, "b" => 0}, _frame) do
          {:error, "Cannot divide by zero"}
        end
      end
  """

  alias Anubis.MCP.Error
  alias Anubis.Server.Frame
  alias Anubis.Server.Response

  @type params :: map()
  @type result :: term()
  @type schema :: map()
  @type annotations :: map() | nil

  @type t :: %__MODULE__{
          name: String.t(),
          title: String.t() | nil,
          description: String.t() | nil,
          input_schema: map | nil,
          output_schema: map | nil,
          annotations: map | nil,
          handler: module | nil,
          validate_input: (map -> {:ok, map} | {:error, [Peri.Error.t()]}) | nil,
          validate_output: (map -> {:ok, map} | {:error, [Peri.Error.t()]}) | nil
        }

  defstruct [
    :name,
    title: nil,
    description: nil,
    input_schema: nil,
    output_schema: nil,
    annotations: nil,
    handler: nil,
    validate_input: nil,
    validate_output: nil
  ]

  @doc """
  Returns the JSON Schema for the tool's input parameters.

  This schema is used to validate client requests and generate documentation.
  The schema should follow the JSON Schema specification.
  """
  @callback input_schema() :: schema()

  @doc """
  Returns the JSON Schema for the tool's output structure.

  This schema defines the expected structure of the tool's output in the
  structuredContent field. The schema should follow the JSON Schema specification.
  This is an optional callback.
  """
  @callback output_schema() :: schema()

  @doc """
  Returns the title that identifies this resource.

  Intended for UI and end-user contexts — optimized to be human-readable and easily understood,
  even by those unfamiliar with domain-specific terminology.

  If not provided, the name should be used for display, except if annotations.title is
  defined, which takes precedence over `name` and `title`.
  """
  @callback title() :: String.t()

  @doc """
  Returns the description of this tool.

  The description helps AI assistants understand what the tool does and when to use it.
  If not provided, the module's `@moduledoc` will be used automatically.

  ## Examples

      def description do
        "Performs arithmetic operations on two numbers"
      end

      # With dynamic content
      def description do
        interval = Application.get_env(:my_app, :cache_minutes, 15)
        "Fetches data (cached for \#{interval} minutes)"
      end
  """
  @callback description() :: String.t()

  @doc """
  Returns optional annotations for the tool.

  Annotations provide additional metadata about the tool that may be used
  by clients for enhanced functionality. This is an optional callback.

  ## Examples

      def annotations do
        %{
          "confidence" => 0.95,
          "category" => "text-processing",
          "tags" => ["nlp", "text"]
        }
      end
  """
  @callback annotations() :: annotations()

  @doc """
  Executes the tool with the given parameters.

  ## Parameters

  - `params` - The validated input parameters from the client
  - `frame` - The server frame containing:
    - `assigns` - Custom data like session_id, client_info, user permissions
    - `initialized` - Whether the server has been initialized

  ## Return Values

  - `{:ok, result}` - Tool executed successfully, frame unchanged
  - `{:ok, result, new_frame}` - Tool executed successfully with frame updates
  - `{:error, reason}` - Tool failed with the given reason

  ## Frame Usage

  The frame provides access to server state and context:

      def execute(params, frame) do
        # Access assigns
        user_id = frame.assigns[:user_id]
        permissions = frame.assigns[:permissions]
        
        # Update frame if needed
        new_frame = Frame.assign(frame, :last_tool_call, DateTime.utc_now())
        
        {:ok, "Result", new_frame}
      end
  """
  @callback execute(params :: params(), frame :: Frame.t()) ::
              {:reply, response :: Response.t(), new_state :: Frame.t()}
              | {:noreply, new_state :: Frame.t()}
              | {:error, error :: Error.t(), new_state :: Frame.t()}

  @optional_callbacks annotations: 0, output_schema: 0, title: 0, description: 0

  defimpl JSON.Encoder, for: __MODULE__ do
    alias Anubis.Server.Component.Tool

    def encode(%Tool{} = tool, _) do
      %{
        "name" => tool.name,
        "description" => tool.description,
        "inputSchema" => tool.input_schema
      }
      |> then(&if t = tool.title, do: Map.put(&1, "title", t), else: &1)
      |> then(&if os = tool.output_schema, do: Map.put(&1, "outputSchema", os), else: &1)
      |> then(&if a = tool.annotations, do: Map.put(&1, "annotations", a), else: &1)
      |> JSON.encode!()
    end
  end
end
