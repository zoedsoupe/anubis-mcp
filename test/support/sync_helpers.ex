defmodule Anubis.Test.SyncHelpers do
  @moduledoc """
  Synchronization helpers that replace fixed `Process.sleep/1` waits in tests.

  Each helper polls synchronously with a tight interval until a predicate is
  satisfied or a deadline expires, so the test resumes within ~5ms of the state
  actually settling instead of paying a fixed 100–300ms upper bound.
  """

  @poll_interval_ms 5

  @doc """
  Polls `:sys.get_state/1` on `server` until `predicate.(state)` is truthy or
  `timeout` ms elapses. Returns the matching state or raises on timeout.
  """
  def await_state(server, predicate, timeout \\ 500) when is_function(predicate, 1) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_state(server, predicate, deadline)
  end

  defp do_await_state(server, predicate, deadline) do
    state = :sys.get_state(server)

    cond do
      predicate.(state) ->
        state

      System.monotonic_time(:millisecond) >= deadline ->
        raise "await_state timed out — last state: #{inspect(state)}"

      true ->
        Process.sleep(@poll_interval_ms)
        do_await_state(server, predicate, deadline)
    end
  end
end
