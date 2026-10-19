defmodule Peri do
  import Peri.Error, only: [summarize: 1]

  @moduledoc (Path.expand("../README.md", __DIR__)
              |> File.read!()
              |> String.split("<!-- moduledoc:start -->")
              |> List.last()
              |> String.split("<!-- moduledoc:end -->")
              |> List.first()) <>
               """
               ## Guides

                 * [Schema types and directives](types.md): the full type vocabulary,
                   basic and time types, collections, enums, literals, constraints,
                   coercion/encoding, `{:meta, ...}`, custom error messages, schema
                   transformation with `Peri.walk/2`
                 * [Validation semantics](validation.md): strict/permissive modes,
                   `:cond` and `:dependent` callbacks and their arities, custom
                   validators, error context, decoding and encoding wire data
                 * [Data generation](generation.md): `Peri.generate/1`, constraint-aware
                   generators, `gen:` overrides, property-based testing
                 * [JSON Schema export](json_schema.md): `Peri.to_json_schema/1`
                 * [Ecto integration](ecto.md): changesets and custom Ecto types
                 * [Phoenix integration](phoenix.md): form and params bridging
                 * [Schema refs](refs.md): reusable named schemas via `{:ref, ...}`
               """

  @type validation :: (term -> validation_result)
  @type validation_result :: :ok | {:error, template :: String.t(), context :: map | keyword}
  @type string_option ::
          {:regex, Regex.t()} | {:eq, String.t()} | {:min, integer} | {:max, integer}
  @type numeric_option(type) ::
          {:eq, type}
          | {:neq, type}
          | {:lt, type}
          | {:lte, type}
          | {:gt, type}
          | {:gte, type}
          | {:range, {min :: type, max :: type}}
  @type time_def :: :time | :date | :datetime | :naive_datetime | :duration
  @type string_def :: :string | {:string, string_option | list(string_option)}
  @type int_def :: :integer | {:integer, numeric_option(integer) | list(numeric_option(integer))}
  @type float_def :: :float | {:float, numeric_option(float) | list(numeric_option(float))}
  @type default_def ::
          {schema_def, {:default, term}}
          | {schema_def, {:default, (-> term)}}
          | {schema_def, {:default, {module, atom}}}
  @type transform_def ::
          {schema_def, {:transform, (term -> term) | (term, term -> term)}}
          | {schema_def, {:transform, {module, atom}}}
          | {schema_def, {:transform, {module, atom, list(term)}}}
  @type custom_def ::
          {:custom, validation}
          | {:custom, {module, atom}}
          | {:custom, {module, atom, list(term)}}
  @type coerce_source ::
          :string
          | (term -> {:ok, term} | :error)
          | {module, atom}
          | {module, atom, list(term)}
  @type coerce_def ::
          {:coerce, schema_def}
          | {:coerce, schema_def, keyword}
          | {:coerce, coerce_source, schema_def}
          | {:coerce, coerce_source, schema_def, keyword}
  @type encode_def ::
          {schema_def, {:encode, (term -> term)}}
          | {schema_def, {:encode, {module, atom}}}
          | {schema_def, {:encode, {module, atom, list(term)}}}
  @type cond_def ::
          {:cond, condition :: (term -> boolean), true_branch :: schema_def,
           else_branch :: schema_def}
          | {:cond, condition :: (current :: term, root :: term -> boolean),
             true_branch :: schema_def, else_branch :: schema_def}
  @type dependent_def ::
          {:dependent, field :: atom, validation, type :: schema_def}
          | {:dependent,
             (term ->
                {:ok, schema_def | nil}
                | {:error, template :: String.t(), context :: map | keyword})}
          | {:dependent,
             (current :: term, root :: term ->
                {:ok, schema_def | nil}
                | {:error, template :: String.t(), context :: map | keyword})}
          | {:dependent, {module, fun :: atom}}
          | {:dependent, {module, fun :: atom, args :: list}}
  @type explicit_schema_def ::
          {:schema, schema}
          | {:schema, map_schema, {:additional_keys, schema_def}}
  @type literal :: integer | float | atom | String.t() | boolean
  @type schema_def ::
          :any
          | :atom
          | :atom!
          | :boolean
          | :map
          | :pid
          | {:either, {schema_def, schema_def}}
          | {:oneof, list(schema_def)}
          | {:required, schema_def}
          | {:meta, schema_def, keyword}
          | {:ref, atom}
          | {:ref, {module, atom}}
          | {:multi, atom, %{optional(term) => schema_def}}
          | {:enum, list(term)}
          | {:enum, list(term), keyword}
          | {:list, schema_def}
          | {:map, schema_def}
          | {:map, key_type :: schema_def, value_type :: schema_def}
          | {:tuple, list(schema_def)}
          | {:literal, literal}
          | time_def
          | string_def
          | int_def
          | float_def
          | default_def
          | transform_def
          | custom_def
          | coerce_def
          | encode_def
  @type map_schema :: %{(String.t() | atom) => schema_def}
  @type schema ::
          schema_def
          | map_schema
          | [{atom, schema_def}]

  @doc """
  Defines a schema with a given name and schema definition.

  ## Examples

      defmodule MySchemas do
        import Peri

        defschema :user, %{
          name: :string,
          age: :integer,
          email: {:required, :string}
        }

        # With permissive mode
        defschema :flexible_user, %{
          name: :string,
          email: {:required, :string}
        }, mode: :permissive

        # With metadata (field-level and schema-level)
        defschema :documented_user, %{
          email: {:meta, {:required, :string}, doc: "Login email", example: "a@b.io"}
        }, title: "User", description: "Account holder"
      end

      # Schema-level metadata is accessible via __schema_meta__/1:
      MySchemas.__schema_meta__(:documented_user)
      # => [title: "User", description: "Account holder"]

      user_data = %{name: "John", age: 30, email: "john@example.com"}
      MySchemas.user(user_data)
      # => {:ok, %{name: "John", age: 30, email: "john@example.com"}}

      invalid_data = %{name: "John", age: 30}
      MySchemas.user(invalid_data)
      # => {:error, [email: "is required"]}

      # Permissive mode preserves extra fields
      flexible_data = %{name: "John", email: "john@example.com", role: "admin"}
      MySchemas.flexible_user(flexible_data)
      # => {:ok, %{name: "John", email: "john@example.com", role: "admin"}}
  """
  @validation_opts [:mode]

  defmacro defschema(name, schema, opts \\ []) do
    bang = :"#{name}!"
    {validation_opts, meta_opts} = Keyword.split(opts, @validation_opts)
    schema = rewrite_local_refs(schema)

    quote do
      def get_schema(unquote(name)) do
        unquote(schema)
      end

      def __schema_meta__(unquote(name)) do
        unquote(meta_opts)
      end

      if Code.ensure_loaded?(Ecto) do
        def unquote(:"#{name}_changeset")(data) do
          Peri.to_changeset!(unquote(schema), data)
        end
      end

      def unquote(name)(data) do
        with {:ok, schema} <- Peri.validate_schema(unquote(schema)) do
          Peri.validate(schema, data, unquote(validation_opts))
        end
      end

      def unquote(bang)(data) do
        with {:ok, valid_schema} <- Peri.validate_schema(unquote(schema)),
             {:ok, valid_data} <- Peri.validate(valid_schema, data, unquote(validation_opts)) do
          valid_data
        else
          {:error, errors} -> raise Peri.InvalidSchema, errors
        end
      end
    end
  end

  # Rewrites `{:ref, atom}` to `{:ref, {__MODULE__, atom}}` at macro expansion
  # so local refs resolve against the calling module without forcing users to
  # spell out the module name. Cross-module refs `{:ref, {Mod, name}}` pass
  # through unchanged.
  defp rewrite_local_refs(ast) do
    Macro.prewalk(ast, fn
      {:ref, name} when is_atom(name) and name not in [:ref] ->
        quote do: {:ref, {__MODULE__, unquote(name)}}

      other ->
        other
    end)
  end

  @doc """
  Checks if the given data is an enumerable, specifically a map or a list.

  ## Parameters

    - `data`: The data to check.

  ## Examples

      iex> is_enumerable(%{})
      true

      iex> is_enumerable([])
      true

      iex> is_enumerable(123)
      false

      iex> is_enumerable("string")
      false
  """
  defguard is_enumerable(data) when is_map(data) or is_list(data)

  @doc """
  Checks if the given data conforms to the specified schema.

  ## Parameters

    - `schema`: The schema definition to validate against.
    - `data`: The data to be validated.

  ## Options

    - `:mode` - Validation mode. Can be `:strict` (default) or `:permissive`.
      - `:strict` - Only fields defined in the schema are returned.
      - `:permissive` - All fields from the input data are preserved.

  ## Returns

    - `true` if the data conforms to the schema.
    - `false` if the data does not conform to the schema.

  ## Examples

      iex> schema = %{name: :string, age: :integer}
      iex> data = %{name: "Alice", age: 30}
      iex> Peri.conforms?(schema, data)
      true

      iex> invalid_data = %{name: "Alice", age: "thirty"}
      iex> Peri.conforms?(schema, invalid_data)
      false
  """
  def conforms?(schema, data, opts \\ []) do
    mode = Keyword.get(opts, :mode, :strict)

    case validate(schema, data, mode: mode) do
      {:ok, _} -> true
      {:error, _errors} -> false
    end
  end

  @doc """
  Converts a Peri schema into a JSON Schema (Draft 7) map.

  Reads `{:meta, type, opts}` annotations and emits `title`, `description`,
  `examples`, `deprecated`. Dynamic types degrade per `:on_unsupported`
  (`:omit | :true_schema | :raise`, default `:omit`).

  Pass `:exclude_meta_keys` to drop annotation keywords from the output —
  commonly `[:default]` when the consumer-facing schema should not surface
  validation defaults.

  ## Examples

      iex> Peri.to_json_schema(%{name: {:required, :string}})
      %{"type" => "object", "properties" => %{"name" => %{"type" => "string"}}, "required" => ["name"]}

      iex> Peri.to_json_schema({:integer, {:default, 0}}, exclude_meta_keys: [:default])
      %{"type" => "integer"}
  """
  @spec to_json_schema(schema, Peri.JSONSchema.Encoder.opts()) :: map
  defdelegate to_json_schema(schema, opts \\ []), to: Peri.JSONSchema.Encoder, as: :encode

  @doc """
  Decodes a JSON Schema (Draft 7) map into a Peri schema.

  Returns `{:ok, schema}` if the resulting Peri schema is valid, otherwise
  `{:error, errors}`.
  """
  @spec from_json_schema(map, list(opt)) :: {:ok, schema} | {:error, term}
        when opt: {:keys, :strings | :atoms | :atoms!}
  defdelegate from_json_schema(json_schema, opts \\ []), to: Peri.JSONSchema.Decoder, as: :decode

  @doc """
  Depth-first rewrite of a schema tree.

  The callback is invoked on every subtree (pre-order). It must return either
  `{:cont, new_node}` to replace the node and continue, or `:drop` to remove it
  (only valid for values inside a map or keyword schema).

  Building block for transforms like "make every field optional" or "strip
  internal-only fields from a public DTO". See `Peri.Walker` for details.

  ## Examples

      iex> schema = %{name: {:required, :string}, age: {:required, :integer}}
      iex> Peri.walk(schema, fn
      ...>   {:required, t} -> {:cont, t}
      ...>   other -> {:cont, other}
      ...> end)
      %{name: :string, age: :integer}
  """
  @spec walk(schema, Peri.Walker.walker_fun()) :: schema
  defdelegate walk(schema, fun), to: Peri.Walker

  if Code.ensure_loaded?(StreamData) do
    @doc """
    Generates sample data based on the given schema definition using `StreamData`.

    This function validates the schema first, and if the schema is valid, it uses the
    `Peri.Generatable.gen/1` function to generate data according to the schema.

    Note that this function returns a `Stream`, so you traverse easily the data generations.

    ## Parameters

      - `schema`: The schema definition to generate data for.

    ## Returns

      - `{:ok, stream}` if the data is successfully generated.
      - `{:error, errors}` if there are validation errors in the schema.

    ## Examples

        iex> schema = %{name: :string, age: {:integer, {:range, {18, 65}}}}
        iex> {:ok, stream} = Peri.generate(schema)
        iex> [data] = Enum.take(stream, 1)
        iex> is_map(data)
        true
        iex> data[:age] in 18..65
        true

    """
    def generate(schema) do
      with {:ok, schema} <- validate_schema(schema) do
        {:ok, Peri.Generatable.gen(schema)}
      end
    end
  end

  @doc """
  Validates a given data map against a schema with options.

  Returns `{:ok, data}` if the data is valid according to the schema, or `{:error, errors}` if there are validation errors.

  ## Parameters

    - schema: The schema definition map.
    - data: The data map to be validated.
    - opts: Options for validation.

  ## Options

    - `:mode` - Validation mode. Can be `:strict` (default) or `:permissive`.
      - `:strict` - Only fields defined in the schema are returned.
      - `:permissive` - All fields from the input data are preserved.

  ## Examples

      schema = %{name: :string, age: :integer}
      data = %{name: "John", age: 30, extra: "field"}

      # Strict mode (default)
      Peri.validate(schema, data)
      # => {:ok, %{name: "John", age: 30}}

      # Permissive mode
      Peri.validate(schema, data, mode: :permissive)
      # => {:ok, %{name: "John", age: 30, extra: "field"}}
  """
  def validate(schema, data, opts \\ [])

  def validate(schema, data, opts) when is_enumerable(schema) and is_enumerable(data) do
    mode = Keyword.get(opts, :mode, :strict)

    if mode not in [:strict, :permissive] do
      raise ArgumentError, "Invalid mode: #{inspect(mode)}. Must be :strict or :permissive"
    end

    spellcheck = collect_spellcheck(schema, data)

    field_opts =
      [
        mode: mode,
        spellcheck: spellcheck,
        spellcheck_candidates: Map.get(spellcheck, [], [])
      ] ++ Keyword.take(opts, [:direction])

    data = filter_data(schema, data, field_opts)
    state = Peri.Parser.new(data, root_data: data)

    case traverse_schema(schema, state, field_opts) do
      %Peri.Parser{errors: [], data: result} -> {:ok, result}
      %Peri.Parser{errors: errors} -> {:error, errors}
    end
  end

  def validate(schema, data, opts) do
    case validate_field(data, schema, data, opts) do
      :ok ->
        {:ok, data}

      {:ok, result} ->
        {:ok, result}

      {:error, errors} ->
        {:error, errors}

      {:error, reason, info} ->
        {:error, Peri.Error.new_single(reason, info)}
    end
  end

  @doc """
  Decodes wire data against a schema.

  Coercion is a schema directive, so decoding is exactly `validate/3`:
  `{:coerce, source, target}` fields convert their `source` representation
  into the `target` type, and values already matching the target pass through
  unchanged.

  Accepts the same options as `validate/3` and returns the same shape.

  ## Examples

      iex> schema = %{page: {:coerce, :string, :integer}}
      iex> Peri.decode(schema, %{"page" => "2"})
      {:ok, %{page: 2}}

      iex> schema = %{page: {:coerce, :string, :integer}}
      iex> Peri.decode(schema, %{page: 2})
      {:ok, %{page: 2}}
  """
  @spec decode(schema, data :: term, keyword) :: {:ok, term} | {:error, term}
  def decode(schema, data, opts \\ []), do: validate(schema, data, opts)

  @doc """
  Encodes data against a schema, producing its wire representation.

  Validates `data` against the schema (target types), then applies the
  reverse of each codec directive:

    * `{:coerce, source, target}` - built-in `:string` sources render with
      `to_string/1` (`to_iso8601/1` for date/time structs); when the
      `encode:` opt is given, that function/MFA is applied instead. Custom
      function/MFA sources without an `encode:` opt pass the validated value
      through unchanged.
    * `{type, {:encode, fun}}` - applies `fun` (or MFA) to the validated
      value. This directive is inert under `validate/3` and `decode/3`.
    * `{:transform, fun}` - skipped; transforms are decode-only.

  Accepts the same options as `validate/3` and returns the same shape.

  ## Examples

      iex> schema = %{page: {:coerce, :string, :integer}}
      iex> Peri.encode(schema, %{page: 2})
      {:ok, %{page: "2"}}

      iex> schema = %{upcased: {:string, {:encode, &String.downcase/1}}}
      iex> Peri.encode(schema, %{upcased: "HELLO"})
      {:ok, %{upcased: "hello"}}
  """
  @spec encode(schema, data :: term, keyword) :: {:ok, term} | {:error, term}
  def encode(schema, data, opts \\ []) do
    validate(schema, data, Keyword.put(opts, :direction, :encode))
  end

  @doc """
  Helper function to put a value into an enum, handling
  not only maps and keyword lists but also structs.

  ## Examples

      iex> Peri.put_in_enum(%{}, :hello, "world")
      iex> Peri.put_in_enum(%{}, "hello", "world")
      iex> Peri.put_in_enum(%User{}, :hello, "world")
      iex> Peri.put_in_enum([], :hello, "world")
  """
  def put_in_enum(enum, key, val) when is_struct(enum) do
    struct(enum, %{key => val})
  end

  def put_in_enum(enum, key, val) when is_map(enum) do
    put_in(enum, [Access.key(key)], val)
  end

  def put_in_enum(enum, key, val) when is_list(enum) do
    put_in(enum[key], val)
  end

  # if data is struct, well, we do not need to filter it
  defp filter_data(_schema, data, _opts) when is_struct(data), do: data

  defp filter_data(schema, data, opts) do
    mode = Keyword.get(opts, :mode, :strict)

    if mode == :permissive do
      data
    else
      acc = make_filter_data_accumulator(schema, data)
      result = Enum.reduce(schema, acc, &do_filter_data(data, &1, &2, opts))
      if is_list(result), do: Enum.reverse(result), else: result
    end
  end

  defp do_filter_data(data, {key, {:meta, type, _meta_opts}}, acc, opts) do
    do_filter_data(data, {key, type}, acc, opts)
  end

  defp do_filter_data(data, {key, type}, acc, opts) do
    string_key = to_string(key)
    value = get_enumerable_value(data, key)
    original_key = if enumerable_has_key?(data, key), do: key, else: string_key

    cond do
      is_enumerable(data) and not enumerable_has_key?(data, key) ->
        acc

      is_enumerable(value) and is_enumerable(type) ->
        nested_filtered_value = filter_data(type, value, opts)
        put_in_enum(acc, original_key, nested_filtered_value)

      true ->
        put_in_enum(acc, original_key, value)
    end
  end

  defp make_filter_data_accumulator(schema, _data) when is_map(schema), do: %{}
  defp make_filter_data_accumulator(schema, _data) when is_list(schema), do: []

  defp enumerable_has_key?(data, key) when is_struct(data) do
    !!get_in(data, [Access.key(key)])
  end

  defp enumerable_has_key?(data, key) when is_map(data) and is_binary(key) do
    Map.has_key?(data, key)
  end

  defp enumerable_has_key?(data, key) when is_map(data) and is_atom(key) do
    Map.has_key?(data, key) or enumerable_has_key?(data, Atom.to_string(key))
  end

  defp enumerable_has_key?(data, key) when is_list(data) do
    Keyword.has_key?(data, key)
  end

  @doc false
  defp traverse_schema(schema, %Peri.Parser{} = state, opts, path \\ []) do
    Enum.reduce(schema, state, fn {key, type}, parser ->
      exists? = enumerable_has_key?(parser.data, key)
      value = if exists?, do: get_enumerable_value(parser.data, key)
      parser = Peri.Parser.for_field(parser, key, exists?)

      case validate_field(value, type, parser, opts) do
        :ok ->
          parser

        {:ok, value} ->
          Peri.Parser.update_data(parser, key, value)

        {:error, [_ | _] = nested_errs} ->
          reduce_errors(path, key, nested_errs, parser)

        {:error, reason, info} ->
          {reason, info} = maybe_suggest_key(reason, info, key, type, exists?, opts)
          err = Peri.Error.new_child(path, key, reason, info)
          Peri.Parser.add_error(parser, err)
      end
    end)
  end

  # When a required field is missing, suggest a typo'd sibling key present in
  # the data but absent from the schema (e.g. `:emial` for `:email`).
  # Candidates are computed from the unfiltered data and threaded through
  # opts under `:spellcheck_candidates`, so this works in both strict and
  # permissive modes.
  defp maybe_suggest_key(reason, info, key, {:required, _}, false, opts),
    do: suggest_key(reason, info, key, opts)

  defp maybe_suggest_key(reason, info, key, {:required, _, _}, false, opts),
    do: suggest_key(reason, info, key, opts)

  defp maybe_suggest_key(reason, info, _key, _type, _exists?, _opts), do: {reason, info}

  defp suggest_key(reason, info, key, opts) do
    candidates = Keyword.get(opts, :spellcheck_candidates, [])
    key_string = to_string(key)
    distance = &String.jaro_distance(to_string(&1), key_string)

    candidate =
      candidates
      |> Enum.filter(&(distance.(&1) > 0.8))
      |> Enum.max_by(distance, fn -> nil end)

    if candidate do
      {reason <> " did you mean %{did_you_mean}?", info ++ [did_you_mean: candidate]}
    else
      {reason, info}
    end
  end

  # Keys present in the data but absent from the schema, in their original
  # (atom or string) form. Compared as strings so string-keyed data matches
  # against atom-keyed schemas. Keys that are neither atoms nor strings
  # (PIDs, tuples, ...) can't be typo suggestions, so they're skipped.
  defp spellcheck_candidates(schema, data) do
    schema_keys = MapSet.new(enum_keys(schema))

    data
    |> enum_keys()
    |> Enum.reject(fn key ->
      key == :__struct__ or not spellcheckable_key?(key) or
        MapSet.member?(schema_keys, to_string(key))
    end)
  end

  defp spellcheckable_key?(key), do: is_atom(key) or is_binary(key)

  defp enum_keys(enum) do
    Enum.flat_map(enum, fn
      {key, _} -> [key]
      _other -> []
    end)
  end

  # Walks the raw schema and data (before strict-mode filtering drops
  # unknown keys) collecting spellcheck candidates per absolute path, so
  # nested schemas can suggest typo'd keys too. Structs are opaque input,
  # so they collect nothing.
  defp collect_spellcheck(_schema, data) when is_struct(data), do: %{}
  defp collect_spellcheck(schema, data), do: do_collect_spellcheck(schema, data, [], %{})

  defp do_collect_spellcheck(schema, data, path, acc) do
    acc =
      case spellcheck_candidates(schema, data) do
        [] -> acc
        candidates -> Map.put(acc, path, candidates)
      end

    Enum.reduce(schema, acc, fn {key, type}, acc ->
      collect_nested_spellcheck(spellcheck_subschema(type), data, key, path, acc)
    end)
  end

  defp collect_nested_spellcheck({:nested, sub}, data, key, path, acc) do
    case get_enumerable_value(data, key) do
      value when is_map(value) and not is_struct(value) ->
        do_collect_spellcheck(sub, value, path ++ [key], acc)

      value when is_list(value) ->
        if Keyword.keyword?(value) do
          do_collect_spellcheck(sub, value, path ++ [key], acc)
        else
          acc
        end

      _other ->
        acc
    end
  end

  defp collect_nested_spellcheck({:list_of, sub}, data, key, path, acc) do
    case get_enumerable_value(data, key) do
      values when is_list(values) ->
        values
        |> Enum.with_index()
        |> Enum.reduce(acc, fn
          {value, index}, acc when is_map(value) and not is_struct(value) ->
            do_collect_spellcheck(sub, value, path ++ [key, index], acc)

          {_value, _index}, acc ->
            acc
        end)

      _other ->
        acc
    end
  end

  defp collect_nested_spellcheck(_other, _data, _key, _path, acc), do: acc

  defp spellcheck_subschema({:required, type}), do: spellcheck_subschema(type)

  defp spellcheck_subschema({:required, type, opts}) when is_list(opts),
    do: spellcheck_subschema(type)

  defp spellcheck_subschema({:meta, type, _opts}), do: spellcheck_subschema(type)
  defp spellcheck_subschema({:schema, schema}), do: spellcheck_subschema(schema)
  defp spellcheck_subschema({:schema, schema, _opts}), do: spellcheck_subschema(schema)

  defp spellcheck_subschema({:list, type}) do
    case spellcheck_subschema(type) do
      {:nested, sub} -> {:list_of, sub}
      other -> other
    end
  end

  defp spellcheck_subschema(type) when is_map(type), do: {:nested, type}

  defp spellcheck_subschema(type) when is_list(type) do
    if Keyword.keyword?(type), do: {:nested, type}, else: nil
  end

  defp spellcheck_subschema(_type), do: nil

  defp spellcheck_path(%Peri.Parser{path: path}) when is_list(path), do: path
  defp spellcheck_path(_other), do: []

  # Access.key/1 only support maps and structs
  def get_enumerable_value(enum, key) when is_struct(enum) do
    get_in(enum, [Access.key(key)])
  end

  def get_enumerable_value(enum, key) when is_map(enum) and is_binary(key) do
    Map.get(enum, key)
  end

  def get_enumerable_value(enum, key) when is_map(enum) and is_atom(key) do
    if Map.has_key?(enum, key) do
      Map.get(enum, key)
    else
      get_enumerable_value(enum, Atom.to_string(key))
    end
  end

  def get_enumerable_value(enum, key) when is_list(enum) do
    Keyword.get(enum, key)
  end

  @doc """
  Checks if the given data is a numeric value, specifically a integer or a float.

  ## Parameters

    - `data`: The data to check.

  ## Examples

      iex> is_numeric(123)
      true

      iex> is_numeric(0xFF)
      true

      iex> is_numeric(12.12)
      true

      iex> is_numeric("string")
      false

      iex> is_numeric(%{})
      false
  """
  defguard is_numeric(n) when is_integer(n) or is_float(n)

  @doc """
  Checks if the given type as an atom is a numeric (integer or float).

  ## Parameters

    - `data`: The data to check.

  ## Examples

      iex> is_numeric(:integer)
      true

      iex> is_numeric(:float)
      true

      iex> is_numeric(:list)
      false

      iex> is_numeric({:enum, _})
      false
  """
  defguard is_numeric_type(t) when t in [:integer, :float]

  defguard is_of_numeric_type(val, t)
           when (t == :integer and is_integer(val)) or (t == :float and is_float(val))

  defguard is_type_with_multiple_options(t) when is_numeric_type(t) or t === :string

  @doc false
  defp validate_field(nil, nil, _data, _opts), do: :ok
  defp validate_field(_, :any, _data, _opts), do: :ok
  defp validate_field(pid, :pid, _data, _opts) when is_pid(pid), do: :ok
  defp validate_field(%Date{}, :date, _data, _opts), do: :ok
  defp validate_field(%Time{}, :time, _data, _opts), do: :ok
  defp validate_field(%Duration{}, :duration, _data, _opts), do: :ok
  defp validate_field(%DateTime{}, :datetime, _data, _opts), do: :ok
  defp validate_field(%NaiveDateTime{}, :naive_datetime, _data, _opts), do: :ok
  defp validate_field(val, :atom, _data, _opts) when is_atom(val), do: :ok
  defp validate_field(val, :atom!, _data, _opts) when is_atom(val), do: :ok
  defp validate_field(val, :map, _data, _opts) when is_map(val), do: :ok
  defp validate_field(val, :string, _data, _opts) when is_binary(val), do: :ok
  defp validate_field(val, :integer, _data, _opts) when is_integer(val), do: :ok
  defp validate_field(val, :float, _data, _opts) when is_float(val), do: :ok
  defp validate_field(val, :boolean, _data, _opts) when is_boolean(val), do: :ok
  defp validate_field(val, :list, _data, _opts) when is_list(val), do: :ok

  defp validate_field(val, {:literal, literal}, _data, _opts) when val === literal, do: :ok

  defp validate_field(val, {:literal, literal}, _data, _opts) do
    {:error, "expected literal value %{expected} but got %{actual}",
     [expected: inspect(literal), actual: inspect(val)]}
  end

  defp validate_field(val, {:meta, type, _meta_opts}, data, opts),
    do: validate_field(val, type, data, opts)

  defp validate_field(val, {:ref, {mod, name}}, parser, opts)
       when is_atom(mod) and is_atom(name) do
    resolve_ref({mod, name}, val, parser, opts)
  end

  defp validate_field(val, {:ref, name}, parser, opts) when is_atom(name) do
    resolve_ref({nil, name}, val, parser, opts)
  end

  defp validate_field(val, {:multi, field, branches}, parser, opts)
       when is_atom(field) and is_map(branches) do
    dispatch_multi(val, field, branches, parser, opts)
  end

  defp validate_field(nil, {:required, type}, _data, _opts) do
    {:error, "is required, expected type of %{expected}", expected: summarize(type)}
  end

  defp validate_field(_val, {:required, {type, {:default, default}}}, _data, _opts) do
    template =
      "cannot set default value of #{inspect(default)} for required field of type %{type}"

    {:ok, template, [type: summarize(type)]}
  end

  # Empty maps and lists are valid for required fields - only nil is invalid
  defp validate_field(val, {:required, type}, data, opts),
    do: validate_field(val, type, data, opts)

  defp validate_field(val, {:required, type, error_opts}, data, opts) when is_list(error_opts) do
    {override, _rest} = Keyword.pop(error_opts, :error)

    val
    |> validate_field({:required, type}, data, opts)
    |> tag_error_override(override)
  end

  defp validate_field(val, {type, options}, data, opts)
       when is_type_with_multiple_options(type) and is_list(options) do
    {override, options} = Keyword.pop(options, :error)
    options = Keyword.delete(options, :gen)

    options
    |> Enum.map(fn option -> validate_field(val, {type, option}, data, opts) end)
    |> Enum.filter(fn x -> x != :ok end)
    |> case do
      [] -> :ok
      errs -> {:error, errs}
    end
    |> tag_error_override(override)
  end

  defp validate_field(val, {:string, {:regex, regex}}, _data, _opts) when is_binary(val) do
    if Regex.match?(regex, val) do
      :ok
    else
      {:error, "should match the %{regex} pattern", [regex: regex]}
    end
  end

  defp validate_field(val, {:string, {:eq, eq}}, _data, _opts) when is_binary(val) do
    if val === eq do
      :ok
    else
      {:error, "should be equal to literal %{literal}", [literal: eq]}
    end
  end

  defp validate_field(val, {:string, {:min, min}}, _data, _opts) when is_binary(val) do
    if String.length(val) >= min do
      :ok
    else
      {:error, "should have the minimum length of %{length}", [length: min]}
    end
  end

  defp validate_field(val, {:string, {:max, max}}, _data, _opts) when is_binary(val) do
    if String.length(val) <= max do
      :ok
    else
      {:error, "should have the maximum length of %{length}", [length: max]}
    end
  end

  defp validate_field(val, {type, {:eq, value}}, _data, _opts)
       when is_of_numeric_type(val, type) do
    if val == value do
      :ok
    else
      {:error, "should be equal to %{value}", [value: value]}
    end
  end

  defp validate_field(val, {type, {:neq, value}}, _data, _opts)
       when is_of_numeric_type(val, type) do
    if val != value do
      :ok
    else
      {:error, "should be not equal to %{value}", [value: value]}
    end
  end

  defp validate_field(val, {type, {:gt, value}}, _data, _opts)
       when is_of_numeric_type(val, type) do
    if val > value do
      :ok
    else
      {:error, "should be greater then %{value}", [value: value]}
    end
  end

  defp validate_field(val, {type, {:gte, value}}, _data, _opts)
       when is_of_numeric_type(val, type) do
    if val >= value do
      :ok
    else
      {:error, "should be greater then or equal to %{value}", [value: value]}
    end
  end

  defp validate_field(val, {type, {:lte, value}}, _data, _opts)
       when is_of_numeric_type(val, type) do
    if val <= value do
      :ok
    else
      {:error, "should be less then or equal to %{value}", [value: value]}
    end
  end

  defp validate_field(val, {type, {:lt, value}}, _data, _opts)
       when is_of_numeric_type(val, type) do
    if val < value do
      :ok
    else
      {:error, "should be less then %{value}", [value: value]}
    end
  end

  defp validate_field(val, {type, {:range, {min, max}}}, _data, _opts)
       when is_of_numeric_type(val, type) do
    info = [min: min, max: max]
    template = "should be in the range of %{min}..%{max} (inclusive)"

    cond do
      val < min -> {:error, template, info}
      val > max -> {:error, template, info}
      true -> :ok
    end
  end

  defp validate_field(val, {type, {:multiple_of, n}}, _data, _opts)
       when is_of_numeric_type(val, type) and is_numeric(n) do
    if multiple_of?(val, n) do
      :ok
    else
      {:error, "should be a multiple of %{value}", [value: n]}
    end
  end

  defp validate_field(val, {type, {:default, {mod, fun}}}, data, opts)
       when is_atom(mod) and is_atom(fun) do
    validate_field(val, {type, {:default, apply(mod, fun, [])}}, data, opts)
  end

  defp validate_field(val, {type, {:default, {mod, fun, args}}}, data, opts)
       when is_atom(mod) and is_atom(fun) and is_list(args) do
    validate_field(val, {type, {:default, apply(mod, fun, args)}}, data, opts)
  end

  defp validate_field(val, {type, {:default, default}}, data, opts)
       when is_function(default, 0) do
    validate_field(val, {type, {:default, default.()}}, data, opts)
  end

  defp validate_field(val, {type, {:default, default}}, data, opts) do
    val = if is_nil(val), do: default, else: val

    with :ok <- validate_field(val, type, data, opts) do
      {:ok, val}
    end
  end

  defp validate_field(val, {:cond, condition, true_type, else_type}, parser, opts) do
    if call_callback(condition, parser) do
      validate_field(val, true_type, %{parser | field_presence?: true}, opts)
    else
      validate_field(val, else_type, parser, opts)
    end
  end

  defp validate_field(val, {:dependent, callback}, parser, opts)
       when is_function(callback) do
    callback
    |> call_callback(parser)
    |> validate_dependent(val, parser, opts)
  end

  defp validate_field(val, {:dependent, {mod, fun}}, parser, opts)
       when is_atom(mod) and is_atom(fun) do
    result =
      cond do
        function_exported?(mod, fun, 2) ->
          current = maybe_get_current_data(parser)
          root = maybe_get_root_data(parser)
          apply(mod, fun, [current, root])

        function_exported?(mod, fun, 1) ->
          root = maybe_get_root_data(parser)
          apply(mod, fun, [root])

        true ->
          nil
      end

    validate_dependent(result, val, parser, opts)
  end

  defp validate_field(val, {:dependent, {mod, fun, args}}, parser, opts)
       when is_atom(mod) and is_atom(fun) and is_list(args) do
    root = maybe_get_root_data(parser)

    mod
    |> apply(fun, [root | args])
    |> validate_dependent(val, parser, opts)
  end

  defp validate_field(val, {:dependent, field, condition, type}, parser, opts) do
    root = maybe_get_root_data(parser)
    dependent_val = get_enumerable_value(root, field)

    case condition.(val, dependent_val) do
      :ok ->
        validate_field(val, type, root, opts)

      {:error, [_ | _]} = error ->
        error

      {:error, _reason, _info} = error ->
        error

      other ->
        info = [actual: inspect(other)]

        {:error, "expected dependent condition to return :ok or {:error, reason}, got %{actual}",
         info}
    end
  end

  defp validate_field(nil, s, parser, opts) when is_enumerable(s) do
    if schema_has_defaults?(s) and parser.field_presence? do
      validate_field(%{}, s, parser, opts)
    else
      :ok
    end
  end

  defp validate_field(nil, _schema, _data, _opts), do: :ok

  defp validate_field(val, {type, {:transform, mapper}}, data, opts)
       when is_function(mapper, 1) do
    if encoding?(opts) do
      validate_field(val, type, data, opts)
    else
      case validate_field(val, type, data, opts) do
        :ok -> {:ok, mapper.(val)}
        {:ok, val} -> {:ok, mapper.(val)}
        err -> err
      end
    end
  end

  defp validate_field(val, {type, {:transform, mapper}}, data, opts)
       when is_function(mapper, 2) do
    if encoding?(opts) do
      validate_field(val, type, data, opts)
    else
      case validate_field(val, type, data, opts) do
        :ok -> {:ok, mapper.(val, maybe_get_root_data(data))}
        {:ok, val} -> {:ok, mapper.(val, maybe_get_root_data(data))}
        err -> err
      end
    end
  end

  defp validate_field(val, {type, {:transform, {mod, fun}}}, data, opts)
       when is_atom(mod) and is_atom(fun) do
    if encoding?(opts) do
      validate_field(val, type, data, opts)
    else
      apply_mod_transform(val, type, mod, fun, data, opts)
    end
  end

  defp validate_field(val, {type, {:transform, {mod, fun, args}}}, data, opts)
       when is_atom(mod) and is_atom(fun) and is_list(args) do
    if encoding?(opts) do
      validate_field(val, type, data, opts)
    else
      apply_mod_transform(val, type, mod, fun, args, data, opts)
    end
  end

  defp validate_field(val, {type, {:encode, encoder}}, data, opts)
       when is_function(encoder, 1),
       do: validate_with_encode(val, type, encoder, data, opts)

  defp validate_field(val, {type, {:encode, {mod, fun}}}, data, opts)
       when is_atom(mod) and is_atom(fun),
       do: validate_with_encode(val, type, {mod, fun}, data, opts)

  defp validate_field(val, {type, {:encode, {mod, fun, args}}}, data, opts)
       when is_atom(mod) and is_atom(fun) and is_list(args),
       do: validate_with_encode(val, type, {mod, fun, args}, data, opts)

  defp validate_field(val, {:coerce, target}, data, opts),
    do: validate_field(val, {:coerce, :string, target, []}, data, opts)

  defp validate_field(val, {:coerce, target, coerce_opts}, data, opts)
       when is_list(coerce_opts),
       do: validate_field(val, {:coerce, :string, target, coerce_opts}, data, opts)

  defp validate_field(val, {:coerce, source, target}, data, opts),
    do: validate_field(val, {:coerce, source, target, []}, data, opts)

  defp validate_field(val, {:coerce, source, target, coerce_opts}, data, opts)
       when is_list(coerce_opts) do
    if encoding?(opts) do
      encode_coercion(val, source, target, coerce_opts, data, opts)
    else
      decode_coercion(val, source, target, coerce_opts, data, opts)
    end
  end

  defp validate_field(val, {:custom, callback}, _data, _opts) when is_function(callback, 1) do
    callback.(val)
  end

  defp validate_field(val, {:custom, {mod, fun}}, _data, _opts)
       when is_atom(mod) and is_atom(fun) do
    apply(mod, fun, [val])
  end

  defp validate_field(val, {:custom, {mod, fun, args}}, _data, _opts)
       when is_atom(mod) and is_atom(fun) and is_list(args) do
    apply(mod, fun, [val | args])
  end

  defp validate_field(val, {:either, {type_1, type_2}}, data, opts) do
    with {:error, _} <- normalize_validation_result(validate_field(val, type_1, data, opts)),
         {:error, _} <- normalize_validation_result(validate_field(val, type_2, data, opts)) do
      info = [
        first_type: summarize(type_1),
        second_type: summarize(type_2),
        actual: inspect(val)
      ]

      template = "expected either %{first_type} or %{second_type}, got: %{actual}"
      {:error, template, info}
    end
  end

  defp validate_field(val, {:oneof, types}, data, opts) do
    types
    |> Enum.reduce_while(:error, fn type, :error ->
      case validate_field(val, type, data, opts) do
        :ok -> {:halt, :ok}
        {:ok, val} -> {:halt, {:ok, val}}
        {:error, _reason, _info} -> {:cont, :error}
        {:error, _errors} -> {:cont, :error}
      end
    end)
    |> then(fn
      :ok ->
        :ok

      {:ok, val} ->
        {:ok, val}

      :error ->
        expected = Enum.map_join(types, " or ", &summarize/1)
        info = [oneof: expected, actual: inspect(val)]
        template = "expected one of %{oneof}, got: %{actual}"

        {:error, template, info}
    end)
  end

  defp validate_field(source, {:tuple, types}, data, opts) when is_tuple(source) do
    if tuple_size(source) == length(types) do
      validate_tuple_elements(source, types, data, opts)
    else
      info = [length: length(types), actual: length(Tuple.to_list(source))]
      template = "expected tuple of size %{length} received tuple with %{actual} length"
      {:error, template, info}
    end
  end

  defp validate_field(val, {:enum, choices}, _data, _opts) do
    if val in choices do
      :ok
    else
      info = [choices: inspect(choices, pretty: true), actual: inspect(val)]
      template = "expected one of %{choices} received %{actual}"
      {:error, template, info}
    end
  end

  defp validate_field(val, {:enum, choices, enum_opts}, data, opts)
       when is_list(choices) and is_list(enum_opts) do
    {override, rest} = Keyword.pop(enum_opts, :error)
    rest = Keyword.delete(rest, :gen)

    val
    |> run_enum_with_opts(choices, rest, data, opts)
    |> tag_error_override(override)
  end

  defp validate_field(data, {:list, type}, source, opts) when is_list(data) do
    data
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {el, index}, {:ok, vals} ->
      element_source =
        case source do
          %Peri.Parser{} = parser -> Peri.Parser.for_list_element(el, parser, index)
          _ -> source
        end

      case validate_field(el, type, element_source, opts) do
        :ok -> {:cont, {:ok, vals}}
        {:ok, val} -> {:cont, {:ok, [val | vals]}}
        {:error, errors} -> {:halt, {:error, errors}}
        {:error, reason, info} -> {:halt, {:error, reason, info}}
      end
    end)
    |> then(fn
      {:ok, []} -> :ok
      {:ok, val} -> {:ok, Enum.reverse(val)}
      err -> err
    end)
  end

  defp validate_field(data, {:list, type, list_opts}, source, opts)
       when is_list(data) and is_list(list_opts) do
    constraint_opts = Keyword.drop(list_opts, [:error, :gen])

    with :ok <- check_list_constraints(data, constraint_opts) do
      validate_field(data, {:list, type}, source, opts)
    end
  end

  defp validate_field(data, {:map, type}, source, opts) when is_map(data) do
    Enum.reduce_while(data, {:ok, %{}}, fn {key, val}, {:ok, map_acc} ->
      case validate_field(val, type, source, opts) do
        :ok -> {:cont, {:ok, Map.put(map_acc, key, val)}}
        {:ok, validated_val} -> {:cont, {:ok, Map.put(map_acc, key, validated_val)}}
        {:error, errors} -> {:halt, {:error, errors}}
        {:error, reason, info} -> {:halt, {:error, reason, info}}
      end
    end)
    |> then(fn
      {:ok, map} when map == %{} -> :ok
      {:ok, map} -> {:ok, map}
      err -> err
    end)
  end

  defp validate_field(data, {:map, key_type, value_type}, source, opts) when is_map(data) do
    Enum.reduce_while(data, {:ok, %{}}, fn {key, val}, {:ok, map_acc} ->
      with :ok <- validate_field(key, key_type, source, opts),
           :ok <- validate_field(val, value_type, source, opts) do
        {:cont, {:ok, Map.put(map_acc, key, val)}}
      else
        {:ok, validated_val} ->
          {:cont, {:ok, Map.put(map_acc, key, validated_val)}}

        error ->
          {:halt, error}
      end
    end)
    |> then(fn
      {:ok, map} when map == %{} -> :ok
      {:ok, map} -> {:ok, map}
      err -> err
    end)
  end

  defp validate_field(data, {:schema, schema}, source, opts) do
    validate_field(data, schema, source, opts)
  end

  defp validate_field(data, {:schema, schema, schema_opts}, source, opts)
       when is_list(schema_opts) do
    validate_field(data, schema, source, opts)
  end

  defp validate_field(
         data,
         {:schema, schema, {:additional_keys, value_schema}},
         source,
         opts
       )
       when is_map(data) and is_map(schema) do
    # Split data not in the schema so that the additional validator doesn't try
    # to validate over the defined keys.
    additional_keys =
      Enum.reduce(Map.keys(schema), MapSet.new(Map.keys(data)), fn key, acc ->
        acc |> MapSet.delete(key) |> MapSet.delete(to_string(key))
      end)

    additional_data =
      data
      |> Enum.filter(fn {key, _} -> MapSet.member?(additional_keys, key) end)
      |> Map.new()

    with {:ok, schema_data} <- validate_field(data, schema, source, opts),
         {:ok, additional_data} <-
           validate_field(additional_data, {:map, value_schema}, source, opts) do
      {:ok, Map.merge(schema_data, additional_data)}
    end
  end

  defp validate_field(data, schema, _data, _opts)
       when is_enumerable(data) and not is_enumerable(schema) do
    {:error, "expected a nested schema but received schema: %{type}", [type: summarize(schema)]}
  end

  defp validate_field(data, schema, p, opts) when is_enumerable(data) do
    root = maybe_get_root_data(p)
    current = maybe_get_current_data(p)
    filtered_data = filter_data(schema, data, opts)
    path = spellcheck_path(p)

    opts =
      Keyword.put(opts, :spellcheck_candidates, Map.get(opts[:spellcheck] || %{}, path, []))

    new_parser = %Peri.Parser{
      data: filtered_data,
      root_data: root,
      current_data: current,
      path: path
    }

    case traverse_schema(schema, new_parser, opts) do
      %Peri.Parser{errors: []} = parser -> {:ok, parser.data}
      %Peri.Parser{errors: errors} -> {:error, errors}
    end
  end

  defp validate_field(val, type, _data, _opts) do
    info = [expected: summarize(type), actual: inspect(val, pretty: true)]
    {:error, "expected type of %{expected} received %{actual} value", info}
  end

  # Dependent callbacks must return {:ok, type} or {:error, reason, info}.
  # A bare return or a type that fails schema validation is a contract breach;
  # report it as a validation error instead of leaking the raw value into
  # traverse_schema.
  defp validate_dependent({:ok, type}, val, parser, opts) do
    case validate_schema(type) do
      {:ok, schema} ->
        validate_field(val, schema, parser, opts)

      {:error, error} ->
        info = [schema: inspect(type), reason: inspect(error)]
        {:error, "dependent callback returned invalid schema %{schema}: %{reason}", info}
    end
  end

  defp validate_dependent({:error, reason, info}, _val, _parser, _opts)
       when is_binary(reason) and is_map(info),
       do: {:error, reason, Map.to_list(info)}

  defp validate_dependent({:error, reason, info}, _val, _parser, _opts)
       when is_binary(reason) and is_list(info),
       do: {:error, reason, info}

  defp validate_dependent(other, _val, _parser, _opts) do
    info = [actual: inspect(other)]
    {:error, "expected dependent callback to return {:ok, type}, got %{actual}", info}
  end

  defp validate_tuple_elements(source, types, data, opts) do
    Enum.with_index(types)
    |> Enum.reduce_while({:ok, []}, fn {type, index}, {:ok, vals} ->
      case validate_field(elem(source, index), type, data, opts) do
        :ok ->
          {:cont, {:ok, vals}}

        {:ok, val} ->
          {:cont, {:ok, [val | vals]}}

        {:error, errors} when is_list(errors) ->
          info = [index: index]
          {:halt, {:error, "tuple element %{index}: invalid", info}}

        {:error, reason, nested_info} ->
          info = [index: index] ++ nested_info
          {:halt, {:error, "tuple element %{index}: #{reason}", info}}
      end
    end)
    |> then(fn
      {:ok, []} -> :ok
      {:ok, vals} -> {:ok, List.to_tuple(Enum.reverse(vals))}
      {:error, reason, info} -> {:error, reason, info}
    end)
  end

  defp validate_and_extract(val, type, data, opts) do
    case validate_field(val, type, data, opts) do
      :ok -> {:ok, val}
      {:ok, val} -> {:ok, val}
      err -> err
    end
  end

  defp apply_mod_transform(val, type, mod, fun, data, opts) do
    with {:ok, val} <- validate_and_extract(val, type, data, opts) do
      cond do
        function_exported?(mod, fun, 1) ->
          {:ok, apply(mod, fun, [val])}

        function_exported?(mod, fun, 2) ->
          {:ok, apply(mod, fun, [val, maybe_get_root_data(data)])}

        true ->
          template = "expected %{mod} to export %{fun}/1 or %{fun}/2"
          {:error, template, mod: mod, fun: fun}
      end
    end
  end

  defp apply_mod_transform(val, type, mod, fun, args, data, opts) do
    with {:ok, val} <- validate_and_extract(val, type, data, opts) do
      cond do
        function_exported?(mod, fun, length(args) + 2) ->
          {:ok, apply(mod, fun, [val, maybe_get_root_data(data) | args])}

        function_exported?(mod, fun, length(args) + 1) ->
          {:ok, apply(mod, fun, [val | args])}

        true ->
          template = "expected %{mod} to export %{fun} with arity from %{base} to %{arity}"
          {:error, template, mod: mod, fun: fun, arity: length(args), base: length(args) + 1}
      end
    end
  end

  defp encoding?(opts), do: Keyword.get(opts, :direction) == :encode

  defp validate_with_encode(val, type, encoder, data, opts) do
    if encoding?(opts) do
      case validate_field(val, type, data, opts) do
        :ok -> {:ok, apply_encoder(encoder, val)}
        {:ok, val} -> {:ok, apply_encoder(encoder, val)}
        err -> err
      end
    else
      validate_field(val, type, data, opts)
    end
  end

  defp apply_encoder(encoder, val) when is_function(encoder, 1), do: encoder.(val)

  defp apply_encoder({mod, fun}, val) when is_atom(mod) and is_atom(fun),
    do: apply(mod, fun, [val])

  defp apply_encoder({mod, fun, args}, val) when is_atom(mod) and is_atom(fun) and is_list(args),
    do: apply(mod, fun, [val | args])

  defp decode_coercion(val, :string, {:list, inner}, coerce_opts, data, opts)
       when is_binary(val) do
    case Keyword.fetch(coerce_opts, :split) do
      {:ok, separators} ->
        val
        |> split_wire_list(separators)
        |> validate_wire_list({:list, {:coerce, :string, inner}}, data, opts)

      :error ->
        validate_field(val, {:list, inner}, data, opts)
    end
  end

  defp decode_coercion(val, :string, {:list, inner, list_opts}, coerce_opts, data, opts)
       when is_binary(val) and is_list(list_opts) do
    case Keyword.fetch(coerce_opts, :split) do
      {:ok, separators} ->
        val
        |> split_wire_list(separators)
        |> validate_wire_list({:list, {:coerce, :string, inner}, list_opts}, data, opts)

      :error ->
        validate_field(val, {:list, inner, list_opts}, data, opts)
    end
  end

  defp decode_coercion(val, source, target, coerce_opts, data, opts) do
    if matches_type?(val, target) do
      validate_field(val, target, data, opts)
    else
      val
      |> validate_field(target, data, opts)
      |> handle_coercion_fallback(val, source, target, coerce_opts, data, opts)
    end
  end

  defp split_wire_list(val, separators) do
    val
    |> String.split(List.wrap(separators), trim: true)
    |> Enum.map(&String.trim/1)
  end

  # a split always replaces the wire value with a list, even when the
  # elements validate unchanged (:ok from list validation keeps the original)
  defp validate_wire_list(parts, list_type, data, opts) do
    case validate_field(parts, list_type, data, opts) do
      :ok -> {:ok, parts}
      other -> other
    end
  end

  defp handle_coercion_fallback(:ok, _val, _source, _target, _coerce_opts, _data, _opts), do: :ok

  defp handle_coercion_fallback(
         {:ok, _} = ok,
         _val,
         _source,
         _target,
         _coerce_opts,
         _data,
         _opts
       ),
       do: ok

  defp handle_coercion_fallback(target_error, val, source, target, coerce_opts, data, opts) do
    if matches_source?(val, source) do
      val
      |> do_coerce(source, target, coerce_opts)
      |> finish_coercion(val, source, target, data, opts)
    else
      target_error
    end
  end

  defp finish_coercion({:ok, coerced}, _val, _source, target, data, opts) do
    case validate_field(coerced, target, data, opts) do
      :ok -> {:ok, coerced}
      {:ok, val} -> {:ok, val}
      err -> err
    end
  end

  defp finish_coercion(:error, val, source, target, _data, _opts) do
    info = [value: inspect(val), source: inspect(source), target: summarize(target)]
    {:error, "cannot coerce %{value} from %{source} to %{target}", info}
  end

  defp encode_coercion(val, source, target, coerce_opts, data, opts) do
    case validate_field(val, target, data, opts) do
      :ok -> {:ok, encode_coerced_value(val, source, target, coerce_opts)}
      {:ok, val} -> {:ok, encode_coerced_value(val, source, target, coerce_opts)}
      err -> err
    end
  end

  defp encode_coerced_value(val, source, target, coerce_opts) do
    case Keyword.fetch(coerce_opts, :encode) do
      {:ok, encoder} -> apply_encoder(encoder, val)
      :error -> default_wire_encode(val, source, target, coerce_opts)
    end
  end

  defp default_wire_encode(val, source, target, coerce_opts) do
    case {source, target} do
      {:string, {:list, inner}} when is_list(val) ->
        encode_wire_list(val, inner, coerce_opts)

      {:string, {:list, inner, list_opts}} when is_list(val) and is_list(list_opts) ->
        encode_wire_list(val, inner, coerce_opts)

      _other ->
        default_wire_encode(val, source, target)
    end
  end

  defp default_wire_encode(val, :string, target) do
    case coerce_target_atom(target) do
      :date -> Date.to_iso8601(val)
      :time -> Time.to_iso8601(val)
      :naive_datetime -> NaiveDateTime.to_iso8601(val)
      :datetime -> DateTime.to_iso8601(val)
      _other -> to_string(val)
    end
  end

  defp default_wire_encode(val, _source, _target), do: val

  defp encode_wire_list(val, inner, coerce_opts) do
    separator = coerce_opts |> Keyword.get(:split, ",") |> List.wrap() |> List.first()
    Enum.map_join(val, separator, &default_wire_encode(&1, :string, inner))
  end

  defp matches_type?(val, :string), do: is_binary(val)
  defp matches_type?(val, :integer), do: is_integer(val)
  defp matches_type?(val, :float), do: is_float(val)
  defp matches_type?(val, :boolean), do: is_boolean(val)
  defp matches_type?(val, :atom), do: is_atom(val)
  defp matches_type?(val, :atom!), do: is_atom(val)
  defp matches_type?(%Date{}, :date), do: true
  defp matches_type?(%Time{}, :time), do: true
  defp matches_type?(%DateTime{}, :datetime), do: true
  defp matches_type?(%NaiveDateTime{}, :naive_datetime), do: true
  defp matches_type?(_val, _target), do: false

  defp matches_source?(val, :string), do: is_binary(val)
  defp matches_source?(_val, source) when is_function(source, 1), do: true
  defp matches_source?(_val, {mod, fun}) when is_atom(mod) and is_atom(fun), do: true

  defp matches_source?(_val, {mod, fun, args})
       when is_atom(mod) and is_atom(fun) and is_list(args),
       do: true

  defp matches_source?(_val, _source), do: false

  defp do_coerce(val, source, _target, _coerce_opts) when is_function(source, 1),
    do: normalize_coercion_result(source.(val))

  defp do_coerce(val, {mod, fun}, _target, _coerce_opts) when is_atom(mod) and is_atom(fun),
    do: normalize_coercion_result(apply(mod, fun, [val]))

  defp do_coerce(val, {mod, fun, args}, _target, _coerce_opts)
       when is_atom(mod) and is_atom(fun) and is_list(args),
       do: normalize_coercion_result(apply(mod, fun, [val | args]))

  defp do_coerce(val, :string, {:enum, choices}, _coerce_opts) when is_binary(val),
    do: coerce_wire_choice(val, choices)

  defp do_coerce(val, :string, {:enum, choices, enum_opts}, _coerce_opts)
       when is_binary(val) and is_list(enum_opts),
       do: coerce_wire_choice(val, choices)

  defp do_coerce(val, :string, {:literal, literal}, _coerce_opts) when is_binary(val),
    do: coerce_wire_choice(val, [literal])

  defp do_coerce(val, :string, target, _coerce_opts) when is_binary(val),
    do: coerce_from_string(val, coerce_target_atom(target))

  defp do_coerce(_val, _source, _target, _coerce_opts), do: :error

  # on a choice miss the raw value goes through so the enum/literal
  # validation produces its own error (including any error: override)
  defp coerce_wire_choice(val, choices) do
    Enum.find_value(choices, {:ok, val}, fn
      choice when is_atom(choice) or is_binary(choice) or is_number(choice) ->
        if to_string(choice) == val, do: {:ok, choice}

      _other ->
        nil
    end)
  end

  defp normalize_coercion_result({:ok, val}), do: {:ok, val}
  defp normalize_coercion_result(_other), do: :error

  defp coerce_target_atom(target) when is_atom(target), do: target
  defp coerce_target_atom({target, _opts}) when is_atom(target), do: target
  defp coerce_target_atom(_target), do: nil

  defp coerce_from_string(val, :integer) do
    case Integer.parse(val) do
      {int, ""} -> {:ok, int}
      _other -> :error
    end
  end

  defp coerce_from_string(val, :float) do
    case Float.parse(val) do
      {float, ""} -> {:ok, float}
      _other -> :error
    end
  end

  defp coerce_from_string("true", :boolean), do: {:ok, true}
  defp coerce_from_string("false", :boolean), do: {:ok, false}
  defp coerce_from_string(_val, :boolean), do: :error

  defp coerce_from_string(val, :atom) do
    {:ok, String.to_existing_atom(val)}
  rescue
    ArgumentError -> :error
  end

  defp coerce_from_string(val, :atom!), do: {:ok, String.to_atom(val)}

  defp coerce_from_string(val, :date), do: wrap_iso8601(Date.from_iso8601(val))
  defp coerce_from_string(val, :time), do: wrap_iso8601(Time.from_iso8601(val))

  defp coerce_from_string(val, :naive_datetime),
    do: wrap_iso8601(NaiveDateTime.from_iso8601(val))

  defp coerce_from_string(val, :datetime) do
    case DateTime.from_iso8601(val) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _reason} -> :error
    end
  end

  defp coerce_from_string(_val, _target), do: :error

  defp wrap_iso8601({:ok, value}), do: {:ok, value}
  defp wrap_iso8601({:error, _reason}), do: :error

  # if schema is matches a raw data structure, it will not use the Peri.Parser
  defp maybe_get_root_data(%Peri.Parser{} = p), do: p.root_data
  defp maybe_get_root_data(data), do: data

  defp maybe_get_current_data(%Peri.Parser{} = p), do: p.current_data || p.data
  defp maybe_get_current_data(data), do: data

  defp valid_error_opt?(opts) do
    case Keyword.fetch(opts, :error) do
      :error -> true
      {:ok, msg} when is_binary(msg) -> true
      {:ok, {mod, fun, args}} when is_atom(mod) and is_atom(fun) and is_list(args) -> true
      {:ok, _} -> false
    end
  end

  defp valid_gen_opt?(opts) do
    case Keyword.fetch(opts, :gen) do
      :error -> true
      {:ok, {mod, fun, args}} when is_atom(mod) and is_atom(fun) and is_list(args) -> true
      {:ok, {mod, fun}} when is_atom(mod) and is_atom(fun) -> true
      {:ok, fun} when is_function(fun, 0) -> true
      {:ok, _} -> false
    end
  end

  defp valid_list_opts?(opts) do
    Enum.all?(opts, fn
      {:min, n} when is_integer(n) and n >= 0 -> true
      {:max, n} when is_integer(n) and n >= 0 -> true
      {:unique, b} when is_boolean(b) -> true
      {:error, _} -> true
      {:gen, _} -> true
      _ -> false
    end)
  end

  defp check_list_constraints(data, list_opts) do
    Enum.reduce_while(list_opts, :ok, fn opt, :ok ->
      case check_list_constraint(data, opt) do
        :ok -> {:cont, :ok}
        err -> {:halt, err}
      end
    end)
  end

  defp check_list_constraint(data, {:min, min}) when is_integer(min) do
    if length(data) >= min do
      :ok
    else
      {:error, "should have at least %{min} items", [min: min]}
    end
  end

  defp check_list_constraint(data, {:max, max}) when is_integer(max) do
    if length(data) <= max do
      :ok
    else
      {:error, "should have at most %{max} items", [max: max]}
    end
  end

  defp check_list_constraint(data, {:unique, true}) do
    if length(Enum.uniq(data)) == length(data) do
      :ok
    else
      {:error, "should have unique items", []}
    end
  end

  defp check_list_constraint(_data, {:unique, false}), do: :ok
  defp check_list_constraint(_data, _opt), do: :ok

  defp multiple_of?(_val, 0), do: false
  defp multiple_of?(val, n) when is_integer(val) and is_integer(n), do: rem(val, n) == 0

  defp multiple_of?(val, n) when is_number(val) and is_number(n) do
    quotient = val / n
    abs(quotient - Float.round(quotient)) < 1.0e-9
  end

  defp validate_enum_type_opt(enum_opts, p) do
    case Keyword.fetch(enum_opts, :type) do
      :error -> :ok
      {:ok, type} -> validate_type(type, p)
    end
  end

  defp run_enum_with_opts(val, choices, enum_opts, data, opts) do
    case Keyword.fetch(enum_opts, :type) do
      :error ->
        validate_field(val, {:enum, choices}, data, opts)

      {:ok, type} ->
        with :ok <- validate_field(val, type, data, opts),
             do: validate_field(val, {:enum, choices}, data, opts)
    end
  end

  defp tag_error_override(:ok, _), do: :ok
  defp tag_error_override({:ok, _} = result, _), do: result
  defp tag_error_override(result, nil), do: result

  defp tag_error_override({:error, template, info}, override) when is_list(info) do
    {:error, template, Keyword.put(info, :__error_override__, override)}
  end

  defp tag_error_override({:error, errors}, override) when is_list(errors) do
    tagged =
      Enum.map(errors, fn
        {:error, template, info} when is_list(info) ->
          {:error, template, Keyword.put(info, :__error_override__, override)}

        other ->
          other
      end)

    {:error, tagged}
  end

  defp tag_error_override(other, _), do: other

  @ref_depth_limit 64

  defp resolve_ref({_mod, _name} = ref, _val, %Peri.Parser{ref_depth: d}, _opts)
       when d >= @ref_depth_limit do
    {:error, "ref resolution exceeded depth limit of %{limit} at %{ref}",
     limit: @ref_depth_limit, ref: inspect(ref)}
  end

  defp resolve_ref({mod, name}, val, parser, opts) when is_atom(mod) and is_atom(name) do
    case fetch_ref_schema(mod, name) do
      {:ok, schema} ->
        validate_field(val, schema, Peri.Parser.bump_ref_depth(parser), opts)

      {:error, reason} ->
        {:error, reason, ref: inspect({mod, name})}
    end
  end

  defp fetch_ref_schema(nil, name) do
    {:error, "ref #{inspect(name)} has no module to resolve against; use {:ref, {Mod, name}}"}
  end

  defp fetch_ref_schema(mod, name) do
    cond do
      not Code.ensure_loaded?(mod) ->
        {:error, "module #{inspect(mod)} not loaded for ref #{inspect(name)}"}

      not function_exported?(mod, :get_schema, 1) ->
        {:error, "#{inspect(mod)} does not export get_schema/1 for ref #{inspect(name)}"}

      true ->
        try do
          {:ok, mod.get_schema(name)}
        rescue
          FunctionClauseError ->
            {:error, "ref #{inspect(name)} not defined in #{inspect(mod)}"}
        end
    end
  end

  defp dispatch_multi(val, field, branches, parser, opts) when is_map(val) or is_list(val) do
    with {:ok, tag} <- fetch_dispatch_value(val, field),
         {:ok, branch} <- fetch_branch(branches, tag, field) do
      validate_field(val, branch, parser, opts)
    end
  end

  defp dispatch_multi(val, _field, _branches, _parser, _opts) do
    {:error, "expected a map or keyword list for :multi dispatch, got %{actual}",
     actual: inspect(val)}
  end

  defp fetch_dispatch_value(val, field) when is_map(val) do
    cond do
      Map.has_key?(val, field) -> {:ok, Map.get(val, field)}
      Map.has_key?(val, Atom.to_string(field)) -> {:ok, Map.get(val, Atom.to_string(field))}
      true -> {:error, "missing :multi dispatch field %{field}", [field: field]}
    end
  end

  defp fetch_dispatch_value(val, field) when is_list(val) do
    if Keyword.has_key?(val, field),
      do: {:ok, Keyword.get(val, field)},
      else: {:error, "missing :multi dispatch field %{field}", [field: field]}
  end

  defp fetch_branch(branches, tag, field) do
    case Map.fetch(branches, tag) do
      {:ok, branch} ->
        {:ok, branch}

      :error ->
        {:error, "no :multi branch matches dispatch %{field}=%{tag}; expected one of %{tags}",
         field: field, tag: inspect(tag), tags: inspect(Map.keys(branches))}
    end
  end

  defp schema_has_defaults?(schema) when is_enumerable(schema) do
    Enum.any?(schema, fn {_key, type} -> type_has_default?(type) end)
  end

  defp type_has_default?({_type, {:default, _default}}), do: true
  defp type_has_default?({:required, type}), do: type_has_default?(type)

  defp type_has_default?(nested) when is_enumerable(nested) do
    schema_has_defaults?(nested)
  end

  defp type_has_default?(_), do: false

  defp call_callback(callback, parser) when is_function(callback, 1) do
    root = maybe_get_root_data(parser)
    callback.(root)
  end

  defp call_callback(callback, parser) when is_function(callback, 2) do
    current = maybe_get_current_data(parser)
    root = maybe_get_root_data(parser)
    callback.(current, root)
  end

  @doc """
  Deep merges two map schemas into a new one.

  When both schemas define the same key as a plain map (a nested schema), the
  nested schemas are merged recursively. Otherwise the value from the right
  side wins: type tuples and directives are never merged structurally.

  The resulting schema is checked with `validate_schema/1`, returning its
  error tuple when the composed schema is invalid.

  ## Examples

      iex> Peri.merge(%{name: :string}, %{age: :integer})
      {:ok, %{name: :string, age: :integer}}

      iex> Peri.merge(%{name: :string}, %{name: :atom})
      {:ok, %{name: :atom}}

      iex> Peri.merge(%{user: %{name: :string}}, %{user: %{age: :integer}})
      {:ok, %{user: %{name: :string, age: :integer}}}
  """
  @spec merge(map_schema, map_schema) :: {:ok, map_schema} | {:error, [Peri.Error.t()]}
  def merge(schema1, schema2) when is_map(schema1) and is_map(schema2) do
    schema1 |> deep_merge(schema2) |> validate_schema()
  end

  def merge(schema1, schema2) do
    raise ArgumentError,
          "Peri.merge/2 expects two map schemas, got: " <>
            inspect(schema1) <> " and " <> inspect(schema2)
  end

  defp deep_merge(schema1, schema2) do
    Map.merge(schema1, schema2, fn _key, value1, value2 ->
      if plain_map?(value1) and plain_map?(value2),
        do: deep_merge(value1, value2),
        else: value2
    end)
  end

  defp plain_map?(value), do: is_map(value) and not is_struct(value)

  @doc """
  Keeps only the given top-level keys of a map schema.

  Keys not present in the schema are ignored. The resulting schema is checked
  with `validate_schema/1`, returning its error tuple when invalid.

  ## Examples

      iex> Peri.select(%{name: :string, age: :integer}, [:name])
      {:ok, %{name: :string}}

      iex> Peri.select(%{name: :string}, [:name, :missing])
      {:ok, %{name: :string}}
  """
  @spec select(map_schema, [atom | String.t()]) ::
          {:ok, map_schema} | {:error, [Peri.Error.t()]}
  def select(schema, keys) when is_map(schema) and is_list(keys) do
    schema |> Map.take(keys) |> validate_schema()
  end

  def select(schema, keys) do
    raise ArgumentError,
          "Peri.select/2 expects a map schema and a list of keys, got: " <>
            inspect(schema) <> " and " <> inspect(keys)
  end

  @doc """
  Drops the given top-level keys from a map schema.

  Keys not present in the schema are ignored. The resulting schema is checked
  with `validate_schema/1`, returning its error tuple when invalid.

  ## Examples

      iex> Peri.except(%{name: :string, age: :integer}, [:age])
      {:ok, %{name: :string}}

      iex> Peri.except(%{name: :string}, [:missing])
      {:ok, %{name: :string}}
  """
  @spec except(map_schema, [atom | String.t()]) ::
          {:ok, map_schema} | {:error, [Peri.Error.t()]}
  def except(schema, keys) when is_map(schema) and is_list(keys) do
    schema |> Map.drop(keys) |> validate_schema()
  end

  def except(schema, keys) do
    raise ArgumentError,
          "Peri.except/2 expects a map schema and a list of keys, got: " <>
            inspect(schema) <> " and " <> inspect(keys)
  end

  @doc """
  Validates a schema definition to ensure it adheres to the expected structure and types.

  This function can handle both simple and complex schema definitions, including nested schemas, custom validation functions, and various type constraints.

  ## Parameters

    - `schema` - The schema definition to be validated. It can be a map or a keyword list representing the schema.

  ## Returns

    - `{:ok, schema}` - If the schema is valid, returns the original schema.
    - `{:error, errors}` - If the schema is invalid, returns an error tuple with detailed error information.

  ## Examples

    Validating a simple schema:

    ```elixir
    schema = %{
      name: :string,
      age: :integer,
      email: {:required, :string}
    }
    assert {:ok, ^schema} = validate_schema(schema)
    ```

    Validating a nested schema:

    ```elixir
    schema = %{
      user: %{
        name: :string,
        profile: %{
          age: {:required, :integer},
          email: {:required, :string}
        }
      }
    }
    assert {:ok, ^schema} = validate_schema(schema)
    ```

    Handling invalid schema definition:

    ```elixir
    schema = %{
      name: :str,
      age: :integer,
      email: {:required, :string}
    }
    assert {:error, _errors} = validate_schema(schema)
    ```
  """
  def validate_schema(schema) when is_enumerable(schema) do
    case traverse_definition(schema, Peri.Parser.new(schema, root_data: schema)) do
      %Peri.Parser{errors: [], data: data} -> {:ok, data}
      %Peri.Parser{errors: errors} -> {:error, errors}
    end
  end

  def validate_schema(schema) do
    case validate_type(schema, Peri.Parser.new(schema, root_data: schema)) do
      :ok ->
        {:ok, schema}

      {:error, reason, info} ->
        {:error, Peri.Error.new_single(reason, info)}
    end
  end

  defp traverse_definition(schema, state) when is_enumerable(schema) do
    Enum.reduce(schema, state, fn {key, type}, %{path: path} = parser ->
      case validate_type(type, parser) do
        :ok ->
          parser

        {:error, [_ | _] = nested_errs} ->
          reduce_errors(path, key, nested_errs, parser)

        {:error, reason, info} ->
          err = Peri.Error.new_child(path, key, reason, [{:schema, schema} | info])
          Peri.Parser.add_error(parser, err)
      end
    end)
  end

  defp validate_type(nil, _parser), do: :ok
  defp validate_type(:any, _parser), do: :ok
  defp validate_type(:atom, _parser), do: :ok
  defp validate_type(:atom!, _parser), do: :ok
  defp validate_type(:integer, _parser), do: :ok
  defp validate_type(:map, _parser), do: :ok
  defp validate_type(:float, _parser), do: :ok
  defp validate_type(:boolean, _parser), do: :ok
  defp validate_type(:string, _parser), do: :ok
  defp validate_type({:literal, _literal}, _parser), do: :ok
  defp validate_type(:date, _parser), do: :ok
  defp validate_type(:time, _parser), do: :ok
  defp validate_type(:duration, _parser), do: :ok
  defp validate_type(:datetime, _parser), do: :ok
  defp validate_type(:naive_datetime, _parser), do: :ok
  defp validate_type(:pid, _parser), do: :ok
  defp validate_type({type, {:default, _val}}, p), do: validate_type(type, p)
  defp validate_type({:enum, choices}, _) when is_list(choices), do: :ok

  defp validate_type({:enum, choices, enum_opts}, p)
       when is_list(choices) and is_list(enum_opts) do
    cond do
      not Keyword.keyword?(enum_opts) ->
        {:error, "expected enum opts to be a keyword list, got %{actual}",
         actual: inspect(enum_opts)}

      not valid_error_opt?(enum_opts) ->
        {:error, "expected error: opt to be a string or MFA tuple, got %{actual}",
         actual: inspect(Keyword.get(enum_opts, :error))}

      not valid_gen_opt?(enum_opts) ->
        {:error,
         "expected gen: opt to be an MFA tuple, {mod, fun}, or 0-arity function, got %{actual}",
         actual: inspect(Keyword.get(enum_opts, :gen))}

      true ->
        validate_enum_type_opt(enum_opts, p)
    end
  end

  defp validate_type({type, options}, p)
       when is_type_with_multiple_options(type) and is_list(options) do
    cond do
      not valid_error_opt?(options) ->
        {:error, "expected error: opt to be a string or MFA tuple, got %{actual}",
         actual: inspect(Keyword.get(options, :error))}

      not valid_gen_opt?(options) ->
        {:error,
         "expected gen: opt to be an MFA tuple, {mod, fun}, or 0-arity function, got %{actual}",
         actual: inspect(Keyword.get(options, :gen))}

      true ->
        options
        |> Keyword.drop([:error, :gen])
        |> reduce_type_options(type, p)
    end
  end

  defp validate_type({:string, {:regex, %Regex{}}}, _p), do: :ok
  defp validate_type({:string, {:eq, eq}}, _p) when is_binary(eq), do: :ok
  defp validate_type({:string, {:min, min}}, _p) when is_integer(min), do: :ok
  defp validate_type({:string, {:max, max}}, _p) when is_integer(max), do: :ok

  defp validate_type({type, {:eq, val}}, _parer)
       when is_numeric_type(type) and is_numeric(val),
       do: :ok

  defp validate_type({type, {:neq, val}}, _parer)
       when is_numeric_type(type) and is_numeric(val),
       do: :ok

  defp validate_type({type, {:lt, val}}, _parer)
       when is_numeric_type(type) and is_numeric(val),
       do: :ok

  defp validate_type({type, {:lte, val}}, _parer)
       when is_numeric_type(type) and is_numeric(val),
       do: :ok

  defp validate_type({type, {:gt, val}}, _parer)
       when is_numeric_type(type) and is_numeric(val),
       do: :ok

  defp validate_type({type, {:gte, val}}, _parer)
       when is_numeric_type(type) and is_numeric(val),
       do: :ok

  defp validate_type({type, {:range, {min, max}}}, _parer)
       when is_numeric_type(type) and is_numeric(min) and is_numeric(max),
       do: :ok

  defp validate_type({type, {:multiple_of, n}}, _parer)
       when is_numeric_type(type) and is_numeric(n) and n != 0,
       do: :ok

  defp validate_type({type, {:multiple_of, n}}, _parer) when is_numeric_type(type) do
    {:error, "expected :multiple_of value to be a non-zero number, got %{actual}",
     actual: inspect(n)}
  end

  defp validate_type({type, {:transform, mapper}}, p) when is_function(mapper, 1),
    do: validate_type(type, p)

  defp validate_type({type, {:transform, mapper}}, p) when is_function(mapper, 2),
    do: validate_type(type, p)

  defp validate_type({type, {:transform, {_mod, _fun}}}, p),
    do: validate_type(type, p)

  defp validate_type({type, {:transform, {_mod, _fun, args}}}, p) when is_list(args),
    do: validate_type(type, p)

  defp validate_type({type, {:encode, encoder}}, p) when is_function(encoder, 1),
    do: validate_type(type, p)

  defp validate_type({type, {:encode, {mod, fun}}}, p) when is_atom(mod) and is_atom(fun),
    do: validate_type(type, p)

  defp validate_type({type, {:encode, {mod, fun, args}}}, p)
       when is_atom(mod) and is_atom(fun) and is_list(args),
       do: validate_type(type, p)

  defp validate_type({:coerce, target}, p),
    do: validate_coerce_type(:string, target, [], p)

  defp validate_type({:coerce, target, coerce_opts}, p) when is_list(coerce_opts),
    do: validate_coerce_type(:string, target, coerce_opts, p)

  defp validate_type({:coerce, source, target}, p),
    do: validate_coerce_type(source, target, [], p)

  defp validate_type({:coerce, source, target, coerce_opts}, p) when is_list(coerce_opts),
    do: validate_coerce_type(source, target, coerce_opts, p)

  defp validate_type({:coerce, _source, _target, coerce_opts}, _p) do
    {:error, "expected coerce opts to be a keyword list, got %{actual}",
     actual: inspect(coerce_opts)}
  end

  defp validate_type({:required, {type, {:default, val}}}, _) do
    template = "cannot set default value of %{value} for required field of type %{type}"
    {:error, template, [value: val, type: summarize(type)]}
  end

  defp validate_type({:meta, type, meta_opts}, p) when is_list(meta_opts) do
    cond do
      not Keyword.keyword?(meta_opts) ->
        {:error, "expected meta opts to be a keyword list, got %{actual}",
         actual: inspect(meta_opts)}

      not valid_gen_opt?(meta_opts) ->
        {:error,
         "expected gen: opt to be an MFA tuple, {mod, fun}, or 0-arity function, got %{actual}",
         actual: inspect(Keyword.get(meta_opts, :gen))}

      true ->
        validate_type(type, p)
    end
  end

  defp validate_type({:meta, _type, meta_opts}, _p) do
    {:error, "expected meta opts to be a keyword list, got %{actual}", actual: inspect(meta_opts)}
  end

  defp validate_type({:ref, name}, _p) when is_atom(name), do: :ok

  defp validate_type({:ref, {mod, name}}, _p) when is_atom(mod) and is_atom(name), do: :ok

  defp validate_type({:multi, field, branches}, p)
       when is_atom(field) and is_map(branches) do
    Enum.reduce_while(branches, :ok, fn {_tag, branch}, :ok ->
      case validate_type(branch, p) do
        :ok -> {:cont, :ok}
        err -> {:halt, err}
      end
    end)
  end

  defp validate_type({:multi, field, _branches}, _p) when not is_atom(field) do
    {:error, "expected :multi dispatch field to be an atom, got %{actual}",
     actual: inspect(field)}
  end

  defp validate_type({:multi, _field, branches}, _p) when not is_map(branches) do
    {:error, "expected :multi branches to be a map, got %{actual}", actual: inspect(branches)}
  end

  defp validate_type({:required, type}, p), do: validate_type(type, p)

  defp validate_type({:required, type, opts}, p) when is_list(opts) do
    cond do
      not Keyword.keyword?(opts) ->
        {:error, "expected required opts to be a keyword list, got %{actual}",
         actual: inspect(opts)}

      not valid_error_opt?(opts) ->
        {:error, "expected error: opt to be a string or MFA tuple, got %{actual}",
         actual: inspect(Keyword.get(opts, :error))}

      not valid_gen_opt?(opts) ->
        {:error,
         "expected gen: opt to be an MFA tuple, {mod, fun}, or 0-arity function, got %{actual}",
         actual: inspect(Keyword.get(opts, :gen))}

      true ->
        validate_type(type, p)
    end
  end

  defp validate_type({:list, type}, p), do: validate_type(type, p)

  defp validate_type({:list, type, list_opts}, p) when is_list(list_opts) do
    cond do
      not Keyword.keyword?(list_opts) ->
        {:error, "expected list opts to be a keyword list, got %{actual}",
         actual: inspect(list_opts)}

      not valid_list_opts?(list_opts) ->
        {:error, "invalid list constraint, allowed: :min, :max, :unique; got %{actual}",
         actual: inspect(list_opts)}

      true ->
        validate_type(type, p)
    end
  end

  defp validate_type({:map, type}, p), do: validate_type(type, p)

  defp validate_type({:map, key_type, value_type}, p) do
    with :ok <- validate_type(key_type, p) do
      validate_type(value_type, p)
    end
  end

  defp validate_type({:schema, type}, p), do: validate_type(type, p)

  defp validate_type({:schema, type, {:additional_keys, value_type}}, p) when is_map(type) do
    with :ok <- validate_type(type, p) do
      validate_type(value_type, p)
    end
  end

  defp validate_type({:schema, type, schema_opts}, p) when is_list(schema_opts) do
    cond do
      not Keyword.keyword?(schema_opts) ->
        {:error, "expected :schema opts to be a keyword list, got %{actual}",
         actual: inspect(schema_opts)}

      not is_binary(Keyword.get(schema_opts, :name, "")) and
          not is_atom(Keyword.get(schema_opts, :name)) ->
        {:error, "expected :schema name to be a binary or atom, got %{actual}",
         actual: inspect(Keyword.get(schema_opts, :name))}

      true ->
        validate_type(type, p)
    end
  end

  defp validate_type({:custom, cb}, _) when is_function(cb, 1), do: :ok
  defp validate_type({:custom, {mod, fun}}, _) when is_atom(mod) and is_atom(fun), do: :ok

  defp validate_type({:custom, {mod, fun, args}}, _)
       when is_atom(mod) and is_atom(fun) and is_list(args),
       do: :ok

  defp validate_type({:cond, cb, type, else_type}, p)
       when is_function(cb, 1) or is_function(cb, 2) do
    with :ok <- validate_type(type, p) do
      validate_type(else_type, p)
    end
  end

  defp validate_type({:dependent, cb}, _) when is_function(cb, 1) or is_function(cb, 2), do: :ok

  defp validate_type({:dependent, {mod, fun}}, _) when is_atom(mod) and is_atom(fun), do: :ok

  defp validate_type({:dependent, {mod, fun, args}}, _)
       when is_atom(mod) and is_atom(fun) and is_list(args),
       do: :ok

  defp validate_type({:dependent, _, cb, type}, p) when is_function(cb, 2) do
    validate_type(type, p)
  end

  defp validate_type({:tuple, types}, p) do
    Enum.reduce_while(types, :ok, fn type, :ok ->
      case validate_type(type, p) do
        :ok -> {:cont, :ok}
        {:error, errors} -> {:halt, {:error, errors}}
        {:error, template, info} -> {:halt, {:error, template, info}}
      end
    end)
  end

  defp validate_type({:either, {type_1, type_2}}, p) do
    with :ok <- validate_type(type_1, p) do
      validate_type(type_2, p)
    end
  end

  defp validate_type({:oneof, types}, p) do
    Enum.reduce_while(types, :ok, fn type, :ok ->
      case validate_type(type, p) do
        :ok -> {:cont, :ok}
        {:error, errors} -> {:halt, {:error, errors}}
        {:error, template, info} -> {:halt, {:error, template, info}}
      end
    end)
  end

  defp validate_type(schema, p) when is_enumerable(schema) do
    case traverse_definition(schema, p) do
      %Peri.Parser{errors: []} -> :ok
      %Peri.Parser{errors: errors} -> {:error, errors}
    end
  end

  defp validate_type(invalid, _p) do
    invalid = inspect(invalid, pretty: true)
    {:error, "invalid schema definition: %{invalid}", invalid: invalid}
  end

  defp reduce_type_options(options, type, p) do
    Enum.reduce_while(options, :ok, fn option, :ok ->
      case validate_type({type, option}, p) do
        :ok -> {:cont, :ok}
        {:error, errors} -> {:halt, {:error, errors}}
        {:error, template, info} -> {:halt, {:error, template, info}}
      end
    end)
  end

  @coerce_string_targets [
    :integer,
    :float,
    :boolean,
    :atom,
    :atom!,
    :date,
    :time,
    :naive_datetime,
    :datetime
  ]

  defp validate_coerce_type(source, target, coerce_opts, p) do
    with :ok <- validate_coerce_source(source),
         :ok <- validate_coerce_target(source, target),
         :ok <- validate_coerce_opts(coerce_opts),
         :ok <- validate_coerce_list_split(source, target, coerce_opts),
         do: validate_type(target, p)
  end

  defp validate_coerce_list_split(:string, {:list, _inner}, coerce_opts),
    do: require_split_opt(coerce_opts)

  defp validate_coerce_list_split(:string, {:list, _inner, list_opts}, coerce_opts)
       when is_list(list_opts),
       do: require_split_opt(coerce_opts)

  defp validate_coerce_list_split(_source, _target, _coerce_opts), do: :ok

  defp require_split_opt(coerce_opts) do
    if Keyword.has_key?(coerce_opts, :split) do
      :ok
    else
      {:error,
       "expected split: opt when coercing from :string to a list target, e.g. {:coerce, {:list, :integer}, split: \",\"}",
       []}
    end
  end

  defp validate_coerce_source(:string), do: :ok
  defp validate_coerce_source(fun) when is_function(fun, 1), do: :ok

  defp validate_coerce_source({mod, fun}) when is_atom(mod) and is_atom(fun), do: :ok

  defp validate_coerce_source({mod, fun, args})
       when is_atom(mod) and is_atom(fun) and is_list(args),
       do: :ok

  defp validate_coerce_source(other) do
    {:error,
     "expected coerce source to be :string, a 1-arity function, or an MFA tuple, got %{actual}",
     actual: inspect(other)}
  end

  defp validate_coerce_target(:string, target) do
    if coerce_string_target?(target) do
      :ok
    else
      {:error,
       "expected coerce target for :string source to be one of %{targets}, an {:enum, ...}, a {:literal, ...}, or a {:list, ...} of those, got %{actual}",
       targets: inspect(@coerce_string_targets), actual: summarize(target)}
    end
  end

  defp validate_coerce_target(_source, _target), do: :ok

  defp coerce_string_target?(target) when target in @coerce_string_targets, do: true

  defp coerce_string_target?({target, _opts}) when target in @coerce_string_targets, do: true

  defp coerce_string_target?({:enum, choices}) when is_list(choices), do: true

  defp coerce_string_target?({:enum, choices, enum_opts})
       when is_list(choices) and is_list(enum_opts),
       do: true

  defp coerce_string_target?({:literal, literal})
       when is_atom(literal) or is_binary(literal) or is_number(literal),
       do: true

  defp coerce_string_target?({:list, inner}), do: coerce_string_target?(inner)

  defp coerce_string_target?({:list, inner, list_opts}) when is_list(list_opts),
    do: coerce_string_target?(inner)

  defp coerce_string_target?(_target), do: false

  defp validate_coerce_opts(opts) do
    cond do
      not Keyword.keyword?(opts) ->
        {:error, "expected coerce opts to be a keyword list, got %{actual}",
         actual: inspect(opts)}

      not valid_coerce_encode_opt?(opts) ->
        {:error, "expected encode: opt to be a 1-arity function or an MFA tuple, got %{actual}",
         actual: inspect(Keyword.get(opts, :encode))}

      not valid_coerce_split_opt?(opts) ->
        {:error, "expected split: opt to be a string or a list of strings, got %{actual}",
         actual: inspect(Keyword.get(opts, :split))}

      Keyword.keys(opts) -- [:encode, :split] != [] ->
        {:error, "unknown coerce opts %{actual}, only :encode and :split are allowed",
         actual: inspect(Keyword.keys(opts) -- [:encode, :split])}

      true ->
        :ok
    end
  end

  defp valid_coerce_split_opt?(opts) do
    case Keyword.fetch(opts, :split) do
      :error -> true
      {:ok, separator} when is_binary(separator) -> true
      {:ok, [_ | _] = separators} -> Enum.all?(separators, &is_binary/1)
      {:ok, _} -> false
    end
  end

  defp valid_coerce_encode_opt?(opts) do
    case Keyword.fetch(opts, :encode) do
      :error -> true
      {:ok, fun} when is_function(fun, 1) -> true
      {:ok, {mod, fun}} when is_atom(mod) and is_atom(fun) -> true
      {:ok, {mod, fun, args}} when is_atom(mod) and is_atom(fun) and is_list(args) -> true
      {:ok, _} -> false
    end
  end

  if Code.ensure_loaded?(Ecto) do
    @doc """
    Converts a `Peri.schema()` definition to an Ecto [schemaless changesets](https://hexdocs.pm/ecto/Ecto.Changeset.html#module-schemaless-changesets).
    """
    @spec to_changeset!(schema, attrs :: map) :: Ecto.Changeset.t()
    def to_changeset!(s, _attrs) when not is_map(s) do
      raise Peri.Error,
        message:
          "currently Ecto doesn't support raw data structures or keyword lists validation, only maps"
    end

    def to_changeset!(%{} = s, %{} = attrs) do
      with {:error, err} <- Peri.validate_schema(s) do
        raise Peri.Error, err
      end

      definition = Peri.Ecto.parse(s)
      process_changeset(definition, attrs)
    end

    defp process_changeset(definition, attrs) do
      nested =
        definition
        |> Enum.map(fn {key, def} -> {key, Map.take(def, [:type, :nested])} end)
        |> Enum.filter(fn {_, def} -> def.nested end)

      nested_keys = Enum.map(nested, fn {key, _} -> key end)

      # Also exclude fields that need special validation
      special_keys =
        definition
        |> Enum.filter(fn {_, def} ->
          def[:type] == :any || def[:conditional]
        end)
        |> Enum.map(fn {key, _} -> key end)

      {process_defaults(definition), process_types(definition)}
      |> Ecto.Changeset.cast(attrs, Map.keys(definition) -- (nested_keys ++ special_keys))
      |> process_special_fields(special_keys, attrs, definition)
      |> process_validations(definition)
      |> process_required(definition)
      |> process_nested(nested, attrs)
    end

    defp process_defaults(definition) do
      definition
      |> Enum.map(fn {key, %{default: val}} -> {key, val} end)
      |> Enum.filter(fn {_key, default} -> default end)
      |> Map.new()
    end

    defp process_types(definition) do
      Map.new(definition, fn
        # Handle special cases for conditional and dependent types
        {key, %{condition: _} = def} -> {key, def[:type] || :string}
        {key, %{dependent_callback: _} = def} -> {key, def[:type] || :string}
        {key, %{depend: _} = def} -> {key, def[:type] || :string}
        # Handle cases where type is nil (either types sometimes don't set it)
        {key, %{type: nil} = _def} -> {key, :string}
        # Normal types
        {key, %{type: type}} -> {key, type}
        # Default fallback for any other pattern
        {key, _def} -> {key, :string}
      end)
    end

    defp process_required(changeset, definition) do
      # Get required fields, but exclude nested fields and conditional fields that will be processed separately
      required =
        definition
        |> Enum.filter(fn
          {_key, def} ->
            def[:required] == true &&
              is_nil(def[:nested]) &&
              not Map.get(def, :conditional, false)
        end)
        |> Enum.map(fn {key, _} -> key end)

      Ecto.Changeset.validate_required(changeset, required)
    end

    defp process_validations(changeset, definition) do
      Enum.reduce(definition, changeset, fn {_, %{validations: vals}}, acc ->
        for validation <- vals, reduce: acc do
          changeset -> validation.(changeset)
        end
      end)
    end

    defp process_nested(changeset, nested, attrs) do
      Enum.reduce(nested, changeset, &handle_nested(&1, &2, attrs))
    end

    defp handle_nested({key, def}, changeset, attrs) do
      value = get_nested_value(attrs, key)

      # First check if this nested field is required but missing
      if def[:required] && is_nil(value) do
        Ecto.Changeset.add_error(changeset, key, "can't be blank", validation: :required)
      else
        cond do
          def[:conditional] && def[:nested] ->
            # Let the validation handle it
            changeset

          match?({:embed, %{cardinality: _}}, def[:type]) ->
            {:embed, %{cardinality: cardinality}} = def[:type]
            validate_and_cast_nested(changeset, key, value, def[:nested], cardinality)

          match?({:parameterized, {Peri.Ecto.Type.OneOf, _}}, def[:type]) ->
            validate_composite_nested(changeset, key, value, def[:nested])

          match?({:parameterized, {Peri.Ecto.Type.Either, _}}, def[:type]) ->
            validate_composite_nested(changeset, key, value, def[:nested])

          true ->
            changeset
        end
      end
    end

    defp get_nested_value(attrs, key) do
      Map.get(attrs, key) || Map.get(attrs, to_string(key))
    end

    defp validate_and_cast_nested(changeset, _key, nil, _schema, _cardinality), do: changeset

    defp validate_and_cast_nested(changeset, key, value, schema, :one) do
      nested = process_changeset(schema, value)
      cast_nested_result(changeset, key, nested)
    end

    defp validate_and_cast_nested(changeset, key, values, schema, :many) when is_list(values) do
      results = Enum.map(values, &process_changeset(schema, &1))
      cast_nested_list_result(changeset, key, results)
    end

    defp validate_and_cast_nested(changeset, key, _value, _schema, :many) do
      Ecto.Changeset.add_error(changeset, key, "is invalid")
    end

    defp validate_composite_nested(changeset, _key, nil, _schemas), do: changeset

    defp validate_composite_nested(changeset, key, value, schemas) when is_map(value) do
      schemas
      |> Enum.find_value(fn {_, schema} ->
        case Peri.validate(schema, value) do
          {:ok, _} -> process_changeset(schema, value)
          _ -> nil
        end
      end)
      |> case do
        nil -> changeset
        nested -> cast_nested_result(changeset, key, nested)
      end
    end

    defp validate_composite_nested(changeset, _key, _value, _schemas), do: changeset

    defp process_special_fields(changeset, special_keys, attrs, definition) do
      Enum.reduce(special_keys, changeset, fn key, acc ->
        value = get_nested_value(attrs, key)
        process_special_field(acc, key, value, definition)
      end)
    end

    defp process_special_field(changeset, _key, nil, _definition), do: changeset

    defp process_special_field(changeset, key, value, _definition) do
      Ecto.Changeset.put_change(changeset, key, value)
    end

    defp cast_nested_result(changeset, key, nested) do
      if nested.valid? do
        # Keep the changeset in changes so get_change returns a changeset
        changes = Map.put(changeset.changes, key, nested)
        %{changeset | changes: changes, valid?: changeset.valid?}
      else
        transfer_nested_errors(changeset, key, nested)
      end
    end

    defp cast_nested_list_result(changeset, key, results) do
      all_valid =
        Enum.all?(results, fn
          %Ecto.Changeset{} = cs -> cs.valid?
          _ -> true
        end)

      if all_valid do
        # For valid results, keep the changesets in changes
        changes = Map.put(changeset.changes, key, results)
        %{changeset | changes: changes, valid?: changeset.valid?}
      else
        # For lists with errors, maintain the changeset structure
        changes = Map.put(changeset.changes, key, results)
        %{changeset | changes: changes, valid?: false}
      end
    end

    defp transfer_nested_errors(changeset, key, nested) do
      # For nested changesets, we need to put the invalid changeset in changes
      # so that traverse_errors can find it
      changes = Map.put(changeset.changes, key, nested)
      %{changeset | changes: changes, valid?: false}
    end
  end

  # Helper functions

  # Normalize validation results to handle different error formats
  defp normalize_validation_result(:ok), do: :ok
  defp normalize_validation_result({:ok, val}), do: {:ok, val}
  defp normalize_validation_result({:error, reason, info}), do: {:error, [reason, info]}
  defp normalize_validation_result({:error, errors}), do: {:error, errors}

  defp reduce_errors(path, key, [_ | _] = errors, parser) do
    Enum.reduce(errors, parser, fn
      %Peri.Error{} = err, parser ->
        err
        |> Peri.Error.update_error_paths(path ++ [key])
        |> then(&Peri.Error.new_parent(path, key, [&1]))
        |> then(&Peri.Parser.add_error(parser, &1))

      {:error, reason, info}, parser ->
        err = Peri.Error.new_child(path, key, reason, info)
        Peri.Parser.add_error(parser, err)
    end)
  end
end
