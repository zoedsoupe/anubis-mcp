defmodule Peri.Error do
  @moduledoc """
  Defines the structure and functions for handling validation errors in the Peri schema validation library.

  The `Peri.Error` module encapsulates information about validation errors that occur during schema validation. Each error contains details about the path to the invalid data, the type of error, and any nested errors for complex or deeply nested schemas.

  ## Attributes

  - `:message` - A human-readable message describing the error.
  - `:content` - Additional information about the error, such as expected and actual values.
  - `:path` - A list representing the path to the invalid data within the structure being validated.
  - `:key` - The specific key or field that caused the error.
  - `:errors` - A list of nested `Peri.Error` structs for detailed information about nested validation errors.

  ## Example

      iex> error = %Peri.Error{
      ...>   message: "Validation failed",
      ...>   content: %{expected: :string, actual: :integer},
      ...>   path: [:user, :age],
      ...>   key: :age,
      ...>   errors: [
      ...>     %Peri.Error{
      ...>       message: "Expected type string, got integer",
      ...>       content: nil,
      ...>       path: [:user, :age],
      ...>       key: :age,
      ...>       errors: nil
      ...>     }
      ...>   ]
      ...> }
      %Peri.Error{
        message: "Validation failed",
        content: %{expected: :string, actual: :integer},
        path: [:user, :age],
        key: :age,
        errors: [
          %Peri.Error{
            message: "Expected type string, got integer",
            content: nil,
            path: [:user, :age],
            key: :age,
            errors: nil
          }
        ]
      }

  ## Functions

  - `error_to_map/1` - Converts a `Peri.Error` struct to a map, including nested errors.
  """

  @behaviour Exception

  @type t :: %__MODULE__{
          message: String.t(),
          content: keyword,
          path: list(atom),
          key: atom | nil,
          errors: list(t()) | nil
        }

  if Code.ensure_loaded?(Jason) and not Code.ensure_loaded?(JSON) do
    @derive {Jason.Encoder, except: [:__exception__]}
  end

  if Code.ensure_loaded?(JSON) do
    @derive {JSON.Encoder, except: [:__exception__]}
  end

  @derive {Inspect, only: ~w(path key content message errors)a}
  defstruct [:path, :key, :content, :message, :errors, __exception__: true]

  @impl true
  def exception([%__MODULE__{} | _] = errors) when is_list(errors) do
    struct(__MODULE__, errors: errors)
  end

  def exception(%__MODULE__{} = err), do: exception(Map.from_struct(err))

  def exception(params) when is_map(params) or is_list(params) do
    struct!(__MODULE__, params)
  end

  @impl true
  def message(%__MODULE__{errors: nil, path: nil} = err), do: err.message

  def message(%__MODULE__{errors: nil} = err) do
    "#{inspect(err.path, pretty: true)} -> #{err.message}"
  end

  def message(%__MODULE__{errors: nested}) when is_list(nested) do
    nested
    |> Enum.map(&message/1)
    |> then(fn [x | xs] ->
      [x | Enum.map(xs, &(String.duplicate("\s", 16) <> &1))]
    end)
    |> Enum.join(",\n")
  end

  @doc """
  Creates a new parent error with nested errors.

  ## Parameters

    - `path` - A list representing the path to the invalid data.
    - `key` - The specific key or field that caused the error.
    - `errors` - A list of nested `Peri.Error` structs.

  ## Examples

      iex> Peri.Error.new_parent([:user], :age, [%Peri.Error{message: "Invalid age"}])
      %Peri.Error{
        path: [:user, :age],
        key: :age,
        errors: [%Peri.Error{message: "Invalid age"}]
      }
  """
  def new_parent(path, key, [%__MODULE__{} | _] = errors) when is_list(path) do
    %__MODULE__{path: path ++ [key], key: key, errors: errors}
  end

  @doc """
  Creates a new single error with a formatted message and context.

  ## Parameters

    - `message` - A string template for the error message.
    - `context` - A list of key-value pairs to replace in the message template.

  ## Examples

      iex> Peri.Error.new_single("Invalid value for %{field}", [field: "age"])
      %Peri.Error{
        message: "Invalid value for age",
        content: %{field: "age"}
      }
  """
  def new_single(message, context) do
    {override, context} = pop_override(context)
    msg = format_error_message(message, context)
    content = Enum.into(context, %{})

    apply_override(%__MODULE__{message: msg, content: content}, override)
  end

  @doc """
  Creates a new child error with a path, key, message, and context.

  ## Parameters

    - `path` - A list representing the path to the invalid data.
    - `key` - The specific key or field that caused the error.
    - `message` - A string template for the error message.
    - `context` - A list of key-value pairs to replace in the message template.

  ## Examples

      iex> Peri.Error.new_child([:user], :age, "Invalid value for %{field}", [field: "age"])
      %Peri.Error{
        path: [:user, :age],
        key: :age,
        message: "Invalid value for age",
        content: %{field: "age"}
      }
  """
  def new_child(path, key, message, context) do
    {override, context} = pop_override(context)
    msg = format_error_message(message, context)
    content = Enum.into(context, %{})

    %__MODULE__{path: path ++ [key], key: key, message: msg, content: content}
    |> apply_override(override)
  end

  @doc false
  def pop_override(context) when is_list(context),
    do: Keyword.pop(context, :__error_override__)

  def pop_override(context), do: {nil, context}

  defp apply_override(%__MODULE__{} = err, nil), do: err

  defp apply_override(%__MODULE__{} = err, msg) when is_binary(msg),
    do: %{err | message: msg}

  defp apply_override(%__MODULE__{} = err, {mod, fun, args})
       when is_atom(mod) and is_atom(fun) and is_list(args) do
    case apply(mod, fun, [err | args]) do
      msg when is_binary(msg) -> %{err | message: msg}
      _ -> err
    end
  end

  defp apply_override(%__MODULE__{} = err, _), do: err

  @doc """
  Recursively walks an error or list of errors, applying the callback to each
  leaf and replacing its message with the callback's return value.

  Mirrors `Ecto.Changeset.traverse_errors/2`. Useful for translating template
  strings into user-facing locale messages, e.g.

      Peri.Error.traverse_errors(errors, fn err ->
        Gettext.dgettext(MyAppWeb.Gettext, "errors", err.message, err.content || %{})
      end)

  Returns the same error shape with translated messages. Non-string callback
  results are coerced via `to_string/1`.
  """
  @spec traverse_errors([t()] | t(), (t() -> String.t() | term)) :: [t()] | t()
  def traverse_errors(errors, fun) when is_list(errors) and is_function(fun, 1) do
    Enum.map(errors, &traverse_errors(&1, fun))
  end

  def traverse_errors(%__MODULE__{errors: nil} = err, fun) when is_function(fun, 1) do
    %{err | message: fun.(err) |> to_string()}
  end

  def traverse_errors(%__MODULE__{errors: nested} = err, fun)
      when is_list(nested) and is_function(fun, 1) do
    %{err | errors: Enum.map(nested, &traverse_errors(&1, fun))}
  end

  def update_error_paths(%Peri.Error{path: path, errors: nil} = error, new_path) do
    %{error | path: new_path ++ path}
  end

  def update_error_paths(%Peri.Error{path: path, errors: errors} = error, new_path) do
    updated_errors = Enum.map(errors, &update_error_paths(&1, new_path))
    %{error | path: new_path ++ path, errors: updated_errors}
  end

  @doc """
  Produces a compact, human-friendly string for a schema or type definition.

  Used in error messages to avoid dumping the entire schema (which can be huge
  for deeply nested or polymorphic schemas). Named schemas
  (`{:schema, _, name: "..."}`) render as their name; raw maps render as a
  sorted key list (`%{keys: [:a, :b, ...]}`) truncated past 6 entries.
  """
  @spec summarize(term) :: String.t()
  def summarize(type), do: summarize(type, 6)

  defp summarize(type, _max_keys) when is_atom(type), do: inspect(type)

  defp summarize({:schema, schema, opts}, _max_keys)
       when is_list(opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, name} when is_binary(name) -> name
      {:ok, name} -> to_string(name)
      :error -> summarize_schema_opts({:schema, schema, opts})
    end
  end

  defp summarize({:schema, schema, {:additional_keys, _}}, max_keys) do
    summarize(schema, max_keys) <> " (+ additional keys)"
  end

  defp summarize({:schema, schema}, max_keys), do: summarize(schema, max_keys)

  defp summarize({:ref, {mod, name}}, _max_keys) when is_atom(mod) and is_atom(name),
    do: "#{inspect(mod)}.#{name}"

  defp summarize({:ref, name}, _max_keys), do: "ref(#{inspect(name)})"

  defp summarize({:list, type}, max_keys), do: "{:list, #{summarize(type, max_keys)}}"
  defp summarize({:map, type}, max_keys), do: "{:map, #{summarize(type, max_keys)}}"

  defp summarize({:map, kt, vt}, max_keys),
    do: "{:map, #{summarize(kt, max_keys)}, #{summarize(vt, max_keys)}}"

  defp summarize({:tuple, types}, max_keys) when is_list(types),
    do: "{:tuple, [#{Enum.map_join(types, ", ", &summarize(&1, max_keys))}]}"

  defp summarize({:enum, choices}, _max_keys) when is_list(choices),
    do: "{:enum, #{inspect(choices)}}"

  defp summarize({:literal, val}, _max_keys), do: "{:literal, #{inspect(val)}}"

  defp summarize({:either, {a, b}}, max_keys),
    do: "{:either, #{summarize(a, max_keys)} | #{summarize(b, max_keys)}}"

  defp summarize({:oneof, types}, max_keys) when is_list(types),
    do: "{:oneof, [#{Enum.map_join(types, ", ", &summarize(&1, max_keys))}]}"

  defp summarize({:multi, field, branches}, _max_keys) when is_map(branches) do
    tags = branches |> Map.keys() |> Enum.map_join(", ", &inspect/1)
    "{:multi, #{inspect(field)}, [#{tags}]}"
  end

  defp summarize({:required, type}, max_keys),
    do: "{:required, #{summarize(type, max_keys)}}"

  defp summarize({:required, type, _opts}, max_keys),
    do: "{:required, #{summarize(type, max_keys)}}"

  defp summarize({:meta, type, _}, max_keys), do: summarize(type, max_keys)

  defp summarize({type, {:default, _}}, max_keys), do: summarize(type, max_keys)

  defp summarize({type, opts}, _max_keys)
       when is_atom(type) and is_list(opts),
       do: inspect(type)

  defp summarize(schema, max_keys) when is_map(schema) and not is_struct(schema) do
    keys = schema |> Map.keys() |> Enum.sort()
    total = length(keys)

    shown =
      keys
      |> Enum.take(max_keys)
      |> Enum.map_join(", ", &format_key/1)

    cond do
      total == 0 -> "%{}"
      total <= max_keys -> "%{keys: [#{shown}]}"
      true -> "%{keys: [#{shown}, ...]}"
    end
  end

  defp summarize(other, _max_keys),
    do: inspect(other, limit: 3, printable_limit: 50)

  defp summarize_schema_opts({:schema, schema, _opts}), do: summarize(schema, 6)

  defp format_key(key) when is_atom(key), do: inspect(key)
  defp format_key(key) when is_binary(key), do: inspect(key)
  defp format_key(key), do: inspect(key)

  def format_error_message(reason, context) when is_list(context) and is_binary(reason) do
    Enum.reduce(context, reason, fn {key, val}, acc ->
      String.replace(
        acc,
        "%{#{key}}",
        if(is_binary(val), do: val, else: inspect(val, pretty: true))
      )
    end)
  end

  @doc """
  Converts an error or list of errors into a nested, data-shaped map of
  messages, mirroring `Ecto.Changeset.traverse_errors/2` output.

  Each leaf error (one without nested `errors`) contributes its `message`
  under its `path`. Integer path segments become integer keys (list
  indices), atoms stay atoms and binaries stay binaries. Multiple leaf
  errors at the same path append to the message list.

  Leaf errors without a path arise from `Peri.Error.new_single/2`, which is
  how top-level scalar validations report failure
  (`Peri.validate(:string, 5)`). Since there is no field to nest them
  under, they humanize to a bare list of messages instead of a map.

  Because `humanize/1` reads each leaf's final `message` verbatim, it
  composes with `traverse_errors/2`: translate first, then humanize.

  ## Examples

      iex> errors = [
      ...>   %Peri.Error{path: [:addresses], key: :addresses, errors: [
      ...>     %Peri.Error{path: [:addresses, 0, :street], key: :street, message: "is too short"}
      ...>   ]},
      ...>   %Peri.Error{path: [:email], key: :email, message: "is required"}
      ...> ]
      iex> Peri.Error.humanize(errors)
      %{addresses: %{0 => %{street: ["is too short"]}}, email: ["is required"]}

      iex> Peri.Error.humanize(%Peri.Error{message: "expected type of :string received 5 value"})
      ["expected type of :string received 5 value"]

      iex> Peri.Error.humanize([])
      %{}
  """
  @spec humanize(t() | [t()]) ::
          %{
            optional(atom | integer | binary) => [String.t()] | map()
          }
          | [String.t()]
  def humanize(errors) when is_list(errors) do
    Enum.reduce(errors, %{}, fn err, acc -> deep_merge(acc, humanize(err)) end)
  end

  def humanize(%__MODULE__{errors: [_ | _] = nested}), do: humanize(nested)

  def humanize(%__MODULE__{errors: errors, message: nil}) when errors in [nil, []], do: %{}

  def humanize(%__MODULE__{errors: errors, message: message} = err) when errors in [nil, []] do
    case err.path || [] do
      [] -> [message]
      [_ | _] = path -> path_to_map(path, message)
    end
  end

  defp path_to_map([key], message), do: %{key => [message]}
  defp path_to_map([key | rest], message), do: %{key => path_to_map(rest, message)}

  defp deep_merge(left, right) when is_list(left) and is_list(right), do: left ++ right

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, v1, v2 -> deep_merge(v1, v2) end)
  end

  # A message list and a nested map collide when one error's path is a
  # prefix of another's. Keep both, nesting the messages under :_.
  defp deep_merge(left, right) when is_list(left) and is_map(right) do
    Map.update(right, :_, left, &deep_merge(&1, left))
  end

  defp deep_merge(left, right) when is_map(left) and is_list(right),
    do: deep_merge(right, left)

  @doc """
  Recursively converts a `Peri.Error` struct into a map.

  ## Parameters

    - `error` - A `Peri.Error` struct to be transformed.

  ## Examples

      iex> error = %Peri.Error{
      ...>   message: "Validation failed",
      ...>   content: %{expected: :string, actual: :integer},
      ...>   path: [:user, :age],
      ...>   key: :age,
      ...>   errors: [
      ...>     %Peri.Error{
      ...>       message: "Expected type string, got integer",
      ...>       content: nil,
      ...>       path: [:user, :age],
      ...>       key: :age,
      ...>       errors: nil
      ...>     }
      ...>   ]
      ...> }
      iex> Peri.Error.error_to_map(error)
      %{
        message: "Validation failed",
        content: %{expected: :string, actual: :integer},
        path: [:user, :age],
        key: :age,
        errors: [
          %{
            message: "Expected type string, got integer",
            content: nil,
            path: [:user, :age],
            key: :age,
            errors: nil
          }
        ]
      }

  """
  def error_to_map(%Peri.Error{} = err) do
    %{
      path: err.path,
      key: err.key,
      content: transform_content(err.content),
      message: err.message,
      errors: transform_errors(err.errors)
    }
  end

  defp transform_content(nil), do: nil

  defp transform_content(content) when is_map(content) do
    content
    |> Enum.map(&transform_content_entry/1)
    |> Map.new()
  end

  defp transform_content(content) when is_list(content) do
    if Enum.all?(content, &match?({_, _}, &1)) do
      content
      |> Enum.map(&transform_content_entry/1)
      |> Map.new()
    else
      content
    end
  end

  defp transform_content(content), do: content

  defp transform_content_entry({k, v}) do
    if is_tuple(v) do
      {k, transform_tuple(v)}
    else
      {k, v}
    end
  end

  defp transform_tuple(tuple) when is_tuple(tuple) do
    for el <- Tuple.to_list(tuple) do
      if is_tuple(el) do
        transform_tuple(el)
      else
        el
      end
    end
  end

  defp transform_errors(nil), do: nil

  defp transform_errors(errors) when is_list(errors) do
    Enum.map(errors, &error_to_map/1)
  end
end
