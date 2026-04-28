defmodule Anubis.Server.Component.URITemplate do
  @moduledoc """
  RFC 6570 URI Template parser and matcher (Levels 1 and 2).

  Supported expressions:

  | Form        | Level | Description                          |
  |-------------|-------|--------------------------------------|
  | `{var}`     | 1     | Simple expansion (excludes `/?#`)    |
  | `{+var}`    | 2     | Reserved expansion (allows reserved) |
  | `{#var}`    | 2     | Fragment expansion (literal `#`)     |

  Level 3 (multi-var, label, path-segment, query) and Level 4 (prefix, explode)
  are not supported.

  ## Examples

      iex> {:ok, t} = URITemplate.parse("file:///{path}")
      iex> URITemplate.match(t, "file:///docs/readme.md")
      {:ok, %{"path" => "docs/readme.md"}}

      iex> {:ok, t} = URITemplate.parse("db:///{table}/{id}")
      iex> URITemplate.match(t, "db:///users/42")
      {:ok, %{"table" => "users", "id" => "42"}}

      iex> {:ok, t} = URITemplate.parse("file:///{+path}")
      iex> URITemplate.match(t, "file:///deep/nested/file.md")
      {:ok, %{"path" => "deep/nested/file.md"}}

      iex> {:ok, t} = URITemplate.parse("/page{#section}")
      iex> URITemplate.match(t, "/page#intro")
      {:ok, %{"section" => "intro"}}
  """

  @type t :: %__MODULE__{
          raw: String.t(),
          vars: [String.t()],
          regex: Regex.t()
        }

  defstruct [:raw, :vars, :regex]

  @expr_pattern ~r/\{([+#]?)([a-zA-Z_][a-zA-Z0-9_]*)\}/

  @doc """
  Parses an RFC 6570 (Level 1 + Level 2) URI template string.

  Returns `{:ok, %URITemplate{}}` on success, `{:error, reason}` otherwise.
  """
  @spec parse(String.t()) :: {:ok, t} | {:error, String.t()}
  def parse(template) when is_binary(template) do
    if (String.contains?(template, "{") or String.contains?(template, "}")) and
         not valid_braces?(template) do
      {:error, "unbalanced or invalid braces in template: #{inspect(template)}"}
    else
      vars = extract_vars(template)

      case vars -- Enum.uniq(vars) do
        [] ->
          {:ok, %__MODULE__{raw: template, vars: vars, regex: build_regex(template)}}

        dups ->
          {:error, "duplicate variables #{inspect(Enum.uniq(dups))} in template"}
      end
    end
  end

  def parse(_), do: {:error, "template must be a string"}

  @doc """
  Same as `parse/1` but raises `ArgumentError` on failure.
  """
  @spec parse!(String.t()) :: t
  def parse!(template) do
    case parse(template) do
      {:ok, t} -> t
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  @doc """
  Matches a URI against a parsed template (or template string).

  Returns `{:ok, vars_map}` on a match where keys are variable names and
  values are the percent-decoded substrings, or `:error` if the URI does not
  match the template.
  """
  @spec match(t | String.t(), String.t()) :: {:ok, map} | :error
  def match(%__MODULE__{} = t, uri) when is_binary(uri) do
    case Regex.run(t.regex, uri, capture: :all_but_first) do
      nil ->
        :error

      captures ->
        pairs =
          t.vars
          |> Enum.zip(captures)
          |> Map.new(fn {k, v} -> {k, URI.decode(v)} end)

        {:ok, pairs}
    end
  end

  def match(template, uri) when is_binary(template) and is_binary(uri) do
    case parse(template) do
      {:ok, t} -> match(t, uri)
      _ -> :error
    end
  end

  defp extract_vars(template) do
    @expr_pattern
    |> Regex.scan(template, capture: :all_but_first)
    |> Enum.map(fn [_op, name] -> name end)
  end

  defp valid_braces?(template) do
    opens = template |> String.graphemes() |> Enum.count(&(&1 == "{"))
    closes = template |> String.graphemes() |> Enum.count(&(&1 == "}"))

    opens == closes and
      Regex.match?(~r/^([^{}]|\{[+#]?[a-zA-Z_][a-zA-Z0-9_]*\})*$/, template)
  end

  defp build_regex(template) do
    pattern =
      template
      |> split_template()
      |> Enum.map_join(fn
        {:literal, lit} -> Regex.escape(lit)
        {:var, "", _name} -> "([^/?#]+)"
        {:var, "+", _name} -> "([^#]+)"
        {:var, "#", _name} -> "#(.+)"
      end)

    Regex.compile!("^" <> pattern <> "$")
  end

  defp split_template(template) do
    template
    |> then(&Regex.split(@expr_pattern, &1, include_captures: true))
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn part ->
      case Regex.run(@expr_pattern, part) do
        [_full, op, name] -> {:var, op, name}
        _ -> {:literal, part}
      end
    end)
  end
end
