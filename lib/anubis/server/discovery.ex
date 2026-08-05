defmodule Anubis.Server.Discovery do
  @moduledoc false

  @server_info_meta "io.modelcontextprotocol/serverInfo"

  @spec result(module(), module()) :: map()
  def result(server, protocol_module) do
    maybe_put(
      %{
        "resultType" => "complete",
        "supportedVersions" => server.supported_protocol_versions(),
        "capabilities" => protocol_module.server_capabilities(server.server_capabilities()),
        "_meta" => %{@server_info_meta => server.server_info()}
      },
      "instructions",
      server.server_instructions()
    )
  end

  defp maybe_put(result, _key, nil), do: result
  defp maybe_put(result, key, value), do: Map.put(result, key, value)
end
