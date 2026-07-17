defmodule Anubis.SSE.Parser do
  @moduledoc false

  alias Anubis.SSE.Event

  @event_separator ~r/(?:\r\n){2}|\n\n/

  @doc """
  Parses a string containing one or more SSE events.

  Each event is separated by an empty line (two consecutive newlines).
  Returns a list of `%SSE.Event{}` structs.
  """
  def run(sse_data) when is_binary(sse_data) do
    sse_data
    |> String.split(@event_separator, trim: true)
    |> Enum.map(&parse_event/1)
    |> Enum.reject(&(&1.data == ""))
  end

  @doc """
  Incrementally parses SSE bytes from a streaming transport.

  `buffer` holds any trailing partial event from prior chunks. Returns
  complete events and the remaining bytes to carry into the next chunk.
  """
  @spec feed(String.t(), String.t()) :: {[Event.t()], String.t()}
  def feed(buffer, chunk) when is_binary(buffer) and is_binary(chunk) do
    consume(buffer <> chunk, [])
  end

  defp consume(data, acc) do
    case Regex.run(@event_separator, data, return: :index) do
      [{start, len}] ->
        block = binary_part(data, 0, start)
        rest = binary_part(data, start + len, byte_size(data) - start - len)

        acc =
          if String.trim(block) == "" do
            acc
          else
            case parse_event(block) do
              %Event{data: ""} -> acc
              event -> [event | acc]
            end
          end

        consume(rest, acc)

      nil ->
        {Enum.reverse(acc), data}
    end
  end

  defp parse_event(event_block) do
    event_block
    |> String.split(~r/\r?\n/)
    |> Enum.reduce(%Event{}, &parse_event_line/2)
  end

  defp parse_event_line("", event), do: event
  # ignore SSE comments
  defp parse_event_line(<<":", _rest::binary>>, event), do: event

  defp parse_event_line(line, event) do
    case String.split(line, ":", parts: 2) do
      ["id", value] -> %{event | id: String.trim_leading(value)}
      ["event", value] -> %{event | event: String.trim_leading(value)}
      ["data", value] -> handle_data(event, String.trim_leading(value))
      ["retry", value] -> handle_retry(event, String.trim_leading(value))
      [_, _] -> event
      [_] -> event
    end
  end

  defp handle_data(%Event{data: ""} = event, data) do
    %{event | data: data}
  end

  defp handle_data(%Event{data: current_data} = event, data) do
    %{event | data: current_data <> "\n" <> data}
  end

  defp handle_retry(%Event{retry: _} = event, value) do
    case Integer.parse(value) do
      {retry, _} -> %{event | retry: retry}
      :error -> event
    end
  end
end
