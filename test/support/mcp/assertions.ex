defmodule Anubis.MCP.Assertions do
  @moduledoc false

  import ExUnit.Assertions, only: [assert: 2]

  def assert_client_initialized(client) when is_pid(client) do
    state = :sys.get_state(client)
    assert state.server_capabilities, "Expected server capabilities to be set"
  end

  def assert_server_initialized(server) when is_pid(server) do
    state = :sys.get_state(server)
    assert state.initialized, "Expected server session to be initialized"
  end
end
