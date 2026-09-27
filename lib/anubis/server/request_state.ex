defmodule Anubis.Server.RequestState do
  @moduledoc """
  The integrity-protected `requestState` of multi round-trip requests.

  A handler that returns an `Anubis.Server.InputRequired` may attach any Erlang
  term as state. The client echoes the resulting string on its retry, so the
  specification treats it as attacker-controlled input: a server whose state
  influences what it does must protect its integrity and reject state that
  fails verification.

  This module signs the term with HMAC-SHA256 and binds it to:

    * the authenticated principal (`Anubis.Server.Frame.subject/1`), so state
      issued to one user is refused for another;
    * the originating request, its method plus the tool or prompt name or the
      resource URI, so state cannot move to a different request;
    * an expiry, `:request_state_ttl` milliseconds after it was issued
      (default: ten minutes).

  A server that authenticates outside `Anubis.Server.Authorization` has no
  subject on the frame, and should carry its own principal inside the term and
  check it on retry.

  These measures bound replay; they do not make a state single-use. A server
  that must consume a state at most once enforces that itself.

  ## Configuration

      config :anubis_mcp, request_state_secret: System.fetch_env!("MCP_REQUEST_STATE_SECRET")

  The secret must be a binary of at least 32 bytes. Signing without one raises.
  """

  alias Anubis.Server.Frame

  @prefix "v1"
  @default_ttl_ms to_timeout(minute: 10)
  @min_secret_bytes 32

  @type binding :: {method :: String.t(), target :: String.t()}

  @doc """
  Signs `term` for the request `binding` identifies, as the principal on `frame`.
  """
  @spec sign(term(), Frame.t(), binding()) :: String.t()
  def sign(term, %Frame{} = frame, binding) do
    expires_at = System.system_time(:millisecond) + ttl()
    payload = :erlang.term_to_binary({term, Frame.subject(frame), binding, expires_at})

    Enum.join([@prefix, encode(payload), encode(mac(payload))], ".")
  end

  @doc """
  Verifies a state the client echoed and returns the term it carries.

  Fails with `:invalid` when the string is malformed or its signature does not
  match, `:mismatch` when it was issued to another principal or request, and
  `:expired` once its TTL has lapsed.
  """
  @spec verify(String.t(), Frame.t(), binding()) :: {:ok, term()} | {:error, :invalid | :mismatch | :expired}
  def verify(token, %Frame{} = frame, binding) when is_binary(token) do
    with {:ok, payload} <- authenticate(token),
         {:ok, {term, principal, issued_for, expires_at}} <- to_term(payload),
         :ok <- match(principal == Frame.subject(frame) and issued_for == binding),
         :ok <- unexpired(expires_at) do
      {:ok, term}
    else
      {:error, reason} -> {:error, reason}
      _malformed -> {:error, :invalid}
    end
  end

  defp to_term(payload) do
    {:ok, :erlang.binary_to_term(payload, [:safe])}
  rescue
    ArgumentError -> {:error, :invalid}
  end

  defp authenticate(token) do
    with [@prefix, encoded_payload, encoded_mac] <- String.split(token, "."),
         {:ok, payload} <- decode(encoded_payload),
         {:ok, given_mac} <- decode(encoded_mac),
         true <- :crypto.hash_equals(mac(payload), given_mac) do
      {:ok, payload}
    else
      _invalid -> {:error, :invalid}
    end
  end

  defp match(true), do: :ok
  defp match(false), do: {:error, :mismatch}

  defp unexpired(expires_at) when is_integer(expires_at) do
    if System.system_time(:millisecond) < expires_at, do: :ok, else: {:error, :expired}
  end

  defp unexpired(_expires_at), do: {:error, :invalid}

  defp mac(payload), do: :crypto.mac(:hmac, :sha256, secret(), payload)

  defp encode(binary), do: Base.url_encode64(binary, padding: false)
  defp decode(encoded), do: Base.url_decode64(encoded, padding: false)

  defp ttl, do: Application.get_env(:anubis_mcp, :request_state_ttl, @default_ttl_ms)

  defp secret do
    case Application.get_env(:anubis_mcp, :request_state_secret) do
      secret when is_binary(secret) and byte_size(secret) >= @min_secret_bytes ->
        secret

      _missing ->
        raise ArgumentError,
              "config :anubis_mcp, :request_state_secret must be a binary of at least " <>
                "#{@min_secret_bytes} bytes to sign a requestState"
    end
  end
end
