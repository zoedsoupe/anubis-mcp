if Code.ensure_loaded?(Phoenix.HTML) do
  defmodule Peri.Phoenix do
    @moduledoc """
    Bridges Peri schemas and Phoenix forms.

    Validates (and coerces) raw params with `Peri.decode/3`, wraps the
    result in a `Peri.Form` struct, and converts it into a
    `Phoenix.HTML.Form` through the `Phoenix.HTML.FormData` protocol, so
    schemas plug directly into `Phoenix.Component.form/1` and the `<.input>`
    component without Ecto.

    ## LiveView round trip

        @schema %{
          name: {:required, :string},
          age: {:coerce, :string, {:integer, {:gte, 18}}}
        }

        def mount(_params, _session, socket) do
          {:ok, assign(socket, form: Peri.Phoenix.to_form(@schema))}
        end

        def handle_event("validate", %{"peri" => params}, socket) do
          {:noreply, assign(socket, form: Peri.Phoenix.to_form(@schema, params))}
        end

        def handle_event("save", %{"peri" => params}, socket) do
          case Peri.decode(@schema, params) do
            {:ok, data} -> # persist, redirect...
            {:error, _} -> {:noreply, assign(socket, form: Peri.Phoenix.to_form(@schema, params))}
          end
        end

    And in the template:

        <.form for={@form} phx-change="validate" phx-submit="save">
          <.input field={@form[:name]} label="Name" />
          <.input field={@form[:age]} type="number" label="Age" />
        </.form>
    """

    alias Phoenix.HTML.FormData

    @doc """
    Validates `params` against `schema` and returns a `Phoenix.HTML.Form`.

    Accepts the same options as `Phoenix.HTML.FormData.to_form/2` (`:as`,
    `:id`, `:action`, ...) plus `:mode`, which is forwarded to
    `Peri.decode/3` (`:strict` by default, `:permissive` to keep unknown
    fields).

    On success the form carries the validated data and no errors. On failure
    errors are stored in changeset format (`%{field => [{message, opts}]}`,
    nested humanized maps under assoc keys) and the form action defaults to
    `:validate` so LiveView shows the errors.

    The first argument may also be an already built `Peri.Form`: with
    non-empty params it revalidates against the stored schema (the update
    path of a `phx-change` round trip); with no params it is converted as is.
    """
    @spec to_form(Peri.schema() | Peri.Form.t(), map, keyword) :: Phoenix.HTML.Form.t()
    def to_form(schema_or_form, params \\ %{}, opts \\ [])

    def to_form(%Peri.Form{schema: schema}, params, opts)
        when is_map(schema) and is_map(params) and params != %{} do
      to_form(schema, params, opts)
    end

    def to_form(%Peri.Form{} = form, _params, opts) do
      FormData.to_form(form, opts)
    end

    def to_form(schema, params, opts) when is_map(schema) and is_map(params) do
      form =
        case Peri.decode(schema, params, Keyword.take(opts, [:mode])) do
          {:ok, data} ->
            %Peri.Form{schema: schema, data: data, params: params}

          {:error, errors} ->
            %Peri.Form{
              schema: schema,
              params: params,
              errors: changeset_errors(Peri.Error.humanize(errors)),
              action: :validate
            }
        end

      FormData.to_form(form, opts)
    end

    # Humanized leaves are [message]; changeset format is [{message, opts}].
    # Nested maps (assoc errors, list entries keyed by index) recurse.
    defp changeset_errors(humanized) when is_map(humanized) do
      Map.new(humanized, fn
        {key, messages} when is_list(messages) ->
          {key, Enum.map(messages, &{&1, []})}

        {key, nested} when is_map(nested) ->
          {key, changeset_errors(nested)}
      end)
    end
  end
end
