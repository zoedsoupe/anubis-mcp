defmodule Anubis.ApplicationTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Anubis.Test.MockSessionStore

  test "does not log warning when session store is disabled" do
    config = [enabled: false, adapter: MockSessionStore]

    log =
      capture_log(fn ->
        assert [] == Anubis.Application.session_store_children(config)
      end)

    refute log =~ "Session store enabled but adapter not available"
    refute log =~ "Session store enabled but adapter not configured"
  end

  test "logs warning when session store is enabled but adapter is nil" do
    config = [enabled: true]

    log =
      capture_log(fn ->
        assert [] == Anubis.Application.session_store_children(config)
      end)

    assert log =~ "Session store enabled but adapter not configured"
  end

  test "logs warning when session store is enabled but adapter is unavailable" do
    config = [enabled: true, adapter: NonExisting.Adapter]

    log =
      capture_log(fn ->
        assert [] == Anubis.Application.session_store_children(config)
      end)

    assert log =~ "Session store enabled but adapter not available"
  end

  test "returns child spec when session store is enabled and adapter is available" do
    config = [enabled: true, adapter: MockSessionStore, ttl: 1_800_000, namespace: "anubis:sessions"]

    log =
      capture_log(fn ->
        assert [{MockSessionStore, config}] == Anubis.Application.session_store_children(config)
      end)

    assert log =~ "Starting session store"
    refute log =~ "Session store enabled but adapter not available"
  end
end
