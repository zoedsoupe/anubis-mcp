defmodule Upcase.Prompts.TextTransform do
  @moduledoc "Generate prompts for various text transformation requests"

  use Anubis.Server.Component, type: :prompt
  alias Anubis.Server.Response

  schema do
    %{
      text: {:required, :string},
      transformations: {
        {:list, {:enum, ["uppercase", "lowercase", "titlecase", "reverse", "remove_spaces"]}},
        {:default, ["uppercase"]}
      },
      explain: {:boolean, {:default, false}}
    }
  end

  @impl true
  def get_messages(%{text: text, transformations: transforms, explain: explain?}, frame) do
    transform_list = Enum.join(transforms, ", ")

    base_message = """
    Please apply the following transformations to this text: #{transform_list}

    Text: "#{text}"
    """

    explanation =
      if explain? do
        "\n\nAlso explain what each transformation does and show the result after each step."
      else
        ""
      end

    {:reply, Response.user_message(Response.prompt(), base_message <> explanation), frame}
  end
end
