if Code.ensure_loaded?(Ecto) do
  defmodule Peri.Ecto.Type do
    @moduledoc "Responsible to convert between Peri <> Ecto types definitions"

    alias Ecto.ParameterizedType

    @spec from(Peri.schema_def()) :: term
    def from(:any), do: __MODULE__.Any
    def from(:pid), do: __MODULE__.PID
    def from(:atom), do: __MODULE__.Atom
    def from(:datetime), do: :utc_datetime
    def from({:oneof, types}), do: ParameterizedType.init(__MODULE__.OneOf, values: types)

    def from({:either, {fst, snd}}),
      do: ParameterizedType.init(__MODULE__.Either, values: {fst, snd})

    def from({:tuple, types}), do: ParameterizedType.init(__MODULE__.Tuple, elements: types)

    def from({:list, inner}), do: {:array, from(inner)}

    def from({:enum, choices}) do
      cond do
        Enum.all?(choices, &is_binary/1) ->
          choices = Enum.map(choices, &String.to_atom/1)
          ParameterizedType.init(Ecto.Enum, values: choices)

        Enum.all?(choices, &is_atom/1) ->
          ParameterizedType.init(Ecto.Enum, values: choices)

        true ->
          raise Peri.Error, message: "Ecto.Enum only accepts strings and atoms"
      end
    end

    def from(type) when is_map(type), do: :map
    def from(type), do: type
  end

  defmodule Peri.Ecto.Type.PID do
    @moduledoc "Custom Ecto type for storing PIDs, use with caution"

    use Ecto.Type

    @impl true
    def type, do: :string

    @impl true
    def cast(pid) when is_pid(pid) do
      {:ok, pid}
    end

    def cast(_), do: :error

    @impl true
    def dump(pid) when is_pid(pid) do
      {:ok, :erlang.term_to_binary(pid)}
    end

    def dump(_), do: :error

    @impl true
    def load(pid) when is_binary(pid) do
      {:ok, :erlang.binary_to_term(pid)}
    end

    def load(_), do: :error
  end

  defmodule Peri.Ecto.Type.Atom do
    @moduledoc "Custom Ecto type for storing atoms as strings"

    use Ecto.Type

    @impl true
    def type, do: :string

    @impl true
    def cast(atom) when is_atom(atom), do: {:ok, atom}
    def cast(_), do: :error

    @impl true
    def dump(atom) when is_atom(atom) do
      {:ok, Atom.to_string(atom)}
    end

    def dump(_), do: :error

    @impl true
    def load(string) when is_binary(string) do
      {:ok, String.to_atom(string)}
    end

    def load(_), do: :error
  end

  defmodule Peri.Ecto.Type.Any do
    @moduledoc "Represents any type. Passes data to Cassandra as is."

    use Ecto.Type

    @impl true
    def type, do: :custom

    @impl true
    def cast(value), do: {:ok, value}

    @impl true
    def load(value), do: {:ok, value}

    @impl true
    def dump(value), do: {:ok, value}
  end

  defmodule Peri.Ecto.Type.Tuple do
    @moduledoc "Custom Ecto type for storing tuples with multiple types/elements"

    use Ecto.ParameterizedType

    @impl true
    def type(_), do: :map

    @impl true
    def init(elements: types) when is_list(types) do
      case Peri.validate_schema({:tuple, types}) do
        {:ok, {:tuple, types}} ->
          {processed_types, nested_map_info} = process_tuple_types(types)

          %{elements: processed_types, original_types: types, map_indexes: nested_map_info}

        {:error, message} ->
          raise Peri.Error, message
      end
    end

    @impl true
    def cast(tuple, %{elements: types, original_types: original_types}) when is_tuple(tuple) do
      # Check size match
      if tuple_size(tuple) != length(types) do
        :error
      else
        cast_tuple_with_maps(tuple, types, original_types)
      end
    end

    # For simple type array without original_types
    def cast(tuple, %{elements: types}) when is_tuple(tuple) do
      with {_idx, values} <- cast_elements(tuple, types) do
        {:ok,
         values
         |> Enum.reverse()
         |> List.to_tuple()}
      end
    end

    def cast(_, _), do: :error

    # Helper for handling tuples with map elements
    defp cast_tuple_with_maps(tuple, types, original_types) do
      tuple_values = Tuple.to_list(tuple)

      # Process each element with its corresponding type
      results =
        Enum.zip([tuple_values, types, original_types])
        |> Enum.map(&cast_tuple_element/1)

      # If all elements cast successfully, build the result tuple
      if Enum.all?(results, &match?({:ok, _}, &1)) do
        values = Enum.map(results, fn {:ok, val} -> val end)
        {:ok, List.to_tuple(values)}
      else
        :error
      end
    end

    # Pattern match on different element/type combinations
    defp cast_tuple_element({map_val, {:embed, %{field: _field_name}}, original_type})
         when is_map(map_val) and is_map(original_type) do
      # Get the schema from the original type
      case tuple_validate_map(map_val, original_type) do
        {:ok, validated_map} -> {:ok, validated_map}
        # Default to returning original map if validation fails
        _ -> {:ok, map_val}
      end
    end

    defp cast_tuple_element({val, type, _}) do
      # Regular element casting
      Ecto.Type.cast(type, val)
    end

    defp tuple_validate_map(map_val, schema) do
      case Peri.validate(schema, map_val) do
        {:ok, validated} -> {:ok, validated}
        _ -> :error
      end
    rescue
      _ -> :error
    end

    defp process_tuple_types(types) do
      types
      |> Enum.with_index()
      |> Enum.map_reduce(%{}, &process_single_tuple_type/2)
    end

    defp process_single_tuple_type({type, idx}, map_info_acc) when is_map(type) do
      map_key = "map_#{idx}"
      embed_type = {:embed, Ecto.Embedded.init(field: map_key, cardinality: :one, related: nil)}
      {embed_type, Map.put(map_info_acc, map_key, idx)}
    end

    defp process_single_tuple_type({type, _idx}, map_info_acc) do
      {Peri.Ecto.Type.from(type), map_info_acc}
    end

    defp cast_elements(tuple, types) do
      if tuple_size(tuple) != length(types) do
        :error
      else
        apply_elements_casting(tuple, types)
      end
    end

    defp apply_elements_casting(tuple, types) do
      Enum.reduce_while(types, {0, []}, fn type, {index, acc} ->
        case Ecto.Type.cast(type, elem(tuple, index)) do
          {:ok, value} -> {:cont, {index + 1, [value | acc]}}
          :error -> {:halt, :error}
        end
      end)
    end

    @impl true
    def dump(tuple, _dumper, _params) when is_tuple(tuple) do
      {:ok,
       tuple
       |> Tuple.to_list()
       |> Enum.with_index(fn el, idx -> {idx, el} end)
       |> Map.new()}
    end

    def dump(_, _, _), do: :error

    @impl true
    def load(tuple, _loader, _params) when is_map(tuple) do
      {:ok,
       tuple
       |> Map.to_list()
       |> Enum.sort_by(fn {idx, _} -> idx end)
       |> Enum.map(fn {_idx, value} -> value end)
       |> List.to_tuple()}
    end

    def load(_, _, _), do: :error
  end

  defmodule Peri.Ecto.Type.Either do
    @moduledoc "Custom Ecto type for storing either of two types"

    use Ecto.ParameterizedType

    import Peri.Ecto, only: [is_ecto_embed: 1]

    alias Peri.Ecto.Type

    require Peri.Ecto

    @impl true
    def type(_), do: :any

    @impl true
    def init(values: {fst, snd}) when is_ecto_embed(fst) do
      case Peri.validate_schema(snd) do
        {:ok, snd} -> %{values: {fst, Type.from(snd)}, original_schema: {nil, snd}}
        {:error, message} -> raise Peri.Error, message
      end
    end

    def init(values: {fst, snd}) when is_ecto_embed(snd) do
      case Peri.validate_schema(fst) do
        {:ok, fst} -> %{values: {Type.from(fst), snd}, original_schema: {fst, nil}}
        {:error, message} -> raise Peri.Error, message
      end
    end

    def init(values: {fst, snd}) do
      case Peri.validate_schema({:either, {fst, snd}}) do
        {:ok, {:either, {fst, snd}}} ->
          %{values: {Type.from(fst), Type.from(snd)}, original_schema: {fst, snd}}

        {:error, message} ->
          raise Peri.Error, message
      end
    end

    defp either_validate_map(map_val, schema) do
      case Peri.validate(schema, map_val) do
        {:ok, validated} -> {:ok, validated}
        _ -> :error
      end
    rescue
      _ -> :error
    end

    @impl true
    def cast(value, %{values: {fst, snd}, original_schema: original_schema})
        when is_ecto_embed(fst) and is_map(value) do
      # Access original schema info
      {fst_original, _snd_original} = original_schema

      # Try the embedded schema first - using original schema if available
      if is_map(fst_original) do
        case either_validate_map(value, fst_original) do
          {:ok, validated_map} -> {:ok, validated_map}
          # Try second type
          _ -> Ecto.Type.cast(snd, value)
        end
      else
        # Try using embed info directly
        embed_mod = fst |> elem(1) |> Map.get(:related)

        changeset =
          if embed_mod do
            # If related module is specified, use it
            struct(embed_mod) |> Ecto.Changeset.cast(value, Map.keys(value))
          else
            # Otherwise just use a basic changeset
            Ecto.Changeset.cast({%{}, %{}}, value, Map.keys(value))
          end

        # If valid, return the map, otherwise try the second type
        if changeset.valid? do
          {:ok, Ecto.Changeset.apply_changes(changeset)}
        else
          Ecto.Type.cast(snd, value)
        end
      end
    end

    def cast(value, %{values: {fst, snd}, original_schema: original_schema})
        when is_ecto_embed(snd) and is_map(value) do
      # Try the first type first
      case Ecto.Type.cast(fst, value) do
        {:ok, casted_value} ->
          {:ok, casted_value}

        :error ->
          cast_second_embed(value, snd, original_schema)
      end
    end

    # Fallback for when we don't have original schema info
    def cast(value, %{values: {fst, snd}}) when is_ecto_embed(fst) and is_map(value) do
      cast(value, %{values: {fst, snd}, original_schema: {nil, nil}})
    end

    def cast(value, %{values: {fst, snd}}) when is_ecto_embed(snd) and is_map(value) do
      cast(value, %{values: {fst, snd}, original_schema: {nil, nil}})
    end

    def cast(value, %{values: {fst, snd}}) do
      with :error <- Ecto.Type.cast(fst, value) do
        Ecto.Type.cast(snd, value)
      end
    end

    defp cast_second_embed(value, snd, original_schema) do
      {_fst_original, snd_original} = original_schema || {nil, nil}

      if is_map(snd_original) do
        either_validate_map(value, snd_original)
      else
        cast_with_embed_info(value, snd)
      end
    end

    defp cast_with_embed_info(value, embed_type) do
      embed_mod = embed_type |> elem(1) |> Map.get(:related)
      changeset = create_embed_changeset(value, embed_mod)

      if changeset.valid? do
        {:ok, Ecto.Changeset.apply_changes(changeset)}
      else
        :error
      end
    end

    defp create_embed_changeset(value, nil) do
      Ecto.Changeset.cast({%{}, %{}}, value, Map.keys(value))
    end

    defp create_embed_changeset(value, embed_mod) do
      struct(embed_mod) |> Ecto.Changeset.cast(value, Map.keys(value))
    end

    @impl true
    def dump(value, _, %{values: {fst, snd}}) do
      with :error <- Ecto.Type.dump(fst, value) do
        Ecto.Type.dump(snd, value)
      end
    end

    @impl true
    def load(value, _, %{values: {fst, snd}}) do
      with :error <- Ecto.Type.load(fst, value) do
        Ecto.Type.load(snd, value)
      end
    end
  end

  defmodule Peri.Ecto.Type.OneOf do
    @moduledoc "Custom Ecto type for storing one of many types, aka sum types"

    use Ecto.ParameterizedType

    @impl true
    def type(_), do: :any

    @impl true
    def init(values: types) when is_list(types) do
      case Peri.validate_schema({:oneof, types}) do
        {:ok, {:oneof, types}} -> %{values: Enum.map(types, &Peri.Ecto.Type.from/1)}
        {:error, message} -> raise Peri.Error, message
      end
    end

    @impl true
    def cast(value, %{values: types}) do
      Enum.reduce_while(types, :error, fn type, _ ->
        case Ecto.Type.cast(type, value) do
          {:ok, value} -> {:halt, {:ok, value}}
          :error -> {:cont, :error}
        end
      end)
    end

    @impl true
    def dump(value, _, %{values: types}) do
      Enum.reduce_while(types, :error, fn type, _ ->
        case Ecto.Type.dump(type, value) do
          {:ok, value} -> {:halt, {:ok, value}}
          :error -> {:cont, :error}
        end
      end)
    end

    @impl true
    def load(value, _, %{values: types}) do
      Enum.reduce_while(types, :error, fn type, _ ->
        case Ecto.Type.load(type, value) do
          {:ok, value} -> {:halt, {:ok, value}}
          :error -> {:cont, :error}
        end
      end)
    end
  end
end
