defmodule Anubis.Server.Component do
  @moduledoc false

  alias Anubis.Server.Component.Prompt
  alias Anubis.Server.Component.Resource
  alias Anubis.Server.Component.Tool

  @doc false
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defmacro __using__(opts) when is_list(opts) do
    {type, opts} = Keyword.pop!(opts, :type)

    if type not in [:tool, :prompt, :resource] do
      raise ArgumentError,
            "Invalid component type: #{type}. Must be :tool, :prompt, or :resource"
    end

    behaviour_module = get_behaviour_module(type)

    title = Keyword.get(opts, :title)

    uri = Keyword.get(opts, :uri)
    uri_template = Keyword.get(opts, :uri_template)
    basename = if uri && type == :resource, do: Path.basename(uri)
    name = Keyword.get(opts, :name, basename)
    mime_type = Keyword.get(opts, :mime_type, "text/plain")
    annotations = Keyword.get(opts, :annotations)

    quote do
      @behaviour unquote(behaviour_module)

      import Anubis.Server.Component,
        only: [
          schema: 1,
          output_schema: 1,
          field: 3,
          field: 2,
          embeds_many: 3,
          embeds_many: 2,
          embeds_one: 3,
          embeds_one: 2
        ]

      import Anubis.Server.Frame

      @doc false
      def __mcp_component_type__, do: unquote(type)

      @doc false
      def __description__, do: @moduledoc

      if unquote(type) == :tool do
        if title = unquote(title) do
          @impl true
          def title, do: title
        end

        @impl true
        def input_schema do
          alias Anubis.Server.Component.Schema

          Schema.to_json_schema(__mcp_raw_schema__())
        end

        if unquote(annotations) != nil do
          @impl true
          def annotations, do: unquote(annotations)
        end
      end

      if unquote(type) == :prompt do
        if title = unquote(title) do
          @impl true
          def title, do: title
        end

        @impl true
        def arguments do
          alias Anubis.Server.Component.Schema

          Schema.to_prompt_arguments(__mcp_raw_schema__())
        end
      end

      if unquote(type) == :resource do
        if unquote(uri) do
          @impl true
          def uri, do: unquote(uri)
          defoverridable uri: 0
        end

        if unquote(uri_template) do
          @impl true
          def uri_template, do: unquote(uri_template)
          defoverridable uri_template: 0
        end

        @impl true
        def name, do: unquote(name)

        if title = unquote(title) do
          @impl true
          def title, do: title
        end

        @impl true
        def mime_type, do: unquote(mime_type)

        defoverridable mime_type: 0
      end
    end
  end

  @doc """
  Defines the parameter schema for the component.

  The schema uses Peri's validation DSL and is automatically validated
  before the component's callback is executed.
  """
  defmacro schema(do: schema_def) do
    wrapped_schema =
      case schema_def do
        {:%{}, _, _} = map_ast ->
          map_ast

        {:__block__, _, field_calls} ->
          {:%{}, [], field_calls}

        single_field ->
          {:%{}, [], [single_field]}
      end

    quote do
      import Peri

      alias Anubis.Server.Component

      @doc false
      def __mcp_raw_schema__, do: unquote(wrapped_schema)

      defschema(
        :mcp_schema,
        Component.__clean_schema_for_peri__(unquote(wrapped_schema))
      )
    end
  end

  @doc """
  Defines the output schema for a tool component.

  This schema describes the expected structure of the tool's output in the
  structuredContent field. Only available for tool components.
  """
  defmacro output_schema(do: schema_def) do
    wrapped_schema =
      case schema_def do
        {:%{}, _, _} = map_ast ->
          map_ast

        {:__block__, _, field_calls} ->
          {:%{}, [], field_calls}

        single_field ->
          {:%{}, [], [single_field]}
      end

    quote do
      import Peri

      alias Anubis.Server.Component

      @doc false
      def __mcp_output_schema__, do: unquote(wrapped_schema)

      defschema(
        :mcp_output_schema,
        Component.__clean_schema_for_peri__(unquote(wrapped_schema))
      )

      @impl true
      def output_schema do
        alias Anubis.Server.Component.Schema

        Schema.to_json_schema(__mcp_output_schema__())
      end
    end
  end

  @doc """
  Defines a field with metadata for JSON Schema generation.

  Supports both simple fields and nested objects with their own fields.

  ## Examples

      # Simple field
      field :email, {:required, :string}, format: "email", description: "User's email address"
      field :age, :integer, description: "Age in years"
      
      # Nested field
      field :user do
        field :name, {:required, :string}
        field :email, :string, format: "email"
      end

      # Nested field with metadata
      field :profile, description: "User profile information" do
        field :bio, :string, description: "Short biography"
        field :avatar_url, :string, format: "uri"
      end
  """
  defmacro field(name, type, opts \\ []) when not is_nil(type) and is_list(opts) do
    {required, remaining_opts} = Keyword.pop(opts, :required, false)
    type = if required, do: {:required, type}, else: type

    quote do
      {unquote(name), {:mcp_field, unquote(type), unquote(remaining_opts)}}
    end
  end

  @doc """
  Defines a field that embeds many objects (array of objects).

  ## Examples

      embeds_many :users, description: "List of users" do
        field :id, :string, required: true, description: "User ID"
        field :name, :string, description: "User name"
      end

      embeds_many :tags, required: true do
        field :name, :string, required: true
        field :value, :string
      end
  """
  defmacro embeds_many(name, opts \\ [], do: block) do
    {required, remaining_opts} = Keyword.pop(opts, :required, false)

    nested_content =
      case block do
        {:__block__, _, expressions} ->
          {:%{}, [], expressions}

        single_expr ->
          {:%{}, [], [single_expr]}
      end

    type = if required, do: {:required, {:list, nested_content}}, else: {:list, nested_content}

    quote do
      {unquote(name), {:mcp_field, unquote(type), unquote(remaining_opts)}}
    end
  end

  @doc """
  Defines a field that embeds one object.

  ## Examples

      embeds_one :user, description: "User object" do
        field :id, :string, required: true, description: "User ID"
        field :name, :string, description: "User name"
      end

      embeds_one :address, required: true do
        field :street, :string, required: true
        field :city, :string, required: true
        field :zip, :string
      end
  """
  defmacro embeds_one(name, opts \\ [], do: block) do
    {required, remaining_opts} = Keyword.pop(opts, :required, false)

    nested_content =
      case block do
        {:__block__, _, expressions} ->
          {:%{}, [], expressions}

        single_expr ->
          {:%{}, [], [single_expr]}
      end

    type = if required, do: {:required, nested_content}, else: nested_content

    quote do
      {unquote(name), {:mcp_field, unquote(type), unquote(remaining_opts)}}
    end
  end

  defp get_behaviour_module(:tool), do: Tool
  defp get_behaviour_module(:prompt), do: Prompt
  defp get_behaviour_module(:resource), do: Resource

  @doc """
  Extracts the description from a component module.

  ## Parameters
    * `module` - The component module atom

  ## Returns
    * The description from `description/0` callback if defined
    * Falls back to the module's `@moduledoc` if no callback is defined
    * Empty string if neither is defined

  ## Examples

      iex> defmodule MyTool do
      ...>   @moduledoc "A helpful tool"
      ...>   use Anubis.Server.Component, type: :tool
      ...> end
      iex> Anubis.Server.Component.get_description(MyTool)
      "A helpful tool"

      iex> defmodule MyToolWithCallback do
      ...>   @moduledoc "Default description"
      ...>   use Anubis.Server.Component, type: :tool
      ...>   def description, do: "Custom description from callback"
      ...> end
      iex> Anubis.Server.Component.get_description(MyToolWithCallback)
      "Custom description from callback"
  """
  def get_description(module) when is_atom(module) do
    description =
      cond do
        function_exported?(module, :description, 0) ->
          module.description()

        function_exported?(module, :__description__, 0) ->
          module.__description__()

        true ->
          ""
      end

    description || ""
  end

  @doc """
  Gets the component type (:tool, :prompt, or :resource).

  ## Parameters
    * `module` - The component module atom

  ## Returns
    * `:tool` - If the module is a tool component
    * `:prompt` - If the module is a prompt component
    * `:resource` - If the module is a resource component

  ## Examples

      iex> defmodule MyTool do
      ...>   use Anubis.Server.Component, type: :tool
      ...> end
      iex> Anubis.Server.Component.get_type(MyTool)
      :tool
  """
  def get_type(module) when is_atom(module) do
    module.__mcp_component_type__()
  end

  @doc """
  Checks if a module is a valid component.

  ## Parameters
    * `module` - The module atom to check

  ## Returns
    * `true` if the module uses `Anubis.Server.Component`
    * `false` otherwise

  ## Examples

      iex> defmodule MyTool do
      ...>   use Anubis.Server.Component, type: :tool
      ...> end
      iex> Anubis.Server.Component.component?(MyTool)
      true

      iex> defmodule NotAComponent do
      ...>   def hello, do: :world
      ...> end
      iex> Anubis.Server.Component.component?(NotAComponent)
      false
  """
  def component?(module) when is_atom(module) do
    not is_nil(get_type(module))
  end

  @doc false
  def __clean_schema_for_peri__(schema) when is_map(schema) do
    Map.new(schema, fn
      {key, {:mcp_field, type, opts}} -> {key, __convert_mcp_field_to_peri__(type, opts)}
      {key, nested} when is_map(nested) -> {key, __clean_schema_for_peri__(nested)}
      {key, value} -> {key, __inject_transforms__(value)}
    end)
  end

  def __clean_schema_for_peri__(schema), do: __inject_transforms__(schema)

  defp __convert_mcp_field_to_peri__(type, opts) do
    {constraints, metadata} = __extract_peri_constraints__(opts)

    # Extract base type and required flag
    {base_type, is_required} =
      case type do
        {:required, inner_type} -> {inner_type, true}
        inner_type -> {inner_type, false}
      end

    # Handle :enum type specially
    constrained_type =
      case base_type do
        :enum ->
          values = Keyword.get(metadata, :values, [])
          {:enum, values}

        _ ->
          # Normal constraint handling
          case constraints do
            [] -> base_type
            [single] -> {base_type, single}
            multiple -> {base_type, multiple}
          end
      end

    # Wrap with required if needed
    final_type =
      if is_required do
        {:required, constrained_type}
      else
        constrained_type
      end

    __inject_transforms__(final_type)
  end

  defp __extract_peri_constraints__(opts) do
    constraints =
      []
      |> maybe_add_constraint(opts, :min_length, :min)
      |> maybe_add_constraint(opts, :max_length, :max)
      |> maybe_add_constraint(opts, :regex, :regex)
      |> maybe_add_constraint(opts, :min, :gte)
      |> maybe_add_constraint(opts, :max, :lte)
      |> maybe_add_constraint(opts, :enum, :enum)
      |> Enum.reverse()

    # Keep :values in metadata for enum types, don't treat it as a constraint
    metadata = Keyword.drop(opts, [:min, :max, :min_length, :max_length, :regex, :enum])
    {constraints, metadata}
  end

  defp maybe_add_constraint(constraints, opts, opt_key, peri_key) do
    case Keyword.get(opts, opt_key) do
      nil -> constraints
      value -> [{peri_key, value} | constraints]
    end
  end

  defp __inject_transforms__({type, {:default, default}}) when type in ~w(date datetime naive_datetime time)a do
    base = __inject_transforms__(type)
    {base, {:default, default}}
  end

  defp __inject_transforms__(:date) do
    {:custom, &__validate_date__/1}
  end

  defp __inject_transforms__(:time) do
    {:custom, &__validate_time__/1}
  end

  defp __inject_transforms__(:datetime) do
    {:custom, &__validate_datetime__/1}
  end

  defp __inject_transforms__(:naive_datetime) do
    {:custom, &__validate_naive_datetime__/1}
  end

  defp __inject_transforms__({:required, type}) do
    {:required, __inject_transforms__(type)}
  end

  defp __inject_transforms__({:list, type}) do
    {:list, __inject_transforms__(type)}
  end

  defp __inject_transforms__(nested) when is_map(nested) do
    __clean_schema_for_peri__(nested)
  end

  defp __inject_transforms__(type), do: type

  defp __validate_date__(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> {:error, "invalid ISO 8601 date format", []}
    end
  end

  defp __validate_date__(%Date{} = date), do: {:ok, date}

  defp __validate_date__(_), do: {:error, "expected ISO 8601 date string or Date struct", []}

  defp __validate_time__(value) when is_binary(value) do
    case Time.from_iso8601(value) do
      {:ok, time} -> {:ok, time}
      {:error, _} -> {:error, "invalid ISO 8601 time format", []}
    end
  end

  defp __validate_time__(%Time{} = time), do: {:ok, time}

  defp __validate_time__(_), do: {:error, "expected ISO 8601 time string or Time struct", []}

  defp __validate_datetime__(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _} -> {:ok, datetime}
      {:error, _} -> {:error, "invalid ISO 8601 datetime format", []}
    end
  end

  defp __validate_datetime__(%DateTime{} = datetime), do: {:ok, datetime}

  defp __validate_datetime__(_), do: {:error, "expected ISO 8601 datetime string or DateTime struct", []}

  defp __validate_naive_datetime__(value) when is_binary(value) do
    # NaiveDateTime.from_iso8601 accepts Z suffix but we want to reject it
    if String.ends_with?(value, "Z") or String.match?(value, ~r/[+-]\d{2}:\d{2}$/) do
      {:error, "NaiveDateTime cannot have timezone information", []}
    else
      case NaiveDateTime.from_iso8601(value) do
        {:ok, naive_datetime} -> {:ok, naive_datetime}
        {:error, _} -> {:error, "invalid ISO 8601 naive datetime format", []}
      end
    end
  end

  defp __validate_naive_datetime__(%NaiveDateTime{} = naive_datetime), do: {:ok, naive_datetime}

  defp __validate_naive_datetime__(_), do: {:error, "expected ISO 8601 naive datetime string or NaiveDateTime struct", []}
end
