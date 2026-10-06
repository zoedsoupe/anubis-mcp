defmodule Anubis.Test.SlowMetadata do
  @moduledoc false

  def init(parent), do: parent

  def call(conn, parent) do
    send(parent, {:metadata_stream, self(), Plug.Conn.get_http_protocol(conn)})
    conn = Plug.Conn.send_chunked(conn, 200)
    deadline = System.monotonic_time(:millisecond) + 12_000
    stream_until(conn, deadline)
  end

  defp stream_until(conn, deadline) do
    if System.monotonic_time(:millisecond) < deadline do
      Process.sleep(20)

      case Plug.Conn.chunk(conn, " ") do
        {:ok, conn} -> stream_until(conn, deadline)
        {:error, _reason} -> conn
      end
    else
      conn
    end
  end
end
