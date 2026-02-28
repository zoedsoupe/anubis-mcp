defmodule Anubis.Protocol.RegistryTest do
  use ExUnit.Case, async: true

  alias Anubis.Protocol.Registry
  alias Anubis.Protocol.V2024_11_05
  alias Anubis.Protocol.V2025_03_26
  alias Anubis.Protocol.V2025_06_18

  describe "get/1" do
    test "returns module for known version" do
      assert {:ok, V2024_11_05} = Registry.get("2024-11-05")
      assert {:ok, V2025_03_26} = Registry.get("2025-03-26")
      assert {:ok, V2025_06_18} = Registry.get("2025-06-18")
    end

    test "returns :error for unknown version" do
      assert :error = Registry.get("9999-01-01")
      assert :error = Registry.get("")
    end
  end

  describe "supported_versions/0" do
    test "returns all versions newest first" do
      versions = Registry.supported_versions()
      assert is_list(versions)
      assert length(versions) == 3
      assert hd(versions) == "2025-06-18"
      assert "2025-03-26" in versions
      assert "2024-11-05" in versions
    end
  end

  describe "latest_version/0" do
    test "returns the latest version" do
      assert "2025-06-18" = Registry.latest_version()
    end
  end

  describe "fallback_version/0" do
    test "returns the fallback version" do
      assert "2025-03-26" = Registry.fallback_version()
    end
  end

  describe "latest_module/0" do
    test "returns the module for the latest version" do
      assert V2025_06_18 = Registry.latest_module()
    end
  end

  describe "supported?/1" do
    test "returns true for supported versions" do
      assert Registry.supported?("2024-11-05")
      assert Registry.supported?("2025-03-26")
      assert Registry.supported?("2025-06-18")
    end

    test "returns false for unsupported versions" do
      refute Registry.supported?("9999-01-01")
      refute Registry.supported?("")
    end
  end

  describe "negotiate/1" do
    test "returns module for supported client version" do
      assert {:ok, "2025-06-18", V2025_06_18} = Registry.negotiate("2025-06-18")
      assert {:ok, "2025-03-26", V2025_03_26} = Registry.negotiate("2025-03-26")
      assert {:ok, "2024-11-05", V2024_11_05} = Registry.negotiate("2024-11-05")
    end

    test "returns error for unsupported client version" do
      assert {:error, :unsupported_version, versions} = Registry.negotiate("9999-01-01")
      assert is_list(versions)
      assert length(versions) == 3
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

    test "returns client version when it matches server's only version" do
      assert {:ok, "2025-03-26", V2025_03_26} =
               Registry.negotiate("2025-03-26", ["2025-03-26"])
    end
  end

  describe "get_features/1" do
    test "returns features for known version" do
      assert {:ok, features} = Registry.get_features("2024-11-05")
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
      assert Registry.supports_feature?("2024-11-05", :tools)
      assert Registry.supports_feature?("2025-03-26", :authorization)
      assert Registry.supports_feature?("2025-06-18", :elicitation)
    end

    test "returns false for unsupported features" do
      refute Registry.supports_feature?("2024-11-05", :authorization)
      refute Registry.supports_feature?("2024-11-05", :elicitation)
      refute Registry.supports_feature?("2025-03-26", :elicitation)
    end

    test "returns false for unknown version" do
      refute Registry.supports_feature?("9999-01-01", :tools)
    end
  end

  describe "progress_params_schema/1" do
    test "2024-11-05 does not include message field" do
      assert {:ok, schema} = Registry.progress_params_schema("2024-11-05")
      assert is_map(schema)
      assert Map.has_key?(schema, "progressToken")
      assert Map.has_key?(schema, "progress")
      refute Map.has_key?(schema, "message")
    end

    test "2025-03-26 includes message field" do
      assert {:ok, schema} = Registry.progress_params_schema("2025-03-26")
      assert Map.has_key?(schema, "message")
    end

    test "2025-06-18 inherits message field from 2025-03-26" do
      assert {:ok, schema} = Registry.progress_params_schema("2025-06-18")
      assert Map.has_key?(schema, "message")
    end

    test "returns :error for unknown version" do
      assert :error = Registry.progress_params_schema("9999-01-01")
    end
  end
end
