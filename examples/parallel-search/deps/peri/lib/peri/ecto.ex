if Code.ensure_loaded?(Ecto) do
  defmodule Peri.Ecto do
    @moduledoc false

    import Ecto.Changeset

    alias Ecto.Embedded, as: Embed
    alias Peri.Ecto.Type

    @type validation ::
            {:eq, integer | float | String.t()}
            | {:neq, integer | float}
            | {:lt, integer | float}
            | {:lte, integer | float}
            | {:gt, integer | float}
            | {:gte, integer | float}
            | {:min, length :: integer}
            | {:max, length :: integer}
            | {:regex, pattern :: Regex.t()}
            | {:range, {min :: integer | float, max :: integer | float}}

    @type def :: %{
            atom => %{
              type: term,
              required: boolean,
              depend: path :: list(atom),
              default: term,
              validations: list(validation),
              nested: %{atom => def}
            }
          }

    defguard is_ecto_embed(data) when elem(data, 0) == :embed or elem(data, 0) == :parameterized

    def parse(%{} = schema) do
      init =
        Map.new(Map.keys(schema), fn key ->
          {key,
           %{
             required: nil,
             default: nil,
             validations: [],
             nested: nil
           }}
        end)

      Enum.reduce(schema, init, &parse_peri/2)
    end

    @raw_types ~w(atom string integer float boolean map date time datetime naive_datetime pid)a

    for type <- @raw_types do
      def parse_peri({key, unquote(type)}, ecto) do
        put_in(ecto[key][:type], Type.from(unquote(type)))
      end
    end

    def parse_peri({key, {:enum, _} = type}, ecto) do
      put_in(ecto[key][:type], Type.from(type))
    end

    def parse_peri({key, {:required, type}}, ecto) do
      ecto = put_in(ecto[key][:required], true)
      parse_peri({key, type}, ecto)
    end

    def parse_peri({key, {:meta, type, _opts}}, ecto) do
      parse_peri({key, type}, ecto)
    end

    # Refs degrade to :map on the changeset side. Recursive schemas can't
    # be expressed as a fixed Ecto type; treating refs as opaque maps lets
    # changeset generation succeed without losing the validation path
    # (Peri.validate/2 still resolves the ref properly).
    def parse_peri({key, {:ref, _}}, ecto) do
      parse_peri({key, :map}, ecto)
    end

    def parse_peri({key, {type, {:default, {mod, fun}}}}, ecto) do
      put_in(ecto[key][:default], apply(mod, fun, []))
      |> then(&parse_peri({key, type}, &1))
    end

    def parse_peri({key, {type, {:default, {mod, fun, args}}}}, ecto) do
      put_in(ecto[key][:default], apply(mod, fun, args))
      |> then(&parse_peri({key, type}, &1))
    end

    def parse_peri({key, {type, {:default, val}}}, ecto) do
      put_in(ecto[key][:default], val)
      |> then(&parse_peri({key, type}, &1))
    end

    def parse_peri({key, {:string, {:regex, regex}}}, ecto) do
      put_validation(ecto, key, fn changeset ->
        validate_format(changeset, key, regex)
      end)
      |> then(&parse_peri({key, :string}, &1))
    end

    def parse_peri({key, {:string, {:eq, eq}}}, ecto) do
      validation =
        &validate_change(&1, key, fn ^key, val ->
          if val === eq, do: [], else: [{key, "should be equal to literal #{eq}"}]
        end)

      put_validation(ecto, key, validation)
      |> then(&parse_peri({key, :string}, &1))
    end

    def parse_peri({key, {:string, {:min, min}}}, ecto) do
      put_validation(ecto, key, fn changeset ->
        validate_length(changeset, key, min: min)
      end)
      |> then(&parse_peri({key, :string}, &1))
    end

    def parse_peri({key, {:string, {:max, max}}}, ecto) do
      put_validation(ecto, key, fn changeset ->
        validate_length(changeset, key, max: max)
      end)
      |> then(&parse_peri({key, :string}, &1))
    end

    @number_checks [
      eq: :equal_to,
      neq: :not_equal_to,
      lt: :less_than,
      gt: :greater_than,
      lte: :less_than_or_equal_to,
      gte: :greater_than_or_equal_to
    ]

    for type <- [:integer, :float], {peri, check} <- @number_checks do
      def parse_peri({key, {unquote(type), {unquote(peri), val}}}, ecto) do
        put_validation(ecto, key, fn changeset ->
          validate_number(changeset, key, [{unquote(check), val}])
        end)
        |> then(&parse_peri({key, unquote(type)}, &1))
      end
    end

    for type <- [:integer, :float] do
      def parse_peri({key, {unquote(type), {:range, {min, max}}}}, ecto) do
        put_validation(ecto, key, fn changeset ->
          validate_number(changeset, key,
            greater_than_or_equal_to: min,
            less_than_or_equal_to: max
          )
        end)
        |> then(&parse_peri({key, unquote(type)}, &1))
      end
    end

    def parse_peri({key, {:list, type}}, ecto) when is_map(type) do
      ecto = put_in(ecto[key][:nested], parse(type))
      put_in(ecto[key][:type], embed_many(key))
    end

    def parse_peri({key, {:list, type}}, ecto) do
      put_in(ecto[key][:type], {:array, Type.from(type)})
    end

    def parse_peri({key, {:map, value_type}}, ecto) when is_atom(value_type) do
      ecto = put_in(ecto[key][:type], :map)
      put_validation(ecto, key, map_value_validation(key, value_type))
    end

    def parse_peri({key, {:map, key_type, value_type}}, ecto) do
      ecto = put_in(ecto[key][:type], :map)
      put_validation(ecto, key, map_key_value_validation(key, key_type, value_type))
    end

    def parse_peri({key, {:tuple, types}}, ecto) when is_list(types) do
      ecto = put_in(ecto[key][:type], Type.from({:tuple, types}))

      put_validation(ecto, key, fn changeset ->
        validate_tuple(changeset, key, types)
      end)
    end

    def parse_peri({key, type}, ecto) when is_map(type) do
      ecto = put_in(ecto[key][:nested], parse(type))
      put_in(ecto[key][:type], embed_one(key))
    end

    def parse_peri({key, {type, {:transform, mapper}}}, ecto) when is_function(mapper, 1) do
      ecto = parse_peri({key, type}, ecto)

      put_validation(ecto, key, fn changeset ->
        update_change(changeset, key, mapper)
      end)
    end

    def parse_peri({key, {type, {:transform, {mod, fun}}}}, ecto)
        when is_atom(mod) and is_atom(fun) do
      ecto = parse_peri({key, type}, ecto)

      put_validation(ecto, key, fn changeset ->
        update_change(changeset, key, &apply(mod, fun, [&1]))
      end)
    end

    def parse_peri({key, {type, {:transform, {mod, fun, args}}}}, ecto)
        when is_atom(mod) and is_atom(fun) and is_list(args) do
      ecto = parse_peri({key, type}, ecto)

      put_validation(ecto, key, fn changeset ->
        update_change(changeset, key, &apply(mod, fun, [&1 | args]))
      end)
    end

    def parse_peri({key, {:either, {fst, snd}}}, ecto) do
      nested_schemas = %{}

      nested_schemas =
        if is_map(fst) do
          Map.put(nested_schemas, "map_fst", parse(fst))
        else
          nested_schemas
        end

      nested_schemas =
        if is_map(snd) do
          Map.put(nested_schemas, "map_snd", parse(snd))
        else
          nested_schemas
        end

      ecto =
        if map_size(nested_schemas) > 0 do
          put_in(ecto[key][:nested], nested_schemas)
        else
          ecto
        end

      # If we have nested schemas, we need custom validation because Either type
      # doesn't handle nested schemas well
      if map_size(nested_schemas) > 0 do
        ecto = put_in(ecto[key][:type], :any)
        ecto = put_in(ecto[key][:original_fst], fst)
        ecto = put_in(ecto[key][:original_snd], snd)

        put_validation(ecto, key, fn changeset ->
          validate_either_with_nested(changeset, key, fst, snd, nested_schemas)
        end)
      else
        # Use the Either type for simple types
        put_in(ecto[key][:type], Type.from({:either, {fst, snd}}))
      end
    end

    def parse_peri({key, {:oneof, types}}, ecto) when is_list(types) do
      if Enum.any?(types, &is_map/1) do
        {map_types, other_types} = Enum.split_with(types, &is_map/1)

        nested_schemas =
          Map.new(map_types, fn map_type ->
            {"map_#{System.unique_integer([:positive])}", parse(map_type)}
          end)

        ecto = put_in(ecto[key][:nested], nested_schemas)

        ecto = put_in(ecto[key][:original_types], types)

        # Always use validate_oneof_nested for validation
        ecto = put_in(ecto[key][:type], :any)

        put_validation(ecto, key, fn changeset ->
          validate_oneof_nested(changeset, key, map_types, other_types, types)
        end)
      else
        # For oneof without maps, use the OneOf type which handles validation
        put_in(ecto[key][:type], Type.from({:oneof, types}))
      end
    end

    def parse_peri({key, {:cond, condition, true_type, else_type}}, ecto) do
      true_branch = parse_single_type(true_type)
      else_branch = parse_single_type(else_type)

      # Store the nested schemas if they exist
      ecto =
        if true_branch[:nested] || else_branch[:nested] do
          ecto
          |> put_in([key, :nested], %{
            "true_branch" => true_branch[:nested],
            "else_branch" => else_branch[:nested]
          })
          |> put_in([key, :type], :any)
          |> put_in([key, :conditional], true)
        else
          ecto
          |> put_in([key, :type], true_branch[:type] || :string)
          |> put_in([key, :conditional], true)
        end

      put_validation(ecto, key, fn changeset ->
        validate_conditional_field(
          changeset,
          key,
          condition,
          true_branch,
          else_branch,
          true_type,
          else_type
        )
      end)
    end

    def parse_peri({key, {:dependent, field, condition, type}}, ecto) when is_atom(field) do
      ecto = put_in(ecto[key][:depend], field)
      ecto = put_in(ecto[key][:condition], condition)
      type_ecto = parse_single_type(type)
      ecto = put_in(ecto[key][:type], type_ecto[:type])

      ecto =
        if type_ecto[:nested] do
          put_in(ecto[key][:nested], type_ecto[:nested])
        else
          ecto
        end

      put_validation(ecto, key, fn changeset ->
        dep_field_value = get_field(changeset, field)
        current_value = get_field(changeset, key)

        case condition.(current_value, dep_field_value) do
          :ok ->
            changeset

          {:error, message, context} ->
            add_error(changeset, key, message, context)
        end
      end)
    end

    def parse_peri({key, {:dependent, callback}}, ecto) when is_function(callback, 1) do
      ecto = put_in(ecto[key][:type], :any)

      put_validation(ecto, key, fn changeset ->
        validate_dependent_callback_field(changeset, key, callback)
      end)
    end

    def parse_peri({key, {:dependent, {mod, fun}}}, ecto) when is_atom(mod) and is_atom(fun) do
      callback = fn data -> apply(mod, fun, [data]) end
      parse_peri({key, {:dependent, callback}}, ecto)
    end

    def parse_peri({key, {:dependent, {mod, fun, args}}}, ecto)
        when is_atom(mod) and is_atom(fun) and is_list(args) do
      callback = fn data -> apply(mod, fun, [data | args]) end
      parse_peri({key, {:dependent, callback}}, ecto)
    end

    def parse_peri({key, {:custom, callback}}, ecto) when is_function(callback, 1) do
      ecto = put_in(ecto[key][:type], :any)
      put_validation(ecto, key, custom_validation(key, callback))
    end

    def parse_peri({key, {:custom, {mod, fun}}}, ecto) when is_atom(mod) and is_atom(fun) do
      callback = fn value -> apply(mod, fun, [value]) end
      parse_peri({key, {:custom, callback}}, ecto)
    end

    def parse_peri({key, {:custom, {mod, fun, args}}}, ecto)
        when is_atom(mod) and is_atom(fun) and is_list(args) do
      callback = fn value -> apply(mod, fun, [value | args]) end
      parse_peri({key, {:custom, callback}}, ecto)
    end

    def parse_peri({key, {:literal, literal}}, ecto) do
      ecto = put_in(ecto[key][:literal], literal)
      ecto = put_in(ecto[key][:type], literal_type(literal))
      put_validation(ecto, key, literal_validation(key, literal))
    end

    def parse_peri({key, type}, _ecto) do
      type = inspect(type, pretty: true)
      raise Peri.Error, message: "Ecto doesn't support `#{type}` type for #{key}"
    end

    defp literal_type(s) when is_binary(s), do: :string
    defp literal_type(i) when is_integer(i), do: :integer
    defp literal_type(f) when is_float(f), do: :float
    defp literal_type(b) when is_boolean(b), do: :boolean
    defp literal_type(a) when is_atom(a), do: Type.from(:atom)
    defp literal_type(_), do: :string

    defp literal_validation(key, literal) do
      fn changeset ->
        validate_change(changeset, key, fn ^key, val ->
          validate_literal_value(val, literal, key)
        end)
      end
    end

    defp validate_literal_value(val, literal, _key) when val === literal, do: []

    defp validate_literal_value(val, literal, key) do
      [{key, "expected literal value #{inspect(literal)} but got #{inspect(val)}"}]
    end

    defp validate_map_key(key, :atom) when is_atom(key), do: :ok
    defp validate_map_key(key, :string) when is_binary(key), do: :ok
    defp validate_map_key(key, :integer) when is_integer(key), do: :ok
    defp validate_map_key(_key, type), do: {:error, "expected #{type}"}

    defp validate_map_value(value, :string) when is_binary(value), do: :ok
    defp validate_map_value(value, :integer) when is_integer(value), do: :ok
    defp validate_map_value(value, :float) when is_float(value), do: :ok
    defp validate_map_value(value, :boolean) when is_boolean(value), do: :ok
    defp validate_map_value(value, :atom) when is_atom(value), do: :ok
    defp validate_map_value(_value, type), do: {:error, "expected #{type}"}

    defp map_value_validation(key, value_type) do
      fn changeset ->
        validate_change(changeset, key, fn ^key, val when is_map(val) ->
          validate_map_values(val, key, value_type)
        end)
      end
    end

    defp validate_map_values(map, key, value_type) do
      has_errors =
        Enum.any?(map, fn {_k, v} ->
          match?({:error, _}, validate_map_value(v, value_type))
        end)

      if has_errors, do: [{key, "is invalid"}], else: []
    end

    defp map_key_value_validation(field_key, key_type, value_type) do
      fn changeset ->
        validate_change(changeset, field_key, fn ^field_key, val when is_map(val) ->
          collect_map_errors(val, field_key, key_type, value_type)
        end)
      end
    end

    defp collect_map_errors(map, field_key, key_type, value_type) do
      Enum.flat_map(map, fn {k, v} ->
        collect_entry_errors(k, v, field_key, key_type, value_type)
      end)
    end

    defp collect_entry_errors(k, v, field_key, key_type, value_type) do
      key_errors = validate_map_key_errors(k, field_key, key_type)
      value_errors = validate_map_value_errors(v, field_key, value_type)
      key_errors ++ value_errors
    end

    defp validate_map_key_errors(k, field_key, key_type) do
      case validate_map_key(k, key_type) do
        :ok -> []
        {:error, msg} -> [{field_key, "invalid key type: #{msg}"}]
      end
    end

    defp validate_map_value_errors(v, field_key, value_type) do
      case validate_map_value(v, value_type) do
        :ok -> []
        {:error, msg} -> [{field_key, "invalid value type: #{msg}"}]
      end
    end

    defp custom_validation(key, callback) do
      fn changeset ->
        value = get_field(changeset, key)

        if is_nil(value) do
          changeset
        else
          handle_custom_result(changeset, key, callback.(value))
        end
      end
    end

    defp handle_custom_result(changeset, _key, :ok), do: changeset
    defp handle_custom_result(changeset, _key, {:ok, _}), do: changeset

    defp handle_custom_result(changeset, key, {:error, message, context}) do
      context = if is_list(context), do: context, else: []
      add_error(changeset, key, message, context)
    end

    # Helper function to validate either type with nested schemas
    defp validate_either_with_nested(changeset, key, fst, snd, _nested_schemas) do
      value = get_field(changeset, key)

      if is_nil(value) do
        changeset
      else
        fst_valid = validate_either_nested_branch(value, fst)
        snd_valid = validate_either_nested_branch(value, snd)

        if fst_valid or snd_valid do
          changeset
        else
          add_error(changeset, key, "is invalid")
        end
      end
    end

    defp validate_either_nested_branch(value, schema) when is_map(schema) do
      match?({:ok, _}, Peri.validate(schema, value))
    end

    defp validate_either_nested_branch(value, type) do
      case Ecto.Type.cast(Peri.Ecto.Type.from(type), value) do
        {:ok, _} -> true
        _ -> false
      end
    end

    defp validate_conditional_field(
           changeset,
           key,
           condition,
           true_branch,
           else_branch,
           _true_type,
           _else_type
         ) do
      data = apply_changes(changeset)

      if condition.(data) do
        apply_conditional_validation(changeset, key, true_branch)
      else
        apply_conditional_validation(changeset, key, else_branch)
      end
    end

    defp validate_dependent_callback_field(changeset, key, callback) do
      data = apply_changes(changeset)

      case callback.(data) do
        {:ok, nil} ->
          changeset

        {:ok, schema_def} ->
          validate_with_dynamic_schema(changeset, key, schema_def)

        {:error, error_msg, context} ->
          context = if is_list(context), do: context, else: []
          add_error(changeset, key, error_msg, context)
      end
    end

    defp validate_with_dynamic_schema(changeset, key, schema_def) do
      case Peri.validate_schema(schema_def) do
        {:ok, valid_schema} ->
          parsed_schema = parse_single_type(valid_schema)
          apply_dependent_validation(changeset, key, parsed_schema)

        {:error, errors} ->
          Enum.reduce(errors, changeset, fn error, acc ->
            add_error(acc, key, "Invalid schema: #{inspect(error)}")
          end)
      end
    end

    defp put_validation(ecto, key, validation) do
      update_in(ecto[key][:validations], &[validation | &1])
    end

    defp validate_tuple(changeset, key, types) do
      validate_change(changeset, key, fn ^key, val ->
        case Peri.validate({:tuple, types}, val) do
          {:ok, _} ->
            []

          {:error, errors} when is_list(errors) ->
            [{key, "is invalid"}]

          {:error, msg} when is_binary(msg) ->
            [{key, msg}]

          {:error, _} ->
            [{key, "is invalid"}]
        end
      end)
    end

    defp embed_one(key) do
      {:embed, Embed.init(field: key, cardinality: :one, related: nil)}
    end

    defp embed_many(key) do
      {:embed, Embed.init(field: key, cardinality: :many, related: nil)}
    end

    defp parse_single_type(nil),
      do: %{type: :string, required: nil, default: nil, validations: [], nested: nil}

    defp parse_single_type(schema_def) when is_map(schema_def) do
      %{
        type: embed_one("embeddable"),
        required: nil,
        default: nil,
        validations: [],
        nested: parse(schema_def)
      }
    end

    defp parse_single_type(schema_def) when is_atom(schema_def) and schema_def in @raw_types do
      %{
        type: Type.from(schema_def),
        required: nil,
        default: nil,
        validations: [],
        nested: nil
      }
    end

    defp parse_single_type({:required, inner_type}) do
      inner_result = parse_single_type(inner_type)
      %{inner_result | required: true}
    end

    defp parse_single_type({:list, inner_type}) when is_map(inner_type) do
      %{
        type: embed_many("embeddable"),
        required: nil,
        default: nil,
        validations: [],
        nested: parse(inner_type)
      }
    end

    defp parse_single_type({:list, inner_type}) do
      %{
        type: {:array, Type.from(inner_type)},
        required: nil,
        default: nil,
        validations: [],
        nested: nil
      }
    end

    defp parse_single_type({:tuple, elements}) do
      %{
        type: Type.from({:tuple, elements}),
        required: nil,
        default: nil,
        validations: [],
        nested: nil
      }
    end

    defp parse_single_type({:enum, _} = schema_def) do
      %{
        type: Type.from(schema_def),
        required: nil,
        default: nil,
        validations: [],
        nested: nil
      }
    end

    defp parse_single_type({:either, _} = schema_def) do
      %{
        type: Type.from(schema_def),
        required: nil,
        default: nil,
        validations: [],
        nested: nil
      }
    end

    defp parse_single_type({:oneof, _} = schema_def) do
      %{
        type: Type.from(schema_def),
        required: nil,
        default: nil,
        validations: [],
        nested: nil
      }
    end

    defp parse_single_type({inner_type, {:default, default_value}}) do
      inner_result = parse_single_type(inner_type)
      %{inner_result | default: default_value}
    end

    defp parse_single_type({:string, _constraint}) do
      %{
        type: :string,
        required: nil,
        default: nil,
        validations: [],
        nested: nil
      }
    end

    defp parse_single_type({:integer, _constraint}) do
      %{
        type: :integer,
        required: nil,
        default: nil,
        validations: [],
        nested: nil
      }
    end

    defp parse_single_type({:float, _constraint}) do
      %{
        type: :float,
        required: nil,
        default: nil,
        validations: [],
        nested: nil
      }
    end

    defp parse_single_type(_) do
      %{
        type: :string,
        required: nil,
        default: nil,
        validations: [],
        nested: nil
      }
    end

    defp apply_conditional_validation(changeset, key, ecto_def) do
      changeset
      |> apply_required_if_needed(key, ecto_def)
      |> apply_nested_validation_if_needed(key, ecto_def)
      |> apply_validations(ecto_def)
    end

    defp apply_required_if_needed(changeset, key, ecto_def) do
      if ecto_def[:required] do
        validate_required(changeset, [key])
      else
        changeset
      end
    end

    defp apply_nested_validation_if_needed(changeset, key, ecto_def) do
      if ecto_def[:nested] do
        validate_nested_field(changeset, key, ecto_def)
      else
        changeset
      end
    end

    defp validate_nested_field(changeset, key, ecto_def) do
      value = get_field(changeset, key)

      if is_nil(value) or not is_map(value) do
        changeset
      else
        validate_nested_map(changeset, key, value, ecto_def[:nested])
      end
    end

    defp validate_nested_map(changeset, key, value, nested_def) do
      nested_changeset = create_nested_changeset(value, nested_def)
      nested_changeset = apply_nested_required(nested_changeset, nested_def)

      if nested_changeset.valid? do
        changeset
      else
        add_nested_errors(changeset, key, nested_changeset.errors)
      end
    end

    defp create_nested_changeset(value, nested_def) do
      types = Map.new(nested_def, fn {k, v} -> {k, v[:type]} end)

      {%{}, types}
      |> Ecto.Changeset.cast(value, Map.keys(nested_def))
    end

    defp apply_nested_required(changeset, nested_def) do
      Enum.reduce(nested_def, changeset, fn {nested_key, nested_def}, acc ->
        if nested_def[:required] do
          validate_required(acc, [nested_key])
        else
          acc
        end
      end)
    end

    defp add_nested_errors(changeset, key, errors) do
      Enum.reduce(errors, changeset, fn {field, {msg, opts}}, acc ->
        add_error(acc, key, "has invalid nested field #{field}: #{msg}", opts)
      end)
    end

    defp apply_validations(changeset, ecto_def) do
      Enum.reduce(ecto_def[:validations] || [], changeset, fn validation, acc ->
        validation.(acc)
      end)
    end

    defp validate_oneof_nested(changeset, key, map_types, other_types, all_types) do
      validate_change(changeset, key, fn ^key, value ->
        valid = validate_oneof_value(value, map_types, other_types, all_types)

        if valid do
          []
        else
          [{key, "is invalid"}]
        end
      end)
    end

    defp validate_oneof_value(value, map_types, _other_types, _all_types) when is_map(value) do
      Enum.any?(map_types, fn schema ->
        match?({:ok, _}, Peri.validate(schema, value))
      end)
    end

    defp validate_oneof_value(value, _map_types, other_types, _all_types) do
      if other_types != [] do
        type = Peri.Ecto.Type.from({:oneof, other_types})
        match?({:ok, _}, Ecto.Type.cast(type, value))
      else
        false
      end
    end

    defp apply_dependent_validation(changeset, key, parsed_schema) do
      changeset
      |> apply_required_if_needed(key, parsed_schema)
      |> validate_dependent_nested(key, parsed_schema)
    end

    defp validate_dependent_nested(changeset, key, parsed_schema) do
      if parsed_schema[:nested] do
        validate_dependent_nested_value(changeset, key, parsed_schema)
      else
        apply_validations(changeset, parsed_schema)
      end
    end

    defp validate_dependent_nested_value(changeset, key, parsed_schema) do
      current_value = get_field(changeset, key)

      if is_nil(current_value) do
        changeset
      else
        process_dependent_nested(changeset, key, current_value, parsed_schema[:nested])
      end
    end

    defp process_dependent_nested(changeset, key, value, nested_schema) do
      nested_changeset =
        value
        |> create_nested_changeset(nested_schema)
        |> apply_nested_required(nested_schema)
        |> apply_nested_validations(nested_schema)

      if nested_changeset.valid? do
        changeset
      else
        add_dependent_errors(changeset, key, nested_changeset.errors)
      end
    end

    defp apply_nested_validations(changeset, nested_schema) do
      Enum.reduce(nested_schema, changeset, fn {_key, def}, acc ->
        Enum.reduce(def[:validations] || [], acc, fn validation, inner_acc ->
          validation.(inner_acc)
        end)
      end)
    end

    defp add_dependent_errors(changeset, key, errors) do
      Enum.reduce(errors, changeset, fn {field, {msg, opts}}, acc ->
        add_error(acc, key, "Invalid nested data: #{field} #{msg}", opts)
      end)
    end
  end
end
