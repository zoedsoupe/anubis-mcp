defmodule Anubis.Server.Session.Store.RedisIntegrationTest do
  use ExUnit.Case, async: false

  alias Anubis.Server.Session.Store.Redis

  @moduletag :integration

  @redis_config [
    redis_url: "redis://localhost:6379",
    pool_size: 3,
    # Short TTL for testing (10 seconds in milliseconds)
    ttl: 10_000,
    namespace: "anubis:test",
    connection_name: :test_redis
  ]

  setup_all do
    # Check if Redis is available
    case :gen_tcp.connect(~c"localhost", 6379, [], 5000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :ok

      {:error, _} ->
        IO.puts("\nSkipping Redis integration tests - Redis not available at localhost:6379")
        :skip
    end
  end

  setup do
    # Configure application to use test Redis config
    Application.put_env(:anubis_mcp, :session_store, @redis_config)

    # Clean up any existing test keys
    case Redix.start_link("redis://localhost:6379") do
      {:ok, conn} ->
        Redix.command(conn, ["FLUSHDB"])
        Redix.stop(conn)
        :ok

      {:error, _} ->
        :skip
    end
  end

  describe "Redis store integration" do
    test "starts and stops correctly" do
      {:ok, pid} = Redis.start_link(@redis_config)
      assert Process.alive?(pid)

      GenServer.stop(pid)
      refute Process.alive?(pid)
    end

    test "saves and loads session data" do
      {:ok, _pid} = Redis.start_link(@redis_config)

      session_id = "test_session_123"

      session_data = %{
        id: session_id,
        initialized: true,
        protocol_version: "2024-11-21",
        client_info: %{"name" => "test_client"}
      }

      # Save session
      assert :ok = Redis.save(session_id, session_data)

      # Load session
      assert {:ok, loaded_data} = Redis.load(session_id)
      assert loaded_data["id"] == session_id
      assert loaded_data["initialized"] == true
      assert loaded_data["protocol_version"] == "2024-11-21"
      assert loaded_data["client_info"]["name"] == "test_client"
    end

    test "handles non-existent sessions" do
      {:ok, _pid} = Redis.start_link(@redis_config)

      assert {:error, :not_found} = Redis.load("nonexistent_session")
    end

    test "deletes sessions" do
      {:ok, _pid} = Redis.start_link(@redis_config)

      session_id = "delete_test_456"
      session_data = %{id: session_id}

      # Save and verify
      :ok = Redis.save(session_id, session_data)
      assert {:ok, _} = Redis.load(session_id)

      # Delete and verify
      :ok = Redis.delete(session_id)
      assert {:error, :not_found} = Redis.load(session_id)
    end

    test "lists active sessions" do
      {:ok, _pid} = Redis.start_link(@redis_config)

      session_ids = ["active_1", "active_2", "active_3"]

      # Save multiple sessions
      for session_id <- session_ids do
        :ok = Redis.save(session_id, %{id: session_id})
      end

      # List active sessions
      {:ok, active} = Redis.list_active([])
      assert length(active) == 3
      assert Enum.all?(session_ids, &(&1 in active))
    end

    test "updates session data atomically" do
      {:ok, _pid} = Redis.start_link(@redis_config)

      session_id = "update_test_789"

      initial_data = %{
        id: session_id,
        log_level: "info",
        initialized: false
      }

      # Save initial data
      :ok = Redis.save(session_id, initial_data)

      # Update some fields
      updates = %{
        log_level: "debug",
        initialized: true
      }

      :ok = Redis.update(session_id, updates)

      # Verify updates
      {:ok, updated_data} = Redis.load(session_id)
      assert updated_data["log_level"] == "debug"
      assert updated_data["initialized"] == true
      # Unchanged field
      assert updated_data["id"] == session_id
    end

    test "handles TTL correctly" do
      {:ok, _pid} = Redis.start_link(@redis_config)

      session_id = "ttl_test_999"
      session_data = %{id: session_id}

      # Save with short TTL (1 second in milliseconds)
      :ok = Redis.save(session_id, session_data, ttl: 1000)

      # Should exist immediately
      assert {:ok, _} = Redis.load(session_id)

      # Wait for expiration (2 seconds to be safe)
      Process.sleep(2000)

      # Should be expired
      assert {:error, :not_found} = Redis.load(session_id)
    end

    test "handles connection pool correctly" do
      config = Keyword.put(@redis_config, :pool_size, 5)
      {:ok, _pid} = Redis.start_link(config)

      # Make multiple concurrent operations
      tasks =
        for i <- 1..20 do
          Task.async(fn ->
            session_id = "concurrent_#{i}"
            :ok = Redis.save(session_id, %{id: session_id})
            {:ok, data} = Redis.load(session_id)
            assert data["id"] == session_id
            :ok = Redis.delete(session_id)
          end)
        end

      # All should complete successfully
      Enum.each(tasks, &Task.await/1)
    end

    test "updates TTL for existing sessions" do
      {:ok, _pid} = Redis.start_link(@redis_config)

      session_id = "ttl_update_test"
      :ok = Redis.save(session_id, %{id: session_id})

      # Update TTL (1 hour in milliseconds)
      :ok = Redis.update_ttl(session_id, 3_600_000)

      # Session should still exist
      assert {:ok, _} = Redis.load(session_id)
    end

    test "cleanup_expired is a no-op for Redis" do
      {:ok, _pid} = Redis.start_link(@redis_config)

      # Redis handles expiration automatically
      assert {:ok, 0} = Redis.cleanup_expired([])
    end
  end

  describe "Redis connection failures" do
    test "handles Redis connection errors gracefully" do
      bad_config = Keyword.put(@redis_config, :redis_url, "redis://nonexistent:9999")

      # Redis starts with sync_connect: false, so it won't fail immediately
      # Instead, operations will fail when the connection isn't available
      {:ok, pid} = Redis.start_link(bad_config)

      # Wait a moment for connection attempt
      Process.sleep(100)

      # Operations should fail due to connection errors
      assert {:error, _reason} = Redis.save("test", %{id: "test"})

      GenServer.stop(pid)
    end
  end
end
