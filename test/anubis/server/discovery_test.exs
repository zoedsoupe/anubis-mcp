defmodule Anubis.Server.DiscoveryTest do
  use ExUnit.Case, async: true

  alias Anubis.Protocol.V2026_07_28
  alias Anubis.Server.Discovery

  defmodule ServerWithInstructions do
    @moduledoc false

    def supported_protocol_versions, do: ["2026-07-28"]
    def server_capabilities, do: %{"tools" => %{}, "resources" => %{}, "roots" => %{}}
    def server_info, do: %{"name" => "Stateless Test Server", "version" => "2.0.0"}
    def server_instructions, do: "Discover a version before sending operational requests."
  end

  defmodule ServerWithoutInstructions do
    @moduledoc false

    def supported_protocol_versions, do: ["2026-07-28"]
    def server_capabilities, do: %{}
    def server_info, do: %{"name" => "Minimal Server", "version" => "1.0.0"}
    def server_instructions, do: nil
  end

  describe "result/2" do
    test "given a stateless server, when discovery is rendered, then it returns the complete server contract" do
      assert Discovery.result(ServerWithInstructions, V2026_07_28) == %{
               "resultType" => "complete",
               "supportedVersions" => ["2026-07-28"],
               "capabilities" => %{"tools" => %{}, "resources" => %{}},
               "instructions" => "Discover a version before sending operational requests.",
               "_meta" => %{
                 "io.modelcontextprotocol/serverInfo" => %{
                   "name" => "Stateless Test Server",
                   "version" => "2.0.0"
                 }
               }
             }
    end

    test "given no server instructions, when discovery is rendered, then it omits the optional field" do
      result = Discovery.result(ServerWithoutInstructions, V2026_07_28)

      refute Map.has_key?(result, "instructions")
    end
  end
end
