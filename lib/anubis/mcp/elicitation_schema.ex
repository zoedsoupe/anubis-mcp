defmodule Anubis.MCP.ElicitationSchema do
  @moduledoc """
  Validator for the restricted JSON Schema subset allowed in elicitation requests.

  Per the MCP specification, an `elicitation/create` `requestedSchema`
  must be a flat object whose properties are all primitives. This module validates
  both the schema map itself (`validate/2`) and content payloads against a
  previously validated schema (`validate_content/2`).

  Two profiles exist, because the permitted subset grew:

    * `:legacy` — the 2025-06-18 subset.
    * `:latest` — the 2025-11-25 subset, which adds titled enums, multi-select
      enums, and defaults on every primitive.

  Permitted property schemas under `:legacy`:

    * `string` with optional `minLength`, `maxLength`, `format`
      (one of `"email"`, `"uri"`, `"date"`, `"date-time"`)
    * `string` enum with `enum` and optional matching `enumNames`
    * `number` / `integer` with optional `minimum`, `maximum`
    * `boolean` with optional `default`

  `:latest` additionally permits:

    * `default` on `string`, `number` / `integer`, and every enum
    * `string` with `oneOf: [{const, title}]` (titled single select)
    * `array` with `minItems` / `maxItems` and either
      `items: {type: "string", enum}` (untitled multi select) or
      `items: {anyOf: [{const, title}]}` (titled multi select)
  """

  import Peri, except: [validate: 1, validate: 2]

  @permitted_string_formats ~w(email uri date date-time)

  @type profile :: :legacy | :latest

  @post_legacy_keywords ~w(oneOf items minItems maxItems)

  @titled_option_schema %{
    "const" => {:required, :string},
    "title" => {:required, :string}
  }

  @untitled_items_schema %{
    "type" => {:required, {:literal, "string"}},
    "enum" => {:required, {:list, :string}}
  }

  @titled_items_schema %{
    "anyOf" => {:required, {:list, @titled_option_schema}}
  }

  @string_property_schema %{
    "type" => {:required, {:literal, "string"}},
    "title" => :string,
    "description" => :string,
    "minLength" => {:integer, {:gte, 0}},
    "maxLength" => {:integer, {:gte, 0}},
    "format" => {:enum, @permitted_string_formats}
  }

  @enum_property_schema %{
    "type" => {:required, {:literal, "string"}},
    "title" => :string,
    "description" => :string,
    "enum" => {:required, {:list, :string}},
    "enumNames" => {:list, :string}
  }

  @titled_single_select_schema %{
    "type" => {:required, {:literal, "string"}},
    "title" => :string,
    "description" => :string,
    "oneOf" => {:required, {:list, @titled_option_schema}}
  }

  @multi_select_schema %{
    "type" => {:required, {:literal, "array"}},
    "title" => :string,
    "description" => :string,
    "minItems" => {:integer, {:gte, 0}},
    "maxItems" => {:integer, {:gte, 0}},
    "items" => {:required, {:either, {@untitled_items_schema, @titled_items_schema}}}
  }

  @numeric_property_schema %{
    "type" => {:required, {:enum, ~w(number integer)}},
    "title" => :string,
    "description" => :string,
    "minimum" => {:either, {:integer, :float}},
    "maximum" => {:either, {:integer, :float}}
  }

  @boolean_property_schema %{
    "type" => {:required, {:literal, "boolean"}},
    "title" => :string,
    "description" => :string,
    "default" => :boolean
  }

  # `:default` is declared per profile rather than merged in, so the legacy
  # profile keeps rejecting it where 2025-06-18 did not define it.
  @string_property_schema_latest Map.put(@string_property_schema, "default", :string)

  @enum_property_schema_latest Map.put(@enum_property_schema, "default", :string)

  @titled_single_select_schema_latest Map.put(@titled_single_select_schema, "default", :string)

  @multi_select_schema_latest Map.put(@multi_select_schema, "default", {:list, :string})

  @numeric_property_schema_latest Map.put(@numeric_property_schema, "default", {:either, {:integer, :float}})

  defschema(:requested_schema, %{
    "type" => {:required, {:literal, "object"}},
    "properties" => {:map, :string, {:custom, {__MODULE__, :validate_property, [:legacy]}}},
    "required" => {:list, :string}
  })

  defschema(:requested_schema_latest, %{
    "type" => {:required, {:literal, "object"}},
    "properties" => {:map, :string, {:custom, {__MODULE__, :validate_property, [:latest]}}},
    "required" => {:list, :string}
  })

  @doc """
  Validates a `requestedSchema` map fits the elicitation subset.

  The `profile` selects which subset the schema must fit: `:legacy` for
  2025-06-18, `:latest` for 2025-11-25. Defaults to `:latest`.

  Returns `:ok` or `{:error, reason}` where `reason` is a human-readable string.
  """
  @spec validate(term(), profile()) :: :ok | {:error, String.t()}
  def validate(schema, profile \\ :latest)

  def validate(schema, profile) when is_map(schema) do
    with {:ok, validated} <- validate_requested_schema(schema, profile),
         :ok <- validate_required_declared(validated) do
      :ok
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, errors} when is_list(errors) -> {:error, format_errors(errors)}
    end
  end

  def validate(_, _profile), do: {:error, "requestedSchema must be a map"}

  @doc """
  Adapter that plugs `validate/2` into Peri's custom validator contract.

  Peri expects `{:error, template, info}`; `validate/2` speaks `:ok |
  {:error, String.t()}`, so a raw call would crash the traversal on the error
  path.
  """
  @spec validate_peri(term(), profile()) :: :ok | {:error, String.t(), keyword()}
  def validate_peri(schema, profile \\ :latest) do
    case validate(schema, profile) do
      :ok -> :ok
      {:error, reason} -> {:error, reason, []}
    end
  end

  defp validate_requested_schema(schema, :legacy), do: requested_schema(schema)
  defp validate_requested_schema(schema, :latest), do: requested_schema_latest(schema)

  @doc false
  @spec validate_property(term(), profile()) :: :ok | {:error, String.t(), keyword()}
  def validate_property(prop, profile \\ :latest)

  def validate_property(prop, profile) when is_map(prop) do
    schema = dispatch_property_schema(prop, profile)

    with :ok <- reject_keywords_outside_profile(prop, profile),
         {:ok, _validated} <- Peri.validate(schema, prop),
         :ok <- validate_enum_names_match(prop),
         :ok <- validate_default_in_enum(prop) do
      :ok
    else
      {:error, errors} when is_list(errors) ->
        {:error, format_errors(errors), []}

      {:error, reason} when is_binary(reason) ->
        {:error, reason, []}
    end
  end

  def validate_property(other, _profile) do
    {:error, "property must be a map, got %{actual}", actual: inspect(other)}
  end

  # Peri validates a map in strict mode by dropping keys the schema does not
  # declare, so a keyword this profile never defined would be stripped and read
  # as absent. Rejecting them here is what keeps the legacy profile legacy: the
  # 2025-06-18 subset has no `oneOf`, no arrays, and a `default` only on
  # booleans.
  defp reject_keywords_outside_profile(prop, :legacy) do
    unsupported =
      Enum.filter(@post_legacy_keywords, &Map.has_key?(prop, &1)) ++
        if(Map.has_key?(prop, "default") and Map.get(prop, "type") != "boolean",
          do: ["default"],
          else: []
        )

    case unsupported do
      [] -> :ok
      keywords -> {:error, "#{inspect(keywords)} require the 2025-11-25 elicitation subset"}
    end
  end

  defp reject_keywords_outside_profile(_prop, :latest), do: :ok

  # `:latest` is checked first: a titled enum carries `oneOf` and a multi-select
  # carries `array`, and neither shape is legal in the legacy profile.
  defp dispatch_property_schema(%{"oneOf" => _}, :latest), do: @titled_single_select_schema_latest
  defp dispatch_property_schema(%{"type" => "array"}, :latest), do: @multi_select_schema_latest
  defp dispatch_property_schema(%{"enum" => _}, :latest), do: @enum_property_schema_latest
  defp dispatch_property_schema(%{"type" => "string"}, :latest), do: @string_property_schema_latest
  defp dispatch_property_schema(%{"type" => "number"}, :latest), do: @numeric_property_schema_latest
  defp dispatch_property_schema(%{"type" => "integer"}, :latest), do: @numeric_property_schema_latest
  defp dispatch_property_schema(%{"type" => "boolean"}, :latest), do: @boolean_property_schema
  defp dispatch_property_schema(%{"enum" => _}, :legacy), do: @enum_property_schema
  defp dispatch_property_schema(%{"type" => "string"}, :legacy), do: @string_property_schema
  defp dispatch_property_schema(%{"type" => "number"}, :legacy), do: @numeric_property_schema
  defp dispatch_property_schema(%{"type" => "integer"}, :legacy), do: @numeric_property_schema
  defp dispatch_property_schema(%{"type" => "boolean"}, :legacy), do: @boolean_property_schema
  defp dispatch_property_schema(_, _profile), do: @string_property_schema

  defp validate_enum_names_match(%{"enum" => enum, "enumNames" => names}) do
    if length(enum) == length(names) do
      :ok
    else
      {:error, "enumNames must have the same length as enum"}
    end
  end

  defp validate_enum_names_match(_), do: :ok

  # A default outside the enum would pre-fill a value the schema then rejects.
  defp validate_default_in_enum(%{"default" => default, "enum" => enum}) do
    validate_default_in(default, enum)
  end

  defp validate_default_in_enum(%{"default" => default, "oneOf" => options}) when is_list(options) do
    validate_default_in(default, Enum.map(options, & &1["const"]))
  end

  defp validate_default_in_enum(%{"default" => default, "items" => %{"enum" => values}}) do
    validate_default_in_list(default, values)
  end

  defp validate_default_in_enum(%{"default" => default, "items" => %{"anyOf" => options}}) when is_list(options) do
    validate_default_in_list(default, Enum.map(options, & &1["const"]))
  end

  defp validate_default_in_enum(_), do: :ok

  defp validate_default_in(default, values) do
    if default in values do
      :ok
    else
      {:error, "default #{inspect(default)} is not one of the enum values"}
    end
  end

  defp validate_default_in_list(default, values) when is_list(default) do
    case Enum.reject(default, &(&1 in values)) do
      [] ->
        :ok

      invalid ->
        {:error, "default values #{inspect(invalid)} are not among the enum values"}
    end
  end

  defp validate_default_in_list(default, _values) do
    {:error, "default must be a list for a multi-select, got #{inspect(default)}"}
  end

  defp validate_required_declared(%{"required" => required, "properties" => properties})
       when is_list(required) and is_map(properties) do
    case Enum.find(required, fn name -> not Map.has_key?(properties, name) end) do
      nil -> :ok
      missing -> {:error, "required property #{inspect(missing)} is not declared in properties"}
    end
  end

  defp validate_required_declared(_), do: :ok

  @doc """
  Validates a content map against an already-validated elicitation schema.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec validate_content(term(), map()) :: :ok | {:error, String.t()}
  def validate_content(content, %{"type" => "object"} = requested) when is_map(content) do
    properties = Map.get(requested, "properties", %{})
    required = Map.get(requested, "required", [])

    with :ok <- reject_unknown_keys(content, properties) do
      peri_schema = build_content_schema(properties, required)

      case Peri.validate(peri_schema, content, mode: :strict) do
        {:ok, _validated} -> :ok
        {:error, errors} when is_list(errors) -> {:error, format_errors(errors)}
      end
    end
  end

  def validate_content(content, %{"type" => "object"}) do
    {:error, "content must be a map, got #{inspect(content)}"}
  end

  def validate_content(_content, _schema) do
    {:error, "schema must be an object schema"}
  end

  defp reject_unknown_keys(content, properties) do
    case Enum.find(Map.keys(content), fn k -> not Map.has_key?(properties, k) end) do
      nil -> :ok
      key -> {:error, "unknown property #{inspect(key)}"}
    end
  end

  defp build_content_schema(properties, required) do
    required_set = MapSet.new(required)

    Map.new(properties, fn {name, prop_schema} ->
      type = property_to_peri(prop_schema)
      type = if MapSet.member?(required_set, name), do: {:required, type}, else: type
      {name, type}
    end)
  end

  defp property_to_peri(%{"enum" => values}), do: {:enum, values}

  # A titled single select accepts any of its `const` values; the titles are
  # display metadata the client shows, not part of the value.
  defp property_to_peri(%{"oneOf" => options}) when is_list(options) do
    {:enum, Enum.map(options, & &1["const"])}
  end

  defp property_to_peri(%{"type" => "array", "items" => %{"enum" => values}} = s) do
    multi_select_peri({:enum, values}, s)
  end

  defp property_to_peri(%{"type" => "array", "items" => %{"anyOf" => options}} = s) when is_list(options) do
    multi_select_peri({:enum, Enum.map(options, & &1["const"])}, s)
  end

  defp property_to_peri(%{"type" => "string"} = s) do
    constraints =
      []
      |> add_constraint(s, "minLength", :min)
      |> add_constraint(s, "maxLength", :max)

    base =
      case constraints do
        [] -> :string
        [single] -> {:string, single}
        many -> {:string, many}
      end

    case Map.get(s, "format") do
      nil -> base
      format -> {:custom, {__MODULE__, :validate_string_format, [format, base]}}
    end
  end

  defp property_to_peri(%{"type" => "integer"} = s) do
    case numeric_constraints(s) do
      [] -> :integer
      [single] -> {:integer, single}
      many -> {:integer, many}
    end
  end

  defp property_to_peri(%{"type" => "number"} = s) do
    case numeric_constraints(s) do
      [] -> {:either, {:integer, :float}}
      [single] -> {:either, {{:integer, single}, {:float, single}}}
      many -> {:either, {{:integer, many}, {:float, many}}}
    end
  end

  defp property_to_peri(%{"type" => "boolean"}), do: :boolean

  defp property_to_peri(_), do: :any

  defp multi_select_peri(item_schema, schema) do
    case list_constraints(schema) do
      [] -> {:list, item_schema}
      constraints -> {:list, item_schema, constraints}
    end
  end

  defp list_constraints(schema) do
    []
    |> add_constraint(schema, "minItems", :min)
    |> add_constraint(schema, "maxItems", :max)
  end

  defp add_constraint(acc, schema, json_key, peri_key) do
    case Map.fetch(schema, json_key) do
      {:ok, value} -> [{peri_key, value} | acc]
      :error -> acc
    end
  end

  defp numeric_constraints(schema) do
    []
    |> add_constraint(schema, "minimum", :gte)
    |> add_constraint(schema, "maximum", :lte)
  end

  @doc false
  @spec validate_string_format(term(), String.t(), term()) ::
          :ok | {:error, String.t(), keyword()}
  def validate_string_format(value, format, base_type) do
    with :ok <- run_base_string(value, base_type),
         :ok <- check_format(value, format) do
      :ok
    else
      {:error, reason} -> {:error, reason, []}
    end
  end

  defp run_base_string(value, :string) when is_binary(value), do: :ok
  defp run_base_string(value, :string), do: {:error, "expected string, got #{inspect(value)}"}

  defp run_base_string(value, base) do
    case Peri.validate(base, value) do
      {:ok, _} -> :ok
      {:error, errors} when is_list(errors) -> {:error, format_errors(errors)}
    end
  end

  defp check_format(value, "email") when is_binary(value) do
    if String.match?(value, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/) do
      :ok
    else
      {:error, "value is not a valid email"}
    end
  end

  defp check_format(value, "uri") when is_binary(value) do
    case URI.new(value) do
      {:ok, %URI{scheme: scheme}} when is_binary(scheme) and scheme != "" -> :ok
      _ -> {:error, "value is not a valid URI"}
    end
  end

  defp check_format(value, "date") when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, _} -> :ok
      _ -> {:error, "value is not a valid ISO 8601 date"}
    end
  end

  defp check_format(value, "date-time") when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _, _} -> :ok
      _ -> {:error, "value is not a valid ISO 8601 date-time"}
    end
  end

  defp check_format(value, format) do
    {:error, "value #{inspect(value)} is not a valid #{format}"}
  end

  defp format_errors(errors) do
    errors
    |> List.wrap()
    |> Enum.map_join("; ", &format_error/1)
  end

  defp format_error(%Peri.Error{message: message, path: path}) when path in [nil, []], do: message
  defp format_error(%Peri.Error{message: message, path: path}), do: "#{Enum.join(path, ".")}: #{message}"
  defp format_error(other), do: inspect(other)
end
