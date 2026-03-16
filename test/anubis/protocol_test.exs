defmodule Anubis.ProtocolTest do
  use ExUnit.Case, async: true

  alias Anubis.MCP.Error
  alias Anubis.Protocol

  describe "backward compatibility" do
    test "supported_versions/0 returns all versions" do
      versions = Protocol.supported_versions()
      assert "2024-11-05" in versions
      assert "2025-03-26" in versions
      assert "2025-06-18" in versions
    end

    test "latest_version/0 returns latest" do
      assert "2025-06-18" = Protocol.latest_version()
    end

    test "fallback_version/0 returns fallback" do
      assert "2025-03-26" = Protocol.fallback_version()
    end

    test "validate_version/1 accepts supported versions" do
      assert :ok = Protocol.validate_version("2024-11-05")
      assert :ok = Protocol.validate_version("2025-03-26")
      assert :ok = Protocol.validate_version("2025-06-18")
    end

    test "validate_version/1 rejects unsupported versions" do
      assert {:error, %Error{}} = Protocol.validate_version("9999-01-01")
    end

    test "get_features/1 returns features for known version" do
      features = Protocol.get_features("2024-11-05")
      assert is_list(features)
      assert :tools in features
    end

    test "get_features/1 returns empty list for unknown version" do
      assert [] = Protocol.get_features("9999-01-01")
    end

    test "supports_feature?/2 checks feature support" do
      assert Protocol.supports_feature?("2025-06-18", :elicitation)
      refute Protocol.supports_feature?("2024-11-05", :elicitation)
    end

    test "negotiate_version/2 matches client and server" do
      assert {:ok, "2025-03-26"} = Protocol.negotiate_version("2025-03-26", "2025-03-26")
    end

    test "negotiate_version/2 prefers server version" do
      assert {:ok, "2025-06-18"} = Protocol.negotiate_version("2024-11-05", "2025-06-18")
    end

    test "negotiate_version/2 returns error for incompatible" do
      assert {:error, %Error{}} =
               Protocol.negotiate_version("9999-01-01", "8888-01-01")
    end
  end

  describe "get_module/1" do
    test "returns module for known version" do
      assert {:ok, Anubis.Protocol.V2024_11_05} = Protocol.get_module("2024-11-05")
      assert {:ok, Anubis.Protocol.V2025_03_26} = Protocol.get_module("2025-03-26")
      assert {:ok, Anubis.Protocol.V2025_06_18} = Protocol.get_module("2025-06-18")
    end

    test "returns :error for unknown version" do
      assert :error = Protocol.get_module("9999-01-01")
    end
  end
end
