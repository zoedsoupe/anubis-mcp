defmodule Anubis.Client.JSONSchemaConverter do
  @moduledoc false

  @type json_schema :: map()
  @type peri_schema :: Peri.schema_def()
  @type validator :: (term() -> {:ok, term()} | {:error, list(Peri.Error.t())})

  @doc """
  Converts a JSON Schema (Draft 7) into a Peri schema.
  """
  @spec to_peri(json_schema()) :: {:ok, peri_schema()} | {:error, list(Peri.Error.t())}
  defdelegate to_peri(json_schema), to: Peri, as: :from_json_schema

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
