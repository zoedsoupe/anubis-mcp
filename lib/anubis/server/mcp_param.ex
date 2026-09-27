defmodule Anubis.Server.McpParam do
  @moduledoc """
  Tool parameters mirrored into `Mcp-Param-{Name}` HTTP headers, which the
  2026-07-28 Streamable HTTP transport defines.

  A tool opts a parameter in with an `x-mcp-header` property in its
  `inputSchema`; with the component DSL, `field :region, :string,
  mcp_header: "Region"`. A client then sends the argument's value in the
  `Mcp-Param-Region` header, and the server rejects the call with `-32020`
  (`HeaderMismatch`, HTTP 400) when a header disagrees with the body, is
  missing for a value the body carries, or holds characters a header value
  cannot.

  An annotation must name a header token, unique regardless of case, on a
  string, integer or boolean parameter reachable from the schema root through
  `properties` alone. A schema that breaks any of these raises
  `ArgumentError` when its JSON Schema is built.
  """

  alias Anubis.MCP.Error

  @base64_prefix "=?base64?"
  @base64_suffix "?="
  @header_types ["string", "integer", "boolean"]
  @token ~r/\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/

  @doc """
  Decodes a header value that may carry the `=?base64?…?=` sentinel.

  Spaces and tabs around the value are not part of it (RFC 9110, section 5.5)
  and are dropped first. A value without the sentinel, or with only its
  prefix, is returned as written. A sentinel around invalid Base64 is `:error`.

  ## Examples

      iex> Anubis.Server.McpParam.decode_header_value("us-west1")
      {:ok, "us-west1"}

      iex> Anubis.Server.McpParam.decode_header_value("=?base64?SGVsbG8=?=")
      {:ok, "Hello"}

      iex> Anubis.Server.McpParam.decode_header_value("=?base64?SGVsbG8?=")
      :error

      iex> Anubis.Server.McpParam.decode_header_value("  test_tool \t")
      {:ok, "test_tool"}
  """
  @spec decode_header_value(String.t()) :: {:ok, String.t()} | :error
  def decode_header_value(value) when is_binary(value) do
    value |> String.replace(~r/\A[ \t]+|[ \t]+\z/, "") |> decode_trimmed()
  end

  defp decode_trimmed(@base64_prefix <> rest = value) do
    if String.ends_with?(rest, @base64_suffix) do
      rest
      |> binary_part(0, byte_size(rest) - byte_size(@base64_suffix))
      |> Base.decode64()
    else
      {:ok, value}
    end
  end

  defp decode_trimmed(value), do: {:ok, value}

  @doc """
  Puts the `x-mcp-header` annotations of a component schema into the JSON
  Schema built from it.

  `schema` is the expanded component schema, whose fields carry `mcp_header:`
  in their metadata; `json_schema` is what it was encoded to. Raises
  `ArgumentError` for an annotation the specification does not allow.
  """
  @spec annotate(map(), map()) :: map()
  def annotate(json_schema, schema) when is_map(json_schema) and is_map(schema) do
    headers = declared(schema, [])
    check_unique!(headers)

    Enum.reduce(headers, json_schema, fn {path, name}, json ->
      property_path = Enum.flat_map(path, &["properties", &1])
      check_type!(get_in(json, property_path), path, name)
      put_in(json, property_path ++ ["x-mcp-header"], name)
    end)
  end

  @doc """
  Checks the `Mcp-Param-*` headers of a `tools/call` against its arguments.

  `input_schema` is the tool's JSON Schema, `arguments` the call's arguments
  and `headers` the request's headers, with lowercase names.
  """
  @spec validate(map() | nil, map() | nil, %{String.t() => String.t()}) :: :ok | {:error, Error.t()}
  def validate(input_schema, arguments, headers) do
    input_schema
    |> annotations([])
    |> Enum.find_value(:ok, fn {path, name} ->
      case check(dig(arguments, path), Map.get(headers, "mcp-param-" <> String.downcase(name)), name) do
        :ok -> nil
        {:error, message} -> {:error, Error.protocol(:header_mismatch, %{message: message})}
      end
    end)
  end

  defp check(nil, nil, _name), do: :ok
  defp check(nil, _header, name), do: {:error, "Mcp-Param-#{name} has no argument in the body to match"}
  defp check(_value, nil, name), do: {:error, "Missing required header Mcp-Param-#{name}"}

  defp check(value, header, name) do
    with true <- header_value?(header),
         {:ok, decoded} <- decode_header_value(header) do
      if decoded == wire_value(value),
        do: :ok,
        else: {:error, "Mcp-Param-#{name} does not match the argument in the body"}
    else
      _invalid -> {:error, "Mcp-Param-#{name} is not a valid header value"}
    end
  end

  # RFC 9110 field values: visible ASCII, space and horizontal tab.
  defp header_value?(value), do: value |> :binary.bin_to_list() |> Enum.all?(&(&1 == 9 or &1 in 32..126))

  defp wire_value(value) when is_binary(value), do: value
  defp wire_value(value) when is_integer(value), do: Integer.to_string(value)
  defp wire_value(value) when is_boolean(value), do: to_string(value)
  defp wire_value(_value), do: nil

  defp dig(value, []), do: value
  defp dig(%{} = map, [key | rest]), do: map |> Map.get(key) |> dig(rest)
  defp dig(_value, _path), do: nil

  # Only chains of `properties` are statically reachable; an annotation under
  # anything else makes the definition invalid and is not honored here.
  defp annotations(%{"properties" => properties}, path) when is_map(properties) do
    Enum.flat_map(properties, fn {key, property} ->
      here = path ++ [key]

      case property do
        %{"x-mcp-header" => name} when is_binary(name) -> [{here, name} | annotations(property, here)]
        %{} -> annotations(property, here)
        _other -> []
      end
    end)
  end

  defp annotations(_schema, _path), do: []

  defp declared(schema, path) do
    Enum.flat_map(schema, fn {key, value} ->
      here = path ++ [to_string(key)]
      {inner, meta} = unwrap(value, [])

      own =
        case Keyword.fetch(meta, :mcp_header) do
          {:ok, name} -> [{here, check_name!(name, here)}]
          :error -> []
        end

      own ++ nested(inner, here)
    end)
  end

  defp nested(inner, path) when is_map(inner), do: declared(inner, path)

  defp nested({:list, item}, path) do
    case item |> unwrap([]) |> elem(0) |> then(&if(is_map(&1), do: declared(&1, path), else: [])) do
      [] -> []
      [{inner_path, name} | _] -> raise ArgumentError, unreachable(inner_path, name)
    end
  end

  defp nested(_inner, _path), do: []

  defp unwrap({:required, inner}, meta), do: unwrap(inner, meta)
  defp unwrap({:meta, inner, opts}, meta), do: unwrap(inner, meta ++ opts)
  defp unwrap({inner, {:default, _value}}, meta), do: unwrap(inner, meta)
  defp unwrap(inner, meta), do: {inner, meta}

  defp check_name!(name, path) do
    if is_binary(name) and Regex.match?(@token, name) do
      name
    else
      raise ArgumentError,
            "mcp_header on #{Enum.join(path, ".")} must be a non-empty HTTP token, got: #{inspect(name)}"
    end
  end

  defp check_unique!(headers) do
    headers
    |> Enum.group_by(fn {_path, name} -> String.downcase(name) end)
    |> Enum.find(fn {_name, uses} -> length(uses) > 1 end)
    |> case do
      nil -> :ok
      {name, _uses} -> raise ArgumentError, "mcp_header #{inspect(name)} is declared more than once, regardless of case"
    end
  end

  defp check_type!(%{"type" => type}, _path, _name) when type in @header_types, do: :ok

  defp check_type!(_property, path, name) do
    raise ArgumentError,
          "mcp_header #{inspect(name)} on #{Enum.join(path, ".")} must annotate a string, integer or boolean"
  end

  defp unreachable(path, name) do
    "mcp_header #{inspect(name)} on #{Enum.join(path, ".")} is inside a list, which a header cannot reach"
  end
end
