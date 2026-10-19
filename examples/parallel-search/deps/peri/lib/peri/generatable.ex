if Code.ensure_loaded?(StreamData) do
  defmodule Peri.Generatable do
    @moduledoc """
    A module for generating sample data based on Peri schemas using StreamData.

    This module provides functions to generate various types of data, conforming to the schema definitions given in Peri. It leverages the StreamData library to create streams of random data that match the specified types and constraints.

    ## Examples

        iex> schema = %{
        ...>   name: :string,
        ...>   age: {:integer, {:gte, 18}},
        ...>   active: :boolean
        ...> }
        iex> Peri.Generatable.gen(schema)
        %StreamData{
          type: :fixed_map,
          data: %{name: StreamData.string(:alphanumeric), age: StreamData.filter(StreamData.integer(), &(&1 >= 18)), active: StreamData.boolean()}
        }

    """

    require Peri

    @doc """
    Generates a stream of data based on the given schema type.

    This function provides various clauses to handle different types and constraints defined in Peri schemas. It uses StreamData to generate streams of random data conforming to the specified types and constraints.

    ## Parameters

      - `schema`: The schema type to generate data for. It can be a simple type like `:integer`, `:string`, etc., or a complex type with constraints like `{:integer, {:gte, 18}}`.

    ## Returns

      - A StreamData generator stream for the specified schema type.

    ## Examples

        iex> Peri.Generatable.gen(:atom)
        %StreamData{type: :atom, data: ...}

        iex> Peri.Generatable.gen(:string)
        %StreamData{type: :string, data: ...}

        iex> Peri.Generatable.gen(:integer)
        %StreamData{type: :integer, data: ...}

        iex> Peri.Generatable.gen({:enum, [:admin, :user, :guest]})
        %StreamData{type: :one_of, data: ...}

        iex> Peri.Generatable.gen({:list, :integer})
        %StreamData{type: :list_of, data: ...}

        iex> Peri.Generatable.gen({:tuple, [:string, :integer]})
        %StreamData{type: :tuple, data: ...}

        iex> Peri.Generatable.gen({:integer, {:gt, 10}})
        %StreamData{type: :filter, data: ...}

        iex> Peri.Generatable.gen({:string, {:regex, ~r/^[a-z]+$/}})
        %StreamData{type: :filter, data: ...}

        iex> Peri.Generatable.gen({:either, {:integer, :string}})
        %StreamData{type: :one_of, data: ...}

        iex> Peri.Generatable.gen({:custom, {MyModule, :my_fun}})
        %StreamData{type: :filter, data: ...}

        iex> schema = %{name: :string, age: {:integer, {:gte, 18}}}
        iex> Peri.Generatable.gen(schema)
        %StreamData{type: :fixed_map, data: ...}

    """
    def gen(:atom), do: StreamData.atom(:alphanumeric)
    def gen(:atom!), do: gen(:atom)
    def gen(:string), do: StreamData.string(:alphanumeric)
    def gen(:integer), do: StreamData.integer()
    def gen(:float), do: StreamData.float()
    def gen(:boolean), do: StreamData.boolean()

    def gen({:literal, literal}), do: StreamData.constant(literal)

    def gen({:required, type}), do: gen(type)

    def gen({:required, type, opts}) when is_list(opts) do
      case Keyword.fetch(opts, :gen) do
        {:ok, override} -> apply_gen_override(override)
        :error -> gen(type)
      end
    end

    def gen({:meta, type, opts}) when is_list(opts) do
      case Keyword.fetch(opts, :gen) do
        {:ok, override} -> apply_gen_override(override)
        :error -> gen(type)
      end
    end

    @ref_gen_depth 5

    def gen({:multi, field, branches}) when is_atom(field) and is_map(branches) do
      branches
      |> Enum.map(fn {tag, branch} ->
        StreamData.bind(gen(branch), fn val ->
          StreamData.constant(merge_dispatch(val, field, tag))
        end)
      end)
      |> StreamData.one_of()
    end

    def gen({:ref, name}) when is_atom(name) do
      raise ArgumentError,
            "cannot generate data for unresolved local ref #{inspect(name)}; use {:ref, {Mod, #{inspect(name)}}}"
    end

    def gen({:ref, {mod, name}}) when is_atom(mod) and is_atom(name) do
      key = {:peri_ref_depth, mod, name}
      depth = Process.get(key, 0)

      if depth >= @ref_gen_depth do
        StreamData.constant(nil)
      else
        Process.put(key, depth + 1)

        try do
          gen(mod.get_schema(name))
        after
          if depth == 0, do: Process.delete(key), else: Process.put(key, depth)
        end
      end
    end

    def gen({:enum, choices}) do
      choices
      |> Enum.map(&StreamData.constant/1)
      |> StreamData.one_of()
    end

    def gen({:enum, choices, opts}) when is_list(opts) do
      case Keyword.fetch(opts, :gen) do
        {:ok, override} -> apply_gen_override(override)
        :error -> gen({:enum, choices})
      end
    end

    def gen({:list, type}) do
      type
      |> gen()
      |> StreamData.list_of()
    end

    def gen({:list, type, list_opts}) when is_list(list_opts) do
      sd_opts =
        Enum.flat_map(list_opts, fn
          {:min, n} -> [min_length: n]
          {:max, n} -> [max_length: n]
          _ -> []
        end)

      if Keyword.get(list_opts, :unique) == true do
        StreamData.uniq_list_of(gen(type), sd_opts)
      else
        StreamData.list_of(gen(type), sd_opts)
      end
    end

    def gen({:map, type}) do
      key_generator =
        StreamData.one_of([
          StreamData.atom(:alphanumeric),
          StreamData.string(:alphanumeric)
        ])

      value_generator = gen(type)

      StreamData.map_of(key_generator, value_generator)
    end

    def gen({:map, key_type, value_type}) do
      key_generator = gen(key_type)
      value_generator = gen(value_type)

      StreamData.map_of(key_generator, value_generator)
    end

    def gen({:tuple, types}) do
      types
      |> Enum.map(&gen/1)
      |> List.to_tuple()
      |> StreamData.tuple()
    end

    def gen({type, {:eq, eq}}) when Peri.is_numeric_type(type) do
      StreamData.constant(eq)
    end

    def gen({type, {:neq, neq}}) when Peri.is_numeric_type(type) do
      stream = gen(type)
      StreamData.filter(stream, &(&1 != neq))
    end

    def gen({type, {:gt, gt}}) when Peri.is_numeric_type(type) do
      stream = gen(type)
      StreamData.filter(stream, &(&1 > gt))
    end

    def gen({type, {:gte, gte}}) when Peri.is_numeric_type(type) do
      stream = gen(type)
      StreamData.filter(stream, &(&1 >= gte))
    end

    def gen({type, {:lt, lt}}) when Peri.is_numeric_type(type) do
      stream = gen(type)
      StreamData.filter(stream, &(&1 < lt))
    end

    def gen({type, {:lte, lte}}) when Peri.is_numeric_type(type) do
      stream = gen(type)
      StreamData.filter(stream, &(&1 <= lte))
    end

    def gen({:float, {:range, {min, max}}}) do
      StreamData.float(min: min / 1, max: max / 1)
    end

    def gen({type, {:range, {min, max}}}) when Peri.is_numeric_type(type) do
      stream = gen(type)
      StreamData.filter(stream, &(&1 >= min and &1 <= max))
    end

    def gen({type, {:multiple_of, n}}) when Peri.is_numeric_type(type) do
      gen(type) |> apply_multiple_of(n)
    end

    def gen({:string, {:regex, regex}}) do
      stream = gen(:string)
      StreamData.filter(stream, &Regex.match?(regex, &1))
    end

    def gen({:string, {:eq, eq}}) do
      StreamData.constant(eq)
    end

    def gen({:string, {:min, min}}) do
      stream = gen(:string)
      StreamData.filter(stream, &(String.length(&1) >= min))
    end

    def gen({:string, {:max, max}}) do
      stream = gen(:string)
      StreamData.filter(stream, &(String.length(&1) <= max))
    end

    def gen({type, {:default, _}}), do: gen(type)
    def gen({type, {:dependent, _, _, _}}), do: gen(type)

    def gen({type, {:transform, mapper}}) do
      stream = gen(type)
      StreamData.map(stream, mapper)
    end

    def gen({:coerce, target}), do: gen(target)
    def gen({:coerce, target, opts}) when is_list(opts), do: gen(target)
    def gen({:coerce, _source, target}), do: gen(target)
    def gen({:coerce, _source, target, _opts}), do: gen(target)
    def gen({type, {:encode, _}}), do: gen(type)

    def gen({type, opts}) when Peri.is_type_with_multiple_options(type) and is_list(opts) do
      case Keyword.fetch(opts, :gen) do
        {:ok, override} ->
          apply_gen_override(override)

        :error ->
          opts
          |> Keyword.delete(:error)
          |> Enum.reduce(gen(type), &apply_constraint_filter(&2, type, &1))
      end
    end

    def gen({:either, {type_1, type_2}}) do
      stream_1 = gen(type_1)
      stream_2 = gen(type_2)
      StreamData.one_of([stream_1, stream_2])
    end

    def gen({:oneof, types}) do
      types
      |> Enum.map(&gen/1)
      |> StreamData.one_of()
    end

    def gen({:custom, {mod, fun}}) do
      StreamData.filter(StreamData.term(), fn val ->
        case apply(mod, fun, [val]) do
          :ok -> true
          {:ok, _} -> true
          {:error, _reason, _info} -> false
        end
      end)
    end

    def gen({:custom, {mod, fun, args}}) do
      StreamData.filter(StreamData.term(), fn val ->
        case apply(mod, fun, [val | args]) do
          :ok -> true
          {:ok, _} -> true
          {:error, _reason, _info} -> false
        end
      end)
    end

    def gen({:custom, cb}) do
      StreamData.filter(StreamData.term(), fn val ->
        case cb.(val) do
          :ok -> true
          {:ok, _} -> true
          {:error, _reason, _info} -> false
        end
      end)
    end

    def gen(schema) when Peri.is_enumerable(schema) do
      for {k, v} <- schema do
        stream = gen(v)
        {k, stream}
      end
      |> StreamData.fixed_map()
    end

    defp merge_dispatch(val, field, tag) when is_map(val), do: Map.put(val, field, tag)
    defp merge_dispatch(val, field, tag) when is_list(val), do: Keyword.put(val, field, tag)
    defp merge_dispatch(val, _field, _tag), do: val

    defp apply_gen_override({mod, fun, args})
         when is_atom(mod) and is_atom(fun) and is_list(args),
         do: apply(mod, fun, args)

    defp apply_gen_override({mod, fun}) when is_atom(mod) and is_atom(fun),
      do: apply(mod, fun, [])

    defp apply_gen_override(fun) when is_function(fun, 0), do: fun.()

    defp apply_gen_override(other) do
      raise ArgumentError,
            "invalid :gen override; expected MFA tuple, {mod, fun}, or 0-arity function, got: " <>
              inspect(other)
    end

    defp apply_constraint_filter(stream, _type, {:eq, v}),
      do: StreamData.filter(stream, &(&1 == v))

    defp apply_constraint_filter(stream, _type, {:neq, v}),
      do: StreamData.filter(stream, &(&1 != v))

    defp apply_constraint_filter(stream, _type, {:gt, v}),
      do: StreamData.filter(stream, &(&1 > v))

    defp apply_constraint_filter(stream, _type, {:gte, v}),
      do: StreamData.filter(stream, &(&1 >= v))

    defp apply_constraint_filter(stream, _type, {:lt, v}),
      do: StreamData.filter(stream, &(&1 < v))

    defp apply_constraint_filter(stream, _type, {:lte, v}),
      do: StreamData.filter(stream, &(&1 <= v))

    defp apply_constraint_filter(stream, type, {:multiple_of, n})
         when type in [:integer, :float] do
      apply_multiple_of(stream, n)
    end

    defp apply_constraint_filter(stream, _type, {:range, {min, max}}),
      do: StreamData.filter(stream, &(&1 in min..max))

    defp apply_constraint_filter(stream, :string, {:regex, regex}),
      do: StreamData.filter(stream, &Regex.match?(regex, &1))

    defp apply_constraint_filter(stream, :string, {:min, min}),
      do: StreamData.filter(stream, &(String.length(&1) >= min))

    defp apply_constraint_filter(stream, :string, {:max, max}),
      do: StreamData.filter(stream, &(String.length(&1) <= max))

    defp apply_constraint_filter(stream, _type, _opt), do: stream

    defp apply_multiple_of(stream, 0),
      do: StreamData.filter(stream, fn _ -> false end)

    defp apply_multiple_of(stream, n) when is_integer(n) do
      StreamData.map(stream, fn
        val when is_integer(val) -> val - rem(val, n)
        val when is_float(val) -> Float.round(val / n) * n
      end)
    end

    defp apply_multiple_of(stream, n) when is_float(n) do
      StreamData.map(stream, fn val -> Float.round(val / n) * n end)
    end
  end
end
