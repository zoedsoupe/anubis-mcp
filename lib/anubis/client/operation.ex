defmodule Anubis.Client.Operation do
  @moduledoc false

  @type progress_options :: [
          token: String.t() | integer(),
          callback: (String.t() | integer(), number(), number() | nil -> any())
        ]

  @type t :: %__MODULE__{
          method: String.t(),
          params: map(),
          progress_opts: progress_options() | nil,
          timeout: pos_integer()
        }

  defstruct [
    :method,
    :timeout,
    params: %{},
    progress_opts: []
  ]

  @doc false
  @spec new(%{
          required(:method) => String.t(),
          optional(:params) => map(),
          optional(:progress_opts) => progress_options() | nil,
          optional(:timeout) => pos_integer()
        }) :: t()
  def new(%{method: method, timeout: timeout} = attrs) do
    %__MODULE__{
      method: method,
      params: Map.get(attrs, :params) || %{},
      progress_opts: Map.get(attrs, :progress_opts),
      timeout: timeout
    }
  end
end
