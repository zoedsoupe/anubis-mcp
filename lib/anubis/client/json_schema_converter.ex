defmodule Anubis.Client.JSONSchemaConverter do
  @moduledoc false

  @type json_schema :: map()
  @type peri_schema :: Peri.schema_def()
  @type validator :: (term() -> {:ok, term()} | {:error, list(Peri.Error.t())})

  @doc """
  Converts a JSON Schema (Draft 7 or 2020-12) into a Peri schema.
  """
  @spec to_peri(json_schema()) :: {:ok, peri_schema()} | {:error, list(Peri.Error.t())}
  def to_peri(json_schema) do
    json_schema
    |> to_draft_07()
    |> Peri.from_json_schema()
  end

  # Peri only understands draft-07 `"items" => [schemas]` tuples; 2020-12
  # servers emit `prefixItems` plus `"items" => false` instead. Rewrite those
  # positions back to the draft-07 shape before delegating.
  defp to_draft_07(schema) when is_map(schema) do
    schema
    |> Map.new(fn {key, value} -> {key, to_draft_07(value)} end)
    |> convert_prefix_items()
  end

  defp to_draft_07(list) when is_list(list), do: Enum.map(list, &to_draft_07/1)
  defp to_draft_07(other), do: other

  defp convert_prefix_items(%{"prefixItems" => items} = schema) when is_list(items) do
    schema
    |> Map.delete("prefixItems")
    |> Map.put("items", items)
  end

  defp convert_prefix_items(schema), do: schema

  @doc """
  Creates a validator function from a JSON Schema.

  Returns a function that takes a value and returns either
  `{:ok, value}` or `{:error, errors}`.
  """
  @spec validator(json_schema()) :: {:ok, validator} | {:error, list(Peri.Error.t())}
  def validator(json_schema) do
    with {:ok, peri_schema} <- to_peri(json_schema) do
      {:ok, fn value -> Peri.validate(peri_schema, value) end}
    end
  end
end
