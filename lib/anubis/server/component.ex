defmodule Anubis.Server.Component do
  @moduledoc false

  alias Anubis.Server.Component.Prompt
  alias Anubis.Server.Component.Resource
  alias Anubis.Server.Component.Tool
  alias Anubis.Server.Component.URITemplate

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

    if (type == :resource and uri) && uri_template do
      raise ArgumentError,
            "Resource component cannot define both :uri and :uri_template (mutually exclusive)"
    end

    if type == :resource and uri_template do
      case URITemplate.parse(uri_template) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          raise ArgumentError, "Invalid :uri_template — #{reason}"
      end
    end

    basename = if uri && type == :resource, do: Path.basename(uri)
    name = Keyword.get(opts, :name, basename)
    mime_type = Keyword.get(opts, :mime_type, "text/plain")
    annotations = Keyword.get(opts, :annotations)
    meta = Keyword.get(opts, :meta)
    scopes = Keyword.get(opts, :scopes, [])

    if not (is_list(scopes) and Enum.all?(scopes, &is_binary/1)) do
      raise ArgumentError,
            "Component :scopes must be a list of strings, got: #{inspect(scopes)}"
    end

    task_support = Keyword.get(opts, :task_support)

    if type == :tool and task_support not in [nil, :forbidden, :optional, :required] do
      raise ArgumentError,
            "Invalid :task_support value #{inspect(task_support)} — must be one of :forbidden, :optional, :required"
    end

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

      @doc false
      def __scopes__, do: unquote(scopes)

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

        if unquote(meta) != nil do
          @impl true
          def meta, do: unquote(meta)
        end

        if unquote(task_support) != nil do
          @impl true
          def task_support, do: unquote(task_support)
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

        __mcp_output_schema__()
        |> Component.__make_optional_nullable__()
        |> Schema.to_json_schema()
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
    quote do
      {unquote(name), unquote(__MODULE__).__build_field__(unquote(type), unquote(opts))}
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
    nested_content =
      case block do
        {:__block__, _, expressions} ->
          {:%{}, [], expressions}

        single_expr ->
          {:%{}, [], [single_expr]}
      end

    type = quote do: {:list, unquote(nested_content)}

    quote do
      {unquote(name), unquote(__MODULE__).__build_field__(unquote(type), unquote(opts))}
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
    nested_content =
      case block do
        {:__block__, _, expressions} ->
          {:%{}, [], expressions}

        single_expr ->
          {:%{}, [], [single_expr]}
      end

    quote do
      {unquote(name), unquote(__MODULE__).__build_field__(unquote(nested_content), unquote(opts))}
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

  @meta_keys [
    :title,
    :description,
    :example,
    :examples,
    :deprecated,
    :format,
    :pattern,
    :read_only,
    :write_only,
    :content_encoding,
    :content_media_type
  ]

  # Peri-native list constraint keys (passed through verbatim to Peri encoder)
  @list_constraint_keys [:min, :max, :unique]

  # User-friendly string constraint aliases mapped to Peri keys
  @string_constraint_aliases %{min_length: :min, max_length: :max}

  # Peri-native string constraint keys (passed through verbatim)
  @string_constraint_keys [:min, :max, :regex, :eq]

  # User-friendly numeric constraint aliases mapped to Peri keys
  @numeric_constraint_aliases %{min: :gte, max: :lte}

  # Peri-native numeric constraint keys (passed through verbatim)
  @numeric_constraint_keys [:gt, :gte, :lt, :lte, :eq, :neq, :multiple_of, :range]

  @doc false
  # Builds a native Peri schema fragment from user-facing (type, opts).
  # Replaces the legacy {:mcp_field, type, opts} indirection.
  def __build_field__(type, opts) when is_list(opts) do
    {required_override, opts} = __pop_required_opt__(opts)
    {type, required_from_type} = __pop_required__(type)
    required = __resolve_required__(required_override, required_from_type)

    {type, opts} = __resolve_enum__(type, opts)
    {default_wrap, opts} = __pop_default__(opts)

    {meta, constraints} = __split_meta_constraints__(opts)
    base = __apply_constraints__(type, constraints)
    with_default = if default_wrap, do: {base, default_wrap}, else: base
    with_meta = if meta == [], do: with_default, else: {:meta, with_default, meta}

    if required, do: {:required, with_meta}, else: with_meta
  end

  # `:default` belongs in Peri's `{type, {:default, v}}` shape, not the meta
  # wrapper — pull it out before splitting meta/constraints so downstream
  # consumers (schema docs, JSON Schema, validators) find it where they expect.
  defp __pop_default__(opts) do
    case Keyword.fetch(opts, :default) do
      {:ok, v} -> {{:default, v}, Keyword.delete(opts, :default)}
      :error -> {nil, opts}
    end
  end

  # Explicit `required: <bool>` opt wins over the `{:required, t}` type wrapper,
  # so callers can opt out of a required type at runtime without rebuilding it.
  defp __pop_required_opt__(opts) do
    case Keyword.fetch(opts, :required) do
      {:ok, val} -> {{:set, val}, Keyword.delete(opts, :required)}
      :error -> {:unset, opts}
    end
  end

  defp __resolve_required__({:set, val}, _from_type), do: val
  defp __resolve_required__(:unset, from_type), do: from_type

  defp __pop_required__({:required, t}), do: {t, true}
  defp __pop_required__(t), do: {t, false}

  # Translates field-macro enum opts into Peri's typed enum form.
  # `field :role, :enum, values: [...], type: :string` →
  # `{:enum, [...], [type: :string]}`. Defaults type to `:string` when omitted.
  defp __resolve_enum__(:enum, opts) do
    {values, opts} = Keyword.pop(opts, :values)
    {enum_type, opts} = Keyword.pop(opts, :type, :string)

    if is_nil(values) do
      raise ArgumentError,
            "`:enum` field requires a `:values` option listing the allowed values"
    end

    {{:enum, values, [type: enum_type]}, opts}
  end

  # Bare-enum type with `type:` opt — promote to typed enum
  defp __resolve_enum__({:enum, values}, opts) when is_list(values) do
    case Keyword.pop(opts, :type) do
      {nil, opts} -> {{:enum, values}, opts}
      {enum_type, opts} -> {{:enum, values, [type: enum_type]}, opts}
    end
  end

  # Legacy 3-arity form {:enum, vals, type_atom} as type slot → keyword form
  defp __resolve_enum__({:enum, values, type}, opts) when is_list(values) and is_atom(type) do
    {{:enum, values, [type: type]}, Keyword.delete(opts, :type)}
  end

  # `field :env, :string, enum: [...]` → typed enum
  defp __resolve_enum__(type, opts) when is_atom(type) do
    case Keyword.pop(opts, :enum) do
      {nil, opts} -> {type, opts |> Keyword.delete(:values) |> Keyword.delete(:type)}
      {values, opts} -> {{:enum, values, [type: type]}, Keyword.delete(opts, :type)}
    end
  end

  defp __resolve_enum__(type, opts) do
    {type, opts |> Keyword.delete(:values) |> Keyword.delete(:type)}
  end

  defp __split_meta_constraints__(opts) do
    {meta, cons} =
      Enum.reduce(opts, {[], []}, fn
        {k, v}, {m, c} when k in @meta_keys -> {[{k, v} | m], c}
        {k, v}, {m, c} -> {m, [{k, v} | c]}
      end)

    {Enum.reverse(meta), Enum.reverse(cons)}
  end

  defp __apply_constraints__(type, []), do: type

  defp __apply_constraints__({:list, item}, opts) do
    list_opts =
      Enum.flat_map(opts, fn
        {k, _} = pair when k in @list_constraint_keys -> [pair]
        _ -> []
      end)

    if list_opts == [], do: {:list, item}, else: {:list, item, list_opts}
  end

  defp __apply_constraints__(:string, opts) do
    string_opts =
      Enum.flat_map(opts, fn
        {k, v} when is_map_key(@string_constraint_aliases, k) ->
          [{Map.fetch!(@string_constraint_aliases, k), v}]

        {k, _} = pair when k in @string_constraint_keys ->
          [pair]

        _ ->
          []
      end)

    __wrap_type_opts__(:string, string_opts)
  end

  defp __apply_constraints__(type, opts) when type in [:integer, :float] do
    num_opts =
      Enum.flat_map(opts, fn
        {k, v} when is_map_key(@numeric_constraint_aliases, k) ->
          [{Map.fetch!(@numeric_constraint_aliases, k), v}]

        {k, _} = pair when k in @numeric_constraint_keys ->
          [pair]

        _ ->
          []
      end)

    __wrap_type_opts__(type, num_opts)
  end

  defp __apply_constraints__(type, _opts), do: type

  defp __wrap_type_opts__(type, []), do: type
  defp __wrap_type_opts__(type, [single]), do: {type, single}
  defp __wrap_type_opts__(type, multi), do: {type, multi}

  @doc false
  # Walks a Peri schema and wraps every non-required field type in
  # `{:either, {type, nil}}` so JSON Schema output emits a oneOf with
  # `{"type": "null"}` allowed. Used for tool output schemas to match
  # Anthropic backend expectations (see issue #142). Required fields and
  # already-nullable fields are left untouched.
  def __make_optional_nullable__(schema) do
    schema
    |> __expand_user_input__()
    |> Peri.walk(fn
      {:field, k, {:required, _} = v} ->
        {:cont, {:field, k, v}}

      {:field, k, {:either, {_, nil}} = v} ->
        {:cont, {:field, k, v}}

      {:field, k, {:either, {nil, _}} = v} ->
        {:cont, {:field, k, v}}

      {:field, k, {:meta, {:either, {_, nil}}, _} = v} ->
        {:cont, {:field, k, v}}

      {:field, k, {:meta, {:either, {nil, _}}, _} = v} ->
        {:cont, {:field, k, v}}

      # Lift meta wrapper outside the union so description/title stay at the
      # field's top-level JSON schema, not buried inside a oneOf branch.
      {:field, k, {:meta, type, opts}} ->
        {:cont, {:field, k, {:meta, {:either, {type, nil}}, opts}}}

      {:field, k, v} ->
        {:cont, {:field, k, {:either, {v, nil}}}}

      other ->
        {:cont, other}
    end)
  end

  @doc false
  # Recursively translates user-friendly schema shapes into native Peri.
  # Handles runtime shorthand `{type, opts}`, `{:required, type, opts}`,
  # `{:object, fields, opts}`, `{:list, item, opts}`, nested maps.
  def __expand_user_input__(schema) when is_map(schema) do
    Map.new(schema, fn {k, v} -> {k, __expand_value__(v)} end)
  end

  def __expand_user_input__(other), do: other

  defp __expand_value__({:object, fields}) when is_map(fields) do
    __expand_user_input__(fields)
  end

  defp __expand_value__({:object, fields, opts}) when is_map(fields) and is_list(opts) do
    fields |> __expand_user_input__() |> __build_field__(opts)
  end

  defp __expand_value__({:required, {:object, fields}}) when is_map(fields) do
    {:required, __expand_user_input__(fields)}
  end

  defp __expand_value__({:required, {:object, fields, opts}}) when is_map(fields) and is_list(opts) do
    __build_field__({:required, __expand_user_input__(fields)}, opts)
  end

  defp __expand_value__({:required, type, opts}) when is_list(opts) do
    __build_field__({:required, __expand_inner__(type)}, opts)
  end

  defp __expand_value__({:list, item, opts}) when is_list(opts) do
    __build_field__({:list, __expand_value__(item)}, opts)
  end

  defp __expand_value__({:list, item}) do
    {:list, __expand_value__(item)}
  end

  defp __expand_value__({:required, type}) do
    {:required, __expand_inner__(type)}
  end

  # Legacy positional 3-arity {:enum, values, type_atom} → Peri keyword form
  defp __expand_value__({:enum, values, type}) when is_list(values) and is_atom(type) do
    {:enum, values, [type: type]}
  end

  # Peri-native bare/keyword enums — pass through
  defp __expand_value__({:enum, values}) when is_list(values), do: {:enum, values}

  # Peri-native list-of-types shapes — pass through
  defp __expand_value__({:oneof, types}) when is_list(types), do: {:oneof, types}
  defp __expand_value__({:tuple, types}) when is_list(types), do: {:tuple, types}

  # Runtime shorthand `{type, opts}` for atomic types
  defp __expand_value__({type, opts}) when is_atom(type) and is_list(opts) do
    __build_field__(type, opts)
  end

  defp __expand_value__(nested) when is_map(nested), do: __expand_user_input__(nested)

  defp __expand_value__(other), do: other

  defp __expand_inner__({:list, item}), do: {:list, __expand_value__(item)}
  defp __expand_inner__({:list, item, opts}) when is_list(opts), do: {:list, __expand_value__(item), opts}
  defp __expand_inner__(nested) when is_map(nested), do: __expand_user_input__(nested)
  defp __expand_inner__(other), do: other

  @doc false
  def __clean_schema_for_peri__(schema) when is_map(schema) do
    schema
    |> __expand_user_input__()
    |> __walk_inject__()
  end

  def __clean_schema_for_peri__(schema), do: __inject_transforms__(schema)

  defp __walk_inject__(schema) when is_map(schema) do
    Map.new(schema, fn {k, v} -> {k, __inject_transforms__(v)} end)
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

  defp __inject_transforms__({:meta, type, opts}) do
    {:meta, __inject_transforms__(type), opts}
  end

  defp __inject_transforms__({:list, type}) do
    {:list, __inject_transforms__(type)}
  end

  defp __inject_transforms__({:list, type, opts}) do
    {:list, __inject_transforms__(type), opts}
  end

  defp __inject_transforms__({:oneof, types}) when is_list(types) do
    {:oneof, Enum.map(types, &__inject_transforms__/1)}
  end

  defp __inject_transforms__({:tuple, types}) when is_list(types) do
    {:tuple, Enum.map(types, &__inject_transforms__/1)}
  end

  defp __inject_transforms__({:either, {a, b}}) do
    {:either, {__inject_transforms__(a), __inject_transforms__(b)}}
  end

  defp __inject_transforms__(nested) when is_map(nested) do
    __walk_inject__(nested)
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
