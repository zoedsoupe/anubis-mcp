defmodule Anubis.Test.MockSessionStore do
  @moduledoc """
  Mock session store for testing persistence functionality.

  Uses an Agent to store sessions in-memory, simulating a real store
  but without external dependencies.
  """

  @behaviour Anubis.Server.Session.Store

  use Agent

  def start_link(_opts) do
    Agent.start_link(fn -> %{sessions: %{}} end, name: __MODULE__)
  end

  def save(session_id, state, _opts) do
    Agent.update(__MODULE__, fn data ->
      %{
        data
        | sessions: Map.put(data.sessions, session_id, state)
      }
    end)

    :ok
  end

  def load(session_id, _opts) do
    Agent.get(__MODULE__, fn data ->
      case Map.get(data.sessions, session_id) do
        nil -> {:error, :not_found}
        state -> {:ok, state}
      end
    end)
  end

  def delete(session_id, _opts) do
    Agent.update(__MODULE__, fn data ->
      %{
        data
        | sessions: Map.delete(data.sessions, session_id)
      }
    end)

    :ok
  end

  def list_active(_opts) do
    sessions = Agent.get(__MODULE__, fn data -> Map.keys(data.sessions) end)
    {:ok, sessions}
  end

  def update_ttl(_session_id, _ttl_seconds, _opts) do
    # Mock doesn't implement TTL
    :ok
  end

  def update(session_id, updates, _opts) do
    Agent.get_and_update(__MODULE__, fn data ->
      case Map.get(data.sessions, session_id) do
        nil ->
          {{:error, :not_found}, data}

        current ->
          updated = Map.merge(current, updates)
          new_data = %{data | sessions: Map.put(data.sessions, session_id, updated)}
          {:ok, new_data}
      end
    end)
  end

  def cleanup_expired(_opts) do
    # Mock doesn't implement expiration
    {:ok, 0}
  end

  # Test helpers

  def reset! do
    if Process.whereis(__MODULE__) do
      Agent.update(__MODULE__, fn _ -> %{sessions: %{}} end)
    end
  end

  def get_all_sessions do
    Agent.get(__MODULE__, & &1.sessions)
  end
end
