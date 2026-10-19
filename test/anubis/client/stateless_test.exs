defmodule Anubis.Client.StatelessTest do
  use ExUnit.Case, async: true

  alias Anubis.Client.Stateless
  alias Anubis.Protocol.Schema

  doctest Stateless

  describe "request_meta/3" do
    test "includes the protocol version and the capabilities verbatim" do
      meta =
        Stateless.request_meta("2026-07-28", %{"roots" => %{"listChanged" => true}}, %{"name" => "c", "version" => "1"})

      assert meta[Schema.protocol_version_key()] == "2026-07-28"
      assert meta[Schema.client_capabilities_key()] == %{"roots" => %{"listChanged" => true}}
    end

    test "includes clientInfo only when name and version are both binaries" do
      complete = Stateless.request_meta("2026-07-28", %{}, %{"name" => "c", "version" => "1"})
      assert complete[Schema.client_info_key()] == %{"name" => "c", "version" => "1"}

      no_version = Stateless.request_meta("2026-07-28", %{}, %{"name" => "c"})
      refute Map.has_key?(no_version, Schema.client_info_key())

      non_binary = Stateless.request_meta("2026-07-28", %{}, %{"name" => "c", "version" => 1})
      refute Map.has_key?(non_binary, Schema.client_info_key())
    end
  end

  describe "build_params/3" do
    setup do
      %{meta: Stateless.request_meta("2026-07-28", %{"roots" => %{}}, %{"name" => "c", "version" => "1"})}
    end

    test "puts _meta into the params", %{meta: meta} do
      params = Stateless.build_params(meta, %{"cursor" => "a"}, nil)

      assert params["cursor"] == "a"
      assert params["_meta"] == meta
    end

    test "merges the progress token under the same _meta", %{meta: meta} do
      for token <- ["t1", 42] do
        params = Stateless.build_params(meta, %{}, token: token)
        assert params["_meta"] == Map.put(meta, "progressToken", token)
      end
    end

    test "ignores progress opts without a usable token", %{meta: meta} do
      assert Stateless.build_params(meta, %{}, callback: fn _, _, _ -> :ok end)["_meta"] == meta
      assert Stateless.build_params(meta, %{}, [])["_meta"] == meta
    end

    test "overwrites a user _meta key", %{meta: meta} do
      params = Stateless.build_params(meta, %{"_meta" => %{"progressToken" => "old"}}, nil)

      assert params["_meta"] == meta
    end
  end

  describe "probe_version/1" do
    test "prefers a configured stateless version" do
      assert Stateless.probe_version("2026-07-28") == "2026-07-28"
    end

    test "falls back to the newest registered stateless version" do
      assert Stateless.probe_version("2025-11-25") == "2026-07-28"
      assert Stateless.probe_version("not-a-version") == "2026-07-28"
    end
  end

  describe "legacy_proposal/1" do
    test "passes a configured legacy version through" do
      assert Stateless.legacy_proposal("2025-06-18") == "2025-06-18"
    end

    test "maps a stateless version to the newest legacy version" do
      assert Stateless.legacy_proposal("2026-07-28") == "2025-11-25"
      assert Stateless.legacy_proposal("not-a-version") == "2025-11-25"
    end
  end

  describe "classify_probe_result/1" do
    test "accepts a well-formed discover result" do
      server_info = %{"name" => "s", "version" => "1"}

      result = %{
        "supportedVersions" => ["2026-07-28"],
        "capabilities" => %{"tools" => %{}},
        "_meta" => %{"io.modelcontextprotocol/serverInfo" => server_info}
      }

      assert Stateless.classify_probe_result(result) == {:stateless, ["2026-07-28"], %{"tools" => %{}}, server_info}
    end

    test "returns nil server_info without _meta" do
      result = %{"supportedVersions" => ["2026-07-28"], "capabilities" => %{}}
      assert Stateless.classify_probe_result(result) == {:stateless, ["2026-07-28"], %{}, nil}
    end

    test "falls back on a missing supportedVersions" do
      assert Stateless.classify_probe_result(%{"capabilities" => %{}}) == :fallback
    end

    test "falls back on a non-list supportedVersions" do
      assert Stateless.classify_probe_result(%{"supportedVersions" => "2026-07-28", "capabilities" => %{}}) == :fallback
    end

    test "falls back on a non-binary version entry" do
      assert Stateless.classify_probe_result(%{"supportedVersions" => [:v2026], "capabilities" => %{}}) == :fallback
    end

    test "falls back on missing or non-map capabilities" do
      refute match?({:stateless, _, _, _}, Stateless.classify_probe_result(%{"supportedVersions" => ["2026-07-28"]}))

      refute match?(
               {:stateless, _, _, _},
               Stateless.classify_probe_result(%{"supportedVersions" => ["2026-07-28"], "capabilities" => [:tools]})
             )
    end

    test "falls back on any non-map input" do
      assert Stateless.classify_probe_result(nil) == :fallback
      assert Stateless.classify_probe_result("ok") == :fallback
      assert Stateless.classify_probe_result([]) == :fallback
    end
  end

  describe "classify_probe_error/1" do
    test "retries a -32022 carrying supported versions" do
      error = %{"code" => -32_022, "message" => "Unsupported", "data" => %{"supported" => ["2026-07-28"]}}
      assert Stateless.classify_probe_error(error) == {:retry, ["2026-07-28"]}
    end

    test "falls back on a -32022 without data" do
      assert Stateless.classify_probe_error(%{"code" => -32_022, "message" => "Unsupported"}) == :fallback
    end

    test "falls back on a -32022 with non-binary supported entries" do
      error = %{"code" => -32_022, "data" => %{"supported" => [1]}}
      assert Stateless.classify_probe_error(error) == :fallback
    end

    test "falls back on other JSON-RPC errors" do
      assert Stateless.classify_probe_error(%{"code" => -32_601, "message" => "Method not found"}) == :fallback
    end

    test "falls back on non-map input" do
      assert Stateless.classify_probe_error("error") == :fallback
      assert Stateless.classify_probe_error(nil) == :fallback
    end
  end

  describe "negotiate/2" do
    test "prefers the probe version when the server serves it" do
      assert Stateless.negotiate("2026-07-28", ["2026-07-28"]) == {:ok, "2026-07-28"}
    end

    test "picks the newest version of the intersection" do
      assert Stateless.negotiate(nil, ["2026-07-28"]) == {:ok, "2026-07-28"}
      assert Stateless.negotiate("2026-07-28", ["9999-01-01", "2026-07-28"]) == {:ok, "2026-07-28"}
    end

    test "errors on an empty intersection" do
      assert Stateless.negotiate("2026-07-28", ["2025-11-25"]) == :error
    end

    test "errors on empty input" do
      assert Stateless.negotiate(nil, []) == :error
    end

    test "errors on a non-list supported" do
      assert Stateless.negotiate("2026-07-28", nil) == :error
    end
  end

  describe "validate_method/2" do
    @removed ~w(ping logging/setLevel resources/subscribe resources/unsubscribe)

    test "refuses the removed methods only in the stateless era" do
      for method <- @removed do
        assert {:error, error} = Stateless.validate_method(:stateless, method)
        assert error.reason == :method_not_found
        assert error.data.method == method
        assert error.data.era == :stateless
      end
    end

    test "allows every method in the other eras" do
      for method <- @removed, era <- [:legacy, :detecting, :connecting] do
        assert Stateless.validate_method(era, method) == :ok
      end
    end

    test "allows any other method in the stateless era" do
      assert Stateless.validate_method(:stateless, "tools/list") == :ok
      assert Stateless.validate_method(:stateless, "server/discover") == :ok
    end
  end
end
