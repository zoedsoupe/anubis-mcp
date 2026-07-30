defmodule Anubis.Protocol.VersionModulesTest do
  use ExUnit.Case, async: true

  alias Anubis.Protocol.V2025_03_26
  alias Anubis.Protocol.V2025_06_18
  alias Anubis.Protocol.V2025_11_25

  describe "V2025_03_26" do
    test "version/0 returns correct string" do
      assert "2025-03-26" = V2025_03_26.version()
    end

    test "supported_features/0 includes base features" do
      features = V2025_03_26.supported_features()
      assert :basic_messaging in features
      assert :resources in features
      assert :tools in features
      assert :prompts in features
      assert :logging in features
      assert :progress in features
      assert :cancellation in features
      assert :ping in features
      assert :roots in features
      assert :sampling in features
    end

    test "supported_features/0 includes base + new features" do
      features = V2025_03_26.supported_features()
      assert :authorization in features
      assert :audio_content in features
      assert :tool_annotations in features
      assert :progress_messages in features
      assert :completion_capability in features
    end

    test "supported_features/0 does not include 2025-06-18 features" do
      features = V2025_03_26.supported_features()
      refute :elicitation in features
      refute :structured_tool_results in features
    end

    test "request_methods/0 includes standard methods" do
      methods = V2025_03_26.request_methods()
      assert "initialize" in methods
      assert "ping" in methods
      assert "tools/list" in methods
      assert "tools/call" in methods
      assert "resources/list" in methods
      assert "resources/read" in methods
      assert "prompts/list" in methods
      assert "prompts/get" in methods
      assert "sampling/createMessage" in methods
    end

    test "request_params_schema/1 returns valid schema for initialize" do
      schema = V2025_03_26.request_params_schema("initialize")
      assert is_map(schema)
      assert Map.has_key?(schema, "protocolVersion")
      assert Map.has_key?(schema, "clientInfo")
    end

    test "request_params_schema/1 returns :map for ping" do
      assert :map = V2025_03_26.request_params_schema("ping")
    end

    test "request_params_schema/1 returns schema for tools/call" do
      schema = V2025_03_26.request_params_schema("tools/call")
      assert is_map(schema)
      assert Map.has_key?(schema, "name")
    end

    test "request_params_schema/1 for sampling includes audio and model preferences" do
      schema = V2025_03_26.request_params_schema("sampling/createMessage")
      assert is_map(schema)
      assert Map.has_key?(schema, "modelPreferences")
      assert Map.has_key?(schema, "messages")
    end

    test "request_params_schema/1 returns :map for unknown method" do
      assert :map = V2025_03_26.request_params_schema("unknown/method")
    end

    test "progress_params_schema/0 includes message field" do
      schema = V2025_03_26.progress_params_schema()
      assert Map.has_key?(schema, "progressToken")
      assert Map.has_key?(schema, "progress")
      assert Map.has_key?(schema, "message")
    end

    test "notification_methods/0 includes standard notifications" do
      methods = V2025_03_26.notification_methods()
      assert "notifications/initialized" in methods
      assert "notifications/cancelled" in methods
      assert "notifications/progress" in methods
    end

    test "notification_params_schema/1 returns schema for cancelled" do
      schema = V2025_03_26.notification_params_schema("notifications/cancelled")
      assert is_map(schema)
      assert Map.has_key?(schema, "requestId")
    end

    test "notification_params_schema/1 for progress includes message" do
      schema = V2025_03_26.notification_params_schema("notifications/progress")
      assert Map.has_key?(schema, "message")
    end
  end

  describe "V2025_06_18" do
    test "version/0 returns correct string" do
      assert "2025-06-18" = V2025_06_18.version()
    end

    test "supported_features/0 includes all features" do
      features = V2025_06_18.supported_features()
      assert :basic_messaging in features
      assert :authorization in features
      assert :elicitation in features
      assert :structured_tool_results in features
      assert :tool_output_schemas in features
      assert :model_preferences in features
      assert :embedded_resources_in_prompts in features
      assert :embedded_resources_in_tools in features
    end

    test "delegates request_params_schema to V2025_03_26" do
      assert V2025_06_18.request_params_schema("tools/call") ==
               V2025_03_26.request_params_schema("tools/call")
    end

    test "delegates progress_params_schema to V2025_03_26" do
      assert V2025_06_18.progress_params_schema() == V2025_03_26.progress_params_schema()
    end

    test "delegates notification_params_schema to V2025_03_26" do
      assert V2025_06_18.notification_params_schema("notifications/cancelled") ==
               V2025_03_26.notification_params_schema("notifications/cancelled")
    end
  end

  describe "version feature inheritance" do
    test "each version is a superset of the previous" do
      v1_features = MapSet.new(V2025_03_26.supported_features())
      v2_features = MapSet.new(V2025_06_18.supported_features())
      v3_features = MapSet.new(V2025_11_25.supported_features())

      assert MapSet.subset?(v1_features, v2_features)
      assert MapSet.subset?(v2_features, v3_features)
    end
  end

  describe "behaviour compliance" do
    for mod <- [V2025_03_26, V2025_06_18, V2025_11_25] do
      test "#{mod} implements all callbacks" do
        mod = unquote(mod)
        assert mod.era() in [:legacy, :stateless]
        assert is_binary(mod.version())
        assert is_list(mod.supported_features())
        assert is_boolean(mod.supports_feature?(:ping))
        assert %{batching: batching?, protocol_version_header: header?} = mod.transport_rules()
        assert is_boolean(batching?)
        assert is_boolean(header?)
        assert is_map(mod.server_capabilities(%{"tools" => %{}}))
        assert is_list(mod.request_methods())
        assert is_list(mod.notification_methods())
        assert is_map(mod.progress_params_schema())
        assert "initialize" |> mod.request_params_schema() |> is_map()
        assert mod.notification_params_schema("notifications/initialized") == :map
        assert {:multi, :method, _} = mod.request_message_schema()
        assert {:multi, :method, _} = mod.notification_message_schema()
      end
    end
  end
end
