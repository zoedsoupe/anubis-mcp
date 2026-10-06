defmodule Anubis.Test.SSEAdapter do
  @moduledoc false

  alias Plug.Adapters.Test.Conn

  defdelegate send_resp(payload, status, headers, body), to: Conn
  defdelegate send_file(payload, status, headers, path, offset, length), to: Conn
  defdelegate read_req_body(payload, opts), to: Conn
  defdelegate inform(payload, status, headers), to: Conn
  defdelegate upgrade(payload, protocol, opts), to: Conn
  defdelegate push(payload, path, headers), to: Conn
  defdelegate get_peer_data(payload), to: Conn
  defdelegate get_http_protocol(payload), to: Conn
  defdelegate get_sock_data(payload), to: Conn
  defdelegate get_ssl_data(payload), to: Conn

  def send_chunked(payload, status, headers) do
    if on_open = Map.get(payload, :on_open), do: on_open.()
    send(payload.owner, {:sse_opened, self()})
    Conn.send_chunked(payload, status, headers)
  end

  def chunk(payload, body) do
    if :atomics.get(payload.disconnected, 1) == 1 do
      {:error, :closed}
    else
      send(payload.owner, {:sse_chunk, self(), IO.iodata_to_binary(body)})
      Conn.chunk(payload, body)
    end
  end
end
