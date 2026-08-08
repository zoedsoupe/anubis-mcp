defmodule Anubis.ProtocolTest do
  use ExUnit.Case, async: true

  alias Anubis.MCP.Error
  alias Anubis.Protocol
  alias Anubis.Protocol.V2025_03_26
  alias Anubis.Protocol.V2025_06_18

  doctest Protocol

  describe "backward compatibility" do
    test "supported_versions/0 returns all versions" do
      versions = Protocol.supported_versions()
      assert "2025-03-26" in versions
      assert "2025-06-18" in versions
      assert "2025-11-25" in versions
      refute "2024-11-05" in versions
    end

    test "latest_version/0 returns latest" do
      assert "2025-11-25" = Protocol.latest_version()
    end

    test "fallback_version/0 returns fallback" do
      assert "2025-03-26" = Protocol.fallback_version()
    end

    test "validate_version/1 accepts supported versions" do
      assert :ok = Protocol.validate_version("2025-03-26")
      assert :ok = Protocol.validate_version("2025-06-18")
    end

    test "validate_version/1 rejects unsupported versions" do
      assert {:error, %Error{}} = Protocol.validate_version("9999-01-01")
      assert {:error, %Error{}} = Protocol.validate_version("2024-11-05")
    end

    test "validate_version/1 accepts every version the handshake can negotiate" do
      for version <- Protocol.supported_versions(:legacy) do
        assert :ok = Protocol.validate_version(version)
      end
    end

    test "validate_version/1 rejects a stateless version it could not negotiate" do
      for version <- Protocol.supported_versions(:stateless) do
        assert {:error, %Error{data: data}} = Protocol.validate_version(version)
        refute version in data.supported
      end
    end

    test "get_features/1 returns features for known version" do
      features = Protocol.get_features("2025-03-26")
      assert is_list(features)
      assert :tools in features
    end

    test "get_features/1 returns empty list for unknown version" do
      assert [] = Protocol.get_features("9999-01-01")
    end

    test "supports_feature?/2 checks feature support" do
      assert Protocol.supports_feature?("2025-06-18", :elicitation)
      refute Protocol.supports_feature?("2025-03-26", :elicitation)
    end

    test "negotiate_version/2 matches client and server" do
      assert {:ok, "2025-03-26", V2025_03_26} =
               Protocol.negotiate_version("2025-03-26", "2025-03-26")
    end

    test "negotiate_version/2 prefers server version" do
      assert {:ok, "2025-06-18", V2025_06_18} =
               Protocol.negotiate_version("2025-03-26", "2025-06-18")
    end

    test "negotiate_version/2 accepts a list of server versions" do
      assert {:ok, "2025-03-26", V2025_03_26} =
               Protocol.negotiate_version("2025-03-26", ["2025-11-25", "2025-03-26"])
    end

    test "negotiate_version/2 returns error for incompatible" do
      assert :error = Protocol.negotiate_version("9999-01-01", "8888-01-01")
    end
  end

  describe "get_module/1" do
    test "returns module for known version" do
      assert {:ok, V2025_03_26} = Protocol.get_module("2025-03-26")
      assert {:ok, V2025_06_18} = Protocol.get_module("2025-06-18")
    end

    test "returns :error for unknown version" do
      assert :error = Protocol.get_module("9999-01-01")
      assert :error = Protocol.get_module("2024-11-05")
    end
  end

  describe "era accessors" do
    test "supported_versions/1 partitions by era" do
      assert Protocol.supported_versions(:stateless) == ["2026-07-28"]
      refute "2026-07-28" in Protocol.supported_versions(:legacy)
    end

    test "era/1 and latest_version/1 delegate to the registry" do
      assert {:ok, :stateless} = Protocol.era("2026-07-28")
      assert {:ok, :legacy} = Protocol.era("2025-11-25")
      assert Protocol.latest_version(:stateless) == "2026-07-28"
    end
  end

  describe "registering a stateless version leaves the legacy era untouched" do
    defmodule DefaultVersionsServer do
      @moduledoc false
      use Anubis.Server, name: "test", version: "1.0.0", capabilities: [:tools]
    end

    test "a server built with the DSL advertises no stateless version" do
      versions = DefaultVersionsServer.supported_protocol_versions()

      assert versions == Protocol.supported_versions(:legacy)
      refute "2026-07-28" in versions
    end

    test "the client default protocol version stays in the legacy era" do
      assert {:ok, :legacy} = Protocol.era(Protocol.latest_version())
    end

    test "negotiate_version/2 cannot resolve into the stateless era" do
      for client_version <- ["2026-07-28", "9999-01-01"] do
        refute match?(
                 {:ok, "2026-07-28", _},
                 Protocol.negotiate_version(client_version, Protocol.supported_versions())
               )
      end
    end
  end
end
