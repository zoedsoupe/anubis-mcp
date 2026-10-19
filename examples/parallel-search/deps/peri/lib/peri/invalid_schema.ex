defmodule Peri.InvalidSchema do
  @moduledoc """
  Exception raised when an invalid schema is encountered.

  This exception is raised with a list of `Peri.Error` structs,
  providing a readable message overview of the validation errors.
  """

  defexception [:message, :errors]

  @type t :: %__MODULE__{
          message: String.t(),
          errors: [Peri.Error.t()]
        }

  @impl true
  def exception(errors) do
    %__MODULE__{
      message: format_errors(errors),
      errors: errors
    }
  end

  defp format_errors(errors) do
    Enum.map_join(errors, "\n", &format_error/1)
  end

  defp format_error(%Peri.Error{
         message: message,
         content: content,
         path: path,
         key: key,
         errors: nested_errors
       }) do
    error_details = [
      "Error in #{Enum.join(path, " -> ")}:",
      "  Key: #{key}",
      "  Message: #{message}",
      format_content(content)
    ]

    nested_error_details =
      if nested_errors do
        Enum.map_join(nested_errors, "\n", &("  " <> format_error(&1)))
      else
        ""
      end

    (error_details ++ [nested_error_details])
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp format_content(nil), do: ""
  defp format_content(content), do: "  Content: #{inspect(content, pretty: true)}"
end
