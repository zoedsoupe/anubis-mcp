defmodule Peri.Parser do
  @moduledoc """
  The `Peri.Parser` module is responsible for managing the state during schema validation. 
  It centralizes functions to handle updating data, adding errors, and managing the path within 
  the data structure being validated.

  ## Struct
  The `Peri.Parser` struct has the following fields:

  - `:data` - The current state of the data being validated.
  - `:errors` - A list of errors encountered during validation.
  - `:path` - The current path within the data structure being validated.
  """

  defstruct [
    :data,
    :root_data,
    :current_data,
    field_presence?: true,
    errors: [],
    path: [],
    ref_depth: 0
  ]

  def for_field(%__MODULE__{} = parent, key, exists?) do
    root = parent.root_data || parent.data
    current_data = parent.current_data || parent.data
    path = List.wrap(parent.path) ++ List.wrap(key)
    %{parent | current_data: current_data, root_data: root, field_presence?: exists?, path: path}
  end

  @doc """
  Initializes a new `Peri.Parser` struct with the given data.

  ## Parameters
  - `data` - The initial data to be validated.

  ## Examples

      iex> Peri.Parser.new(%{name: "Alice"})
      %Peri.Parser{data: %{name: "Alice"}, errors: [], path: []}
  """
  def new(data, root_data: root) do
    %__MODULE__{data: data, root_data: root, current_data: data, errors: [], path: []}
  end

  @doc """
  Updates the data in the parser state at the given key with the specified value.

  ## Parameters
  - `state` - The current `Peri.Parser` state.
  - `key` - The key to update in the data.
  - `val` - The value to set at the specified key.

  ## Examples

      iex> state = Peri.Parser.new(%{name: "Alice"})
      iex> Peri.Parser.update_data(state, :age, 30)
      %Peri.Parser{data: %{name: "Alice", age: 30}, errors: [], path: []}
  """
  def update_data(%__MODULE__{} = state, key, val) do
    %{state | data: Peri.put_in_enum(state.data, key, val)}
  end

  @doc """
  Adds an error to the parser state's list of errors.

  ## Parameters
  - `state` - The current `Peri.Parser` state.
  - `err` - The `%Peri.Error{}` struct representing the error to add.

  ## Examples

      iex> state = Peri.Parser.new(%{name: "Alice"})
      iex> error = %Peri.Error{path: [:name], message: "is required", content: []}
      iex> Peri.Parser.add_error(state, error)
      %Peri.Parser{data: %{name: "Alice"}, errors: [%Peri.Error{path: [:name], message: "is required", content: []}], path: []}
  """
  def add_error(%__MODULE__{} = state, %Peri.Error{} = err) do
    %{state | errors: [err | state.errors]}
  end

  @doc """
  Creates a new parser for a list element, preserving the root data.

  ## Parameters
  - `element_data` - The data for the current list element.
  - `parent_parser` - The parent parser containing root data and path information.
  - `index` - The index of the element in the list.

  ## Examples

      iex> parent = Peri.Parser.new(%{items: [1, 2, 3]}, root_data: %{items: [1, 2, 3]})
      iex> Peri.Parser.for_list_element(1, parent, 0)
      %Peri.Parser{data: 1, current_data: 1, root_data: %{items: [1, 2, 3]}, errors: [], path: [0]}
  """
  def for_list_element(element_data, %__MODULE__{} = parent_parser, index) do
    %__MODULE__{
      data: element_data,
      current_data: element_data,
      root_data: parent_parser.root_data || parent_parser.data,
      errors: [],
      path: parent_parser.path ++ [index],
      ref_depth: parent_parser.ref_depth
    }
  end

  @doc """
  Increments the ref-resolution depth counter. Used by `{:ref, _}`
  directive resolution to bound recursion on cyclic data.
  """
  def bump_ref_depth(%__MODULE__{ref_depth: d} = state), do: %{state | ref_depth: d + 1}
end
