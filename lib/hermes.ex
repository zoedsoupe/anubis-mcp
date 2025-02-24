defmodule Hermes do
  @moduledoc false

  alias Hermes.Client

  @latest_protocol_version "2024-11-05"
  @supported_versions [@latest_protocol_version]

  def new_client(transport, client_info, capabilities \\ %{}) do
    %Client{
      transport: transport,
      client_info: client_info,
      capabilities: capabilities
    }
  end

  def initialize(%Client{} = client) do
    with {:ok, result} <-
           request(client.transport, %{
             method: "initialize",
             params: %{
               protocolVersion: @latest_protocol_version,
               capabilities: client.capabilities,
               clientInfo: client.client_info
             }
           }),
         :ok <- validate_protocol_version(result.protocolVersion),
         :ok <- client.transport.notify(%{method: "notifications/initialized"}) do
      {:ok,
       %Client{
         client
         | server_capabilities: result.capabilities,
           server_version: result.serverInfo,
           instructions: result.instructions
       }}
    end
  end

  def list_tools(%Client{server_capabilities: %{tools: true}} = client) do
    request(client.transport, %{method: "tools/list"})
  end

  def list_tools(%Client{}) do
    {:error, "Server does not support tools"}
  end

  def call_tool(%Client{server_capabilities: %{tools: true}} = client, name, arguments) do
    request(client.transport, %{
      method: "tools/call",
      params: %{
        name: name,
        arguments: arguments
      }
    })
  end

  def call_tool(%Client{}, _name, _arguments) do
    {:error, "Server does not support tools"}
  end

  # Private helpers for request/response handling
  defp request(transport, payload) do
    payload
    |> Map.put(:jsonrpc, "2.0")
    |> Map.put(:id, generate_request_id())
    |> transport.send()
  end

  defp validate_protocol_version(version) do
    if version in @supported_versions do
      :ok
    else
      {:error, "Unsupported protocol version: #{version}"}
    end
  end

  defp generate_request_id do
    binary = <<
      System.system_time(:nanosecond)::64,
      :erlang.phash2({node(), self()}, 16_777_216)::24,
      :erlang.unique_integer()::32
    >>

    Base.url_encode64(binary)
  end

  defguard is_valid_request_id(request_id)
           when is_binary(request_id) and byte_size(request_id) in 20..200
end
