defmodule Peri.Walker do
  @moduledoc """
  Depth-first schema rewriter.

  `Peri.walk/2` (delegated here) traverses a schema in pre-order, invoking the
  supplied callback on every subtree. Callback contract depends on context:

    * **Map / keyword schema entries** — invoked as `{:field, key, value}`.
      Return one of:

        * `{:cont, {:field, new_key, new_value}}` — replace the entry; the
          walker recurses into `new_value` as a type expression. `new_key` may
          differ from the original (rename) and may be any term valid as a key
          for the surrounding container.
        * `:drop` — remove the entry from the parent map / keyword list.

    * **Every other subtree** — invoked as the type expression itself
      (e.g. `:string`, `{:list, …}`, `{:multi, …}`, a nested map). Return:

        * `{:cont, new_node}` — replace and continue walking children of
          `new_node`.
        * `:drop` — not allowed in this context; raises.

  Map keys are not visited as standalone nodes; constraint option lists
  (e.g. `[gte: 18, error: "…"]`), `:enum` members, `:literal` values, `:ref`
  names, `:multi` tags, callbacks, and transforms are not visited either —
  only sub-schemas and field entries are.

  Example — make every required field optional:

      Peri.walk(schema, fn
        {:required, t} -> {:cont, t}
        {:required, t, _opts} -> {:cont, t}
        other -> {:cont, other}
      end)

  Example — strip private fields from a map schema:

      Peri.walk(schema, fn
        {:field, k, _v} when k in [:internal_id, :secret] -> :drop
        other -> {:cont, other}
      end)

  Example — rename `email` to `:login`:

      Peri.walk(schema, fn
        {:field, :email, v} -> {:cont, {:field, :login, v}}
        other -> {:cont, other}
      end)
  """

  @type field_node :: {:field, term, term}
  @type sentinel :: {:cont, term} | {:cont, field_node} | :drop
  @type walker_fun :: (term -> sentinel)

  @spec walk(Peri.schema(), walker_fun) :: Peri.schema()
  def walk(schema, fun) when is_function(fun, 1) do
    visit_type(schema, fun)
  end

  defp visit_type(node, fun) do
    case fun.(node) do
      {:cont, new_node} ->
        walk_type_children(new_node, fun)

      :drop ->
        raise ArgumentError,
              "Peri.walk/2 callback returned :drop outside a map field; " <>
                ":drop is only valid for {:field, k, v} entries"

      other ->
        raise ArgumentError,
              "Peri.walk/2 callback must return {:cont, term} | :drop, got: " <>
                inspect(other)
    end
  end

  defp visit_field(key, value, fun) do
    case fun.({:field, key, value}) do
      {:cont, {:field, new_key, new_value}} ->
        {:keep, new_key, visit_type(new_value, fun)}

      :drop ->
        :drop

      {:cont, other} ->
        raise ArgumentError,
              "Peri.walk/2 callback must return {:cont, {:field, k, v}} for a " <>
                "map field; got {:cont, #{inspect(other)}}"

      other ->
        raise ArgumentError,
              "Peri.walk/2 callback must return {:cont, {:field, k, v}} | :drop " <>
                "for a map field; got: " <> inspect(other)
    end
  end

  defp walk_type_children(node, fun) when is_map(node) and not is_struct(node) do
    Enum.reduce(node, %{}, fn {k, v}, acc ->
      case visit_field(k, v, fun) do
        {:keep, new_k, new_v} -> Map.put(acc, new_k, new_v)
        :drop -> acc
      end
    end)
  end

  defp walk_type_children([{k, _} | _] = node, fun) when is_atom(k) do
    if Keyword.keyword?(node),
      do: Enum.flat_map(node, &flat_map_kw_entry(&1, fun)),
      else: node
  end

  defp walk_type_children({:required, t}, fun), do: {:required, visit_type(t, fun)}

  defp walk_type_children({:required, t, opts}, fun) when is_list(opts),
    do: {:required, visit_type(t, fun), opts}

  defp walk_type_children({:list, t}, fun), do: {:list, visit_type(t, fun)}

  defp walk_type_children({:map, t}, fun), do: {:map, visit_type(t, fun)}

  defp walk_type_children({:map, kt, vt}, fun),
    do: {:map, visit_type(kt, fun), visit_type(vt, fun)}

  defp walk_type_children({:tuple, ts}, fun) when is_list(ts),
    do: {:tuple, Enum.map(ts, &visit_type(&1, fun))}

  defp walk_type_children({:either, {t1, t2}}, fun),
    do: {:either, {visit_type(t1, fun), visit_type(t2, fun)}}

  defp walk_type_children({:oneof, ts}, fun) when is_list(ts),
    do: {:oneof, Enum.map(ts, &visit_type(&1, fun))}

  defp walk_type_children({:meta, t, opts}, fun) when is_list(opts),
    do: {:meta, visit_type(t, fun), opts}

  defp walk_type_children({:coerce, target}, fun),
    do: {:coerce, visit_type(target, fun)}

  defp walk_type_children({:coerce, target, opts}, fun) when is_list(opts),
    do: {:coerce, visit_type(target, fun), opts}

  defp walk_type_children({:coerce, source, target}, fun),
    do: {:coerce, source, visit_type(target, fun)}

  defp walk_type_children({:coerce, source, target, opts}, fun) when is_list(opts),
    do: {:coerce, source, visit_type(target, fun), opts}

  defp walk_type_children({:cond, cb, t, el}, fun),
    do: {:cond, cb, visit_type(t, fun), visit_type(el, fun)}

  defp walk_type_children({:dependent, x, cb, t}, fun) when is_function(cb, 2),
    do: {:dependent, x, cb, visit_type(t, fun)}

  defp walk_type_children({:multi, field, branches}, fun)
       when is_atom(field) and is_map(branches) do
    walked = Map.new(branches, fn {tag, branch} -> {tag, visit_type(branch, fun)} end)
    {:multi, field, walked}
  end

  defp walk_type_children({:schema, s}, fun), do: {:schema, visit_type(s, fun)}

  defp walk_type_children({:schema, s, {:additional_keys, t}}, fun) do
    {:schema, visit_type(s, fun), {:additional_keys, visit_type(t, fun)}}
  end

  defp walk_type_children(other, _fun), do: other

  defp flat_map_kw_entry({key, value}, fun) do
    case visit_field(key, value, fun) do
      {:keep, new_k, new_v} -> [{new_k, new_v}]
      :drop -> []
    end
  end
end
