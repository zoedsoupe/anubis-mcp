defmodule Anubis.Protocol.RegistryTest do
  use ExUnit.Case, async: true

  alias Anubis.Protocol.Registry
  alias Anubis.Protocol.V2025_03_26
  alias Anubis.Protocol.V2025_06_18
  alias Anubis.Protocol.V2025_11_25

  describe "get/1" do
    test "returns module for known version" do
      assert {:ok, V2025_03_26} = Registry.get("2025-03-26")
      assert {:ok, V2025_06_18} = Registry.get("2025-06-18")
      assert {:ok, V2025_11_25} = Registry.get("2025-11-25")
    end

    test "returns :error for unknown version" do
      assert :error = Registry.get("9999-01-01")
      assert :error = Registry.get("")
    end

    test "returns :error for dropped versions" do
      assert :error = Registry.get("2024-11-05")
    end
  end

  describe "supported_versions/0" do
    test "returns all versions newest first" do
      versions = Registry.supported_versions()
      assert is_list(versions)
      assert length(versions) == 4
      assert hd(versions) == "2026-07-28"
      assert "2025-11-25" in versions
      assert "2025-06-18" in versions
      assert "2025-03-26" in versions
      refute "2024-11-05" in versions
    end
  end

  describe "versions_for_era/1" do
    test "groups every registered version into exactly one era" do
      legacy = Registry.versions_for_era(:legacy)
      stateless = Registry.versions_for_era(:stateless)

      assert Enum.sort(legacy ++ stateless) == Enum.sort(Registry.supported_versions())
      assert legacy -- stateless == legacy
    end

    test "the handshake versions are legacy and 2026-07-28 is stateless" do
      assert Registry.legacy_versions() == ["2025-11-25", "2025-06-18", "2025-03-26"]
      assert Registry.stateless_versions() == ["2026-07-28"]
    end

    test "each era is ordered newest first" do
      for era <- [:legacy, :stateless] do
        versions = Registry.versions_for_era(era)
        assert versions == Enum.sort(versions, :desc)
      end
    end
  end

  describe "era/1" do
    test "reports the era of a registered version" do
      assert {:ok, :legacy} = Registry.era("2025-11-25")
      assert {:ok, :stateless} = Registry.era("2026-07-28")
    end

    test "returns :error for unknown version" do
      assert :error = Registry.era("9999-01-01")
    end
  end

  describe "latest_version/0" do
    test "returns the latest handshake-negotiable version" do
      assert "2025-11-25" = Registry.latest_version()
      assert Registry.latest_version() == Registry.latest_version(:legacy)
      assert {:ok, :legacy} = Registry.era(Registry.latest_version())
    end
  end

  describe "latest_version/1" do
    test "returns the newest version of an era" do
      assert "2025-11-25" = Registry.latest_version(:legacy)
      assert "2026-07-28" = Registry.latest_version(:stateless)
    end
  end

  describe "fallback_version/0" do
    test "returns the fallback version" do
      assert "2025-03-26" = Registry.fallback_version()
    end
  end

  describe "latest_module/0" do
    test "returns the module for the latest version" do
      assert V2025_11_25 = Registry.latest_module()
    end
  end

  describe "supported?/1" do
    test "returns true for supported versions" do
      assert Registry.supported?("2025-03-26")
      assert Registry.supported?("2025-06-18")
      assert Registry.supported?("2025-11-25")
    end

    test "returns false for unsupported versions" do
      refute Registry.supported?("9999-01-01")
      refute Registry.supported?("")
    end

    test "returns false for dropped versions" do
      refute Registry.supported?("2024-11-05")
    end
  end

  describe "negotiate/1" do
    test "returns module for supported client version" do
      assert {:ok, "2025-11-25", V2025_11_25} = Registry.negotiate("2025-11-25")
      assert {:ok, "2025-06-18", V2025_06_18} = Registry.negotiate("2025-06-18")
      assert {:ok, "2025-03-26", V2025_03_26} = Registry.negotiate("2025-03-26")
    end

    test "returns error for unsupported client version" do
      assert {:error, :unsupported_version, versions} = Registry.negotiate("9999-01-01")
      assert versions == Registry.legacy_versions()
    end

    test "returns error for dropped client version" do
      assert {:error, :unsupported_version, _} = Registry.negotiate("2024-11-05")
    end

    test "treats a stateless version as unsupported by the handshake" do
      assert {:error, :unsupported_version, versions} = Registry.negotiate("2026-07-28")
      refute "2026-07-28" in versions
    end
  end

  describe "negotiate/2" do
    test "prefers client version when in server list" do
      assert {:ok, "2025-03-26", V2025_03_26} =
               Registry.negotiate("2025-03-26", ["2025-06-18", "2025-03-26"])
    end

    test "falls back to server latest when client version not in server list" do
      assert {:ok, "2025-06-18", V2025_06_18} =
               Registry.negotiate("2024-11-05", ["2025-06-18", "2025-03-26"])
    end

    test "falls back to the newest server version regardless of list order" do
      for server_versions <- [
            ["2024-11-05", "2025-11-25"],
            ["2025-11-25", "2024-11-05"],
            ["2025-03-26", "2025-11-25", "2024-11-05"]
          ] do
        assert {:ok, "2025-11-25", V2025_11_25} = Registry.negotiate("9999-01-01", server_versions)
      end
    end

    test "returns client version when it matches server's only version" do
      assert {:ok, "2025-03-26", V2025_03_26} =
               Registry.negotiate("2025-03-26", ["2025-03-26"])
    end

    test "never resolves to a stateless version" do
      for client_version <- ["2026-07-28", "2025-11-25", "9999-01-01"] do
        refute match?({:ok, "2026-07-28", _}, Registry.negotiate(client_version, Registry.supported_versions()))
      end
    end

    test "an unknown client version never falls back into the stateless era" do
      assert {:ok, version, module} = Registry.negotiate("9999-01-01", Registry.supported_versions())

      assert version == "2025-11-25"
      assert module.era() == :legacy
    end

    test "ignores stateless and unregistered entries in the server list" do
      assert {:ok, "2025-03-26", V2025_03_26} =
               Registry.negotiate("2025-03-26", ["2026-07-28", "9999-01-01", "2025-03-26"])
    end

    test "returns :error when the server list offers no legacy version" do
      assert :error = Registry.negotiate("2026-07-28", ["2026-07-28"])
      assert :error = Registry.negotiate("2025-03-26", ["9999-01-01"])
      assert :error = Registry.negotiate("2025-03-26", [])
    end
  end

  describe "get_features/1" do
    test "returns features for known version" do
      assert {:ok, features} = Registry.get_features("2025-03-26")
      assert :basic_messaging in features
      assert :tools in features
      assert :resources in features
    end

    test "returns :error for unknown version" do
      assert :error = Registry.get_features("9999-01-01")
    end
  end

  describe "supports_feature?/2" do
    test "returns true for supported features" do
      assert Registry.supports_feature?("2025-03-26", :tools)
      assert Registry.supports_feature?("2025-03-26", :authorization)
      assert Registry.supports_feature?("2025-06-18", :elicitation)
    end

    test "returns false for unsupported features" do
      refute Registry.supports_feature?("2025-03-26", :elicitation)
      refute Registry.supports_feature?("2025-06-18", :tasks)
    end

    test "returns false for unknown version" do
      refute Registry.supports_feature?("9999-01-01", :tools)
      refute Registry.supports_feature?("2024-11-05", :tools)
    end
  end

  describe "progress_params_schema/1" do
    test "2025-03-26 includes message field" do
      assert {:ok, schema} = Registry.progress_params_schema("2025-03-26")
      assert is_map(schema)
      assert Map.has_key?(schema, "progressToken")
      assert Map.has_key?(schema, "progress")
      assert Map.has_key?(schema, "message")
    end

    test "2025-06-18 inherits message field from 2025-03-26" do
      assert {:ok, schema} = Registry.progress_params_schema("2025-06-18")
      assert Map.has_key?(schema, "message")
    end

    test "returns :error for unknown version" do
      assert :error = Registry.progress_params_schema("9999-01-01")
      assert :error = Registry.progress_params_schema("2024-11-05")
    end
  end
end
