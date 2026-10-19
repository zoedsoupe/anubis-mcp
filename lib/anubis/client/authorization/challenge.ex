defmodule Anubis.Client.Authorization.Challenge do
  @moduledoc """
  An HTTP authorization challenge, including the original `WWW-Authenticate` values.

  `scope` is the server's requested scope string, independent of metadata's
  `scopes_supported`. `parse_error` identifies malformed or ambiguous Bearer
  challenges; discovery refuses to use them.
  """

  @type t :: %__MODULE__{
          mcp_url: String.t(),
          status: pos_integer(),
          headers: [String.t()],
          resource_metadata: String.t() | nil,
          scope: String.t() | nil,
          error: String.t() | nil,
          error_description: String.t() | nil,
          parse_error: atom() | nil
        }
  defstruct [:mcp_url, :status, :resource_metadata, :scope, :error, :error_description, :parse_error, headers: []]

  @token "[!#$%&'*+.^_`|~0-9A-Za-z-]+"
  @param_start Regex.compile!("^#{@token}\\s*=")
  @scheme Regex.compile!("^(#{@token})(?:[ \\t]+(.*))?$")
  @param Regex.compile!("^(#{@token})\\s*=\\s*(#{@token}|\"(?:[^\"\\\\\\r\\n]|\\\\[^\\r\\n])*\")$")

  @doc """
  Extracts Bearer parameters from response headers without discarding the originals.

  Header and parameter names are case insensitive. Multiple distinct Bearer
  challenges are reported as ambiguous rather than selecting one implicitly.
  """
  @spec from_response(String.t(), pos_integer(), [{String.t(), String.t()}]) :: t()
  def from_response(mcp_url, status, headers) do
    values = for {name, value} <- headers, String.downcase(name) == "www-authenticate", do: value
    challenge = %__MODULE__{mcp_url: mcp_url, status: status, headers: values}

    case values |> Enum.flat_map(&bearer_groups/1) |> Enum.map(&parameters/1) |> Enum.uniq() do
      [] ->
        challenge

      [{:ok, params}] ->
        %{
          challenge
          | resource_metadata: params["resource_metadata"],
            scope: params["scope"],
            error: params["error"],
            error_description: params["error_description"]
        }

      [{:error, reason}] ->
        %{challenge | parse_error: reason}

      _ ->
        %{challenge | parse_error: :ambiguous_bearer_challenge}
    end
  end

  defp bearer_groups(value) do
    {current, groups} =
      value
      |> split_parts([], [], false, false)
      |> Enum.reject(&(&1 == ""))
      |> Enum.reduce({nil, []}, &group_part/2)

    add_group(current, groups)
  end

  defp group_part(part, {current, groups}) do
    if Regex.match?(@param_start, part) do
      {append_part(current, part), groups}
    else
      case Regex.run(@scheme, part) do
        [_, scheme, rest] -> {{String.downcase(scheme), [rest]}, add_group(current, groups)}
        [_, scheme] -> {{String.downcase(scheme), []}, add_group(current, groups)}
        _ -> {append_part(current, part), groups}
      end
    end
  end

  defp append_part({scheme, parts}, part), do: {scheme, [part | parts]}
  defp append_part(nil, _part), do: nil
  defp add_group({"bearer", parts}, groups), do: [Enum.reverse(parts) | groups]
  defp add_group(_, groups), do: groups

  defp parameters(parts), do: Enum.reduce_while(parts, {:ok, %{}}, &add_parameter/2)

  defp add_parameter(part, {:ok, params}) do
    with [_, name, value] <- Regex.run(@param, String.trim(part)),
         name = String.downcase(name),
         false <- Map.has_key?(params, name) do
      {:cont, {:ok, Map.put(params, name, unquote_value(value))}}
    else
      _ -> {:halt, {:error, :invalid_bearer_challenge}}
    end
  end

  defp unquote_value("\"" <> value) do
    value |> binary_part(0, byte_size(value) - 1) |> then(&Regex.replace(~r/\\(.)/s, &1, "\\1"))
  end

  defp unquote_value(value), do: value

  defp split_parts(<<>>, part, parts, _quoted, _escaped), do: Enum.reverse([part_string(part) | parts])

  defp split_parts(<<char, rest::binary>>, part, parts, quoted, true),
    do: split_parts(rest, [char | part], parts, quoted, false)

  defp split_parts(<<?\\, rest::binary>>, part, parts, true, false),
    do: split_parts(rest, [?\\ | part], parts, true, true)

  defp split_parts(<<?\", rest::binary>>, part, parts, quoted, false),
    do: split_parts(rest, [?\" | part], parts, not quoted, false)

  defp split_parts(<<?,, rest::binary>>, part, parts, false, false),
    do: split_parts(rest, [], [part_string(part) | parts], false, false)

  defp split_parts(<<char, rest::binary>>, part, parts, quoted, false),
    do: split_parts(rest, [char | part], parts, quoted, false)

  defp part_string(part), do: part |> Enum.reverse() |> :erlang.list_to_binary() |> String.trim()
end
