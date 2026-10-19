defmodule Peri.Form do
  @moduledoc """
  A form-ready struct holding Peri validation results.

  `Peri.Phoenix.to_form/3` builds this struct from a schema and raw params,
  and the `Phoenix.HTML.FormData` implementation (available when
  `phoenix_html` is loaded) converts it into a `Phoenix.HTML.Form`, so
  Peri schemas plug into `Phoenix.Component.form/1` and `<.input>` without
  Ecto.

  ## Fields

    * `:schema` - the Peri schema the params were validated against
    * `:data` - the validated data (atom keys), `%{}` when validation failed
    * `:params` - the raw params as received (usually string keys)
    * `:errors` - errors in changeset format, `%{field => [{message, opts}]}`
      with nested humanized maps under assoc keys (list entries keyed by index)
    * `:name` - the form name, defaults to `"peri"`
    * `:action` - the form action (`:validate`, `:save`, ...), used by
      LiveView to decide when to show errors
  """

  defstruct schema: nil, data: %{}, params: %{}, errors: %{}, name: "peri", action: nil

  @type errors :: %{optional(atom) => [{String.t(), keyword}] | errors()}

  @type t :: %__MODULE__{
          schema: Peri.schema() | nil,
          data: map,
          params: map,
          errors: errors(),
          name: String.t() | nil,
          action: atom | nil
        }
end

if Code.ensure_loaded?(Phoenix.HTML) do
  defimpl Phoenix.HTML.FormData, for: Peri.Form do
    @moduledoc false

    def to_form(%Peri.Form{} = form, opts) do
      {name, opts} = Keyword.pop(opts, :as)
      {id, opts} = Keyword.pop(opts, :id)
      {action, opts} = Keyword.pop(opts, :action, form.action)
      {hidden, opts} = Keyword.pop(opts, :hidden, [])

      name = if(name, do: to_string(name), else: form.name)
      id = if(id, do: to_string(id), else: name)

      %Phoenix.HTML.Form{
        source: form,
        impl: __MODULE__,
        id: id,
        name: name,
        data: form.data,
        params: normalize_params(form.params),
        errors: flat_errors(form.errors),
        action: action,
        hidden: hidden,
        options: opts
      }
    end

    def to_form(%Peri.Form{} = form, parent, field, opts) do
      {default, opts} = Keyword.pop(opts, :default)
      {prepend, opts} = Keyword.pop(opts, :prepend, [])
      {append, opts} = Keyword.pop(opts, :append, [])
      {name, opts} = Keyword.pop(opts, :as)
      {id, opts} = Keyword.pop(opts, :id)
      {hidden, opts} = Keyword.pop(opts, :hidden, [])
      {action, opts} = Keyword.pop(opts, :action, parent.action)

      id = to_string(id || parent.id <> "_#{field}")
      name = to_string(name || parent.name <> "[#{field}]")
      params = Map.get(parent.params || %{}, to_string(field))

      {cardinality, nested_schema} = nested_schema(form.schema, field, data_for(form.data, field))
      nested_data = data_for(form.data, field) || default
      nested_errors = Map.get(form.errors, field, %{})

      case cardinality do
        :one ->
          entry =
            child_form(form, nested_schema, nested_data, params, nested_errors, %{
              id: id,
              name: name,
              action: action,
              hidden: hidden,
              options: opts
            })

          [entry]

        :many ->
          entries = list_entries(params, nested_data, prepend, append)

          for {{data, entry_params}, index} <- Enum.with_index(entries) do
            index_errors = index_errors(nested_errors, index)

            child_form(form, nested_schema, data, entry_params, index_errors, %{
              id: id <> "_#{index}",
              name: name <> "[#{index}]",
              index: index,
              action: action,
              hidden: hidden,
              options: opts
            })
          end
      end
    end

    def input_value(_source, %{data: data, params: params}, field)
        when is_atom(field) or is_binary(field) do
      key = to_string(field)
      data = data || %{}

      case params do
        %{^key => value} ->
          value

        %{} ->
          case Map.fetch(data, field) do
            {:ok, value} -> value
            :error -> Map.get(data, key)
          end
      end
    end

    def input_validations(%Peri.Form{schema: schema}, _form, field)
        when is_atom(field) or is_binary(field) do
      case schema && schema_field(schema, field) do
        nil -> []
        {:required, type} -> [required: true] ++ length_validations(type)
        type -> length_validations(type)
      end
    end

    # Nested schema resolution: unwraps {:required, type} and tells apart
    # single nested maps (cardinality :one) from lists of maps (:many).
    # Without schema information, the data shape decides.
    defp nested_schema(schema, field, data) do
      case schema && schema_field(schema, field) do
        nil -> if is_list(data), do: {:many, nil}, else: {:one, nil}
        type -> cardinality(type)
      end
    end

    defp cardinality({:required, type}), do: cardinality(type)
    defp cardinality({:list, inner}), do: {:many, inner}
    defp cardinality(%{} = nested), do: {:one, nested}
    defp cardinality(_other), do: {:one, nil}

    defp schema_field(schema, field) do
      Map.get(schema, field) || Map.get(schema, String.to_existing_atom(to_string(field)))
    rescue
      ArgumentError -> Map.get(schema, field)
    end

    defp length_validations({:string, {:min, min}}), do: [minlength: min]
    defp length_validations({:string, {:max, max}}), do: [maxlength: max]
    defp length_validations(_type), do: []

    # Builds one nested %Phoenix.HTML.Form{} backed by a child %Peri.Form{}
    # so input_value/3 and input_validations/3 keep working at any depth.
    defp child_form(parent, schema, data, params, errors, attrs) do
      child = %Peri.Form{
        schema: schema,
        data: data || %{},
        params: params || %{},
        errors: errors || %{},
        name: parent.name,
        action: attrs.action
      }

      %Phoenix.HTML.Form{
        source: child,
        impl: __MODULE__,
        id: attrs.id,
        name: attrs.name,
        index: Map.get(attrs, :index),
        data: child.data,
        params: normalize_params(child.params),
        errors: flat_errors(child.errors),
        action: attrs.action,
        hidden: attrs.hidden,
        options: attrs.options
      }
    end

    # Entries for cardinality :many, mirroring the Map impl: params win when
    # present, otherwise prepend ++ data ++ append with empty params.
    defp list_entries(params, _data, _prepend, _append) when is_map(params) and params != %{} do
      params
      |> Enum.sort_by(fn {index, _} ->
        case Integer.parse(to_string(index)) do
          {numeric_index, ""} -> {0, numeric_index}
          _ -> {1, to_string(index)}
        end
      end)
      |> Enum.map(fn {_index, entry_params} -> {nil, entry_params} end)
    end

    defp list_entries(params, _data, _prepend, _append) when is_list(params) and params != [] do
      Enum.map(params, fn entry_params -> {nil, entry_params} end)
    end

    defp list_entries(_params, data, prepend, append) do
      Enum.map(prepend ++ List.wrap(data) ++ append, &{&1, %{}})
    end

    # Humanized list errors are keyed by integer index; params may have been
    # submitted with gaps, so fall back to string keys too.
    defp index_errors(errors, index) when is_map(errors) do
      Map.get(errors, index) || Map.get(errors, to_string(index)) || %{}
    end

    defp index_errors(_errors, _index), do: %{}

    defp data_for(data, field) when is_map(data) do
      Map.get(data, field) || Map.get(data, to_string(field))
    end

    defp data_for(_data, _field), do: nil

    # Top-level errors must be a flat list of {field, {message, opts}};
    # nested humanized maps are surfaced through to_form/4 instead.
    defp flat_errors(errors) when is_map(errors) do
      for {field, messages} <- errors,
          is_list(messages),
          {message, opts} <- messages do
        {field, {message, opts}}
      end
    end

    defp flat_errors(_errors), do: []

    # Form params are always looked up by string key.
    defp normalize_params(params) when is_map(params) do
      Map.new(params, fn
        {key, value} when is_atom(key) -> {Atom.to_string(key), value}
        {key, value} -> {key, value}
      end)
    end

    defp normalize_params(params), do: params
  end
end
