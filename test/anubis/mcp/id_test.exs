defmodule Anubis.MCP.IDTest do
  use ExUnit.Case, async: true

  alias Anubis.MCP.ID

  @moduletag capture_log: true

  doctest ID

  describe "generate/0" do
    test "generates a unique ID" do
      id1 = ID.generate()
      id2 = ID.generate()

      assert is_binary(id1)
      assert is_binary(id2)
      assert id1 != id2
    end

    test "generates a valid Base64 encoded string" do
      id = ID.generate()

      assert {:ok, _decoded} = Base.url_decode64(id)
    end

    test "generated IDs can be validated" do
      id = ID.generate()

      assert ID.valid?(id)
    end
  end

  describe "generate_request_id/0" do
    test "generates an ID with req_ prefix" do
      id = ID.generate_request_id()

      assert is_binary(id)
      assert String.starts_with?(id, "req_")
    end

    test "generates unique request IDs" do
      id1 = ID.generate_request_id()
      id2 = ID.generate_request_id()

      assert id1 != id2
    end

    test "generated request IDs can be validated" do
      id = ID.generate_request_id()

      assert ID.valid_request_id?(id)
    end
  end

  describe "generate_progress_token/0" do
    test "generates a token with progress_ prefix" do
      token = ID.generate_progress_token()

      assert is_binary(token)
      assert String.starts_with?(token, "progress_")
    end

    test "generates unique tokens" do
      token1 = ID.generate_progress_token()
      token2 = ID.generate_progress_token()

      assert token1 != token2
    end

    test "generated progress tokens can be validated" do
      token = ID.generate_progress_token()

      assert ID.valid_progress_token?(token)
    end
  end

  describe "generate_session_id/0" do
    test "generates an ID with session_ prefix" do
      id = ID.generate_session_id()

      assert String.starts_with?(id, "session_")
    end

    test "carries 256 bits of randomness" do
      "session_" <> rest = ID.generate_session_id()

      assert {:ok, bytes} = Base.url_decode64(rest, padding: false)
      assert byte_size(bytes) == 32
    end

    test "carries no timestamp or process component" do
      "session_" <> rest = ID.generate_session_id()

      refute ID.valid?(rest)
      assert is_nil(ID.timestamp_from_id(rest))
    end

    test "stays within the visible ASCII range required for the header" do
      id = ID.generate_session_id()

      assert id |> String.to_charlist() |> Enum.all?(&(&1 >= 0x21 and &1 <= 0x7E))
    end

    test "does not repeat" do
      ids = for _ <- 1..1_000, do: ID.generate_session_id()

      assert length(Enum.uniq(ids)) == 1_000
    end
  end

  describe "timestamp_from_id/1" do
    test "extracts timestamp from a valid ID" do
      id = ID.generate()

      timestamp = ID.timestamp_from_id(id)

      assert is_integer(timestamp)
      assert timestamp <= System.system_time(:nanosecond)
      # Within the last second
      assert timestamp > System.system_time(:nanosecond) - 1_000_000_000
    end

    test "returns nil for invalid IDs" do
      assert ID.timestamp_from_id("invalid-id") == nil
      assert ID.timestamp_from_id("") == nil
    end
  end

  describe "valid?/1" do
    test "returns true for valid IDs" do
      id = ID.generate()

      assert ID.valid?(id)
    end

    test "returns false for invalid IDs" do
      assert ID.valid?("invalid-id") == false
      assert ID.valid?("") == false
      assert ID.valid?(nil) == false
      assert ID.valid?("too-short") == false
    end
  end

  describe "valid_request_id?/1" do
    test "returns true for valid request IDs" do
      id = ID.generate_request_id()

      assert ID.valid_request_id?(id)
    end

    test "returns false for normal IDs" do
      id = ID.generate()

      assert ID.valid_request_id?(id) == false
    end

    test "returns false for progress tokens" do
      token = ID.generate_progress_token()

      assert ID.valid_request_id?(token) == false
    end

    test "returns false for invalid IDs" do
      assert ID.valid_request_id?("req_invalid") == false
      assert ID.valid_request_id?("not-a-request-id") == false
      assert ID.valid_request_id?("") == false
      assert ID.valid_request_id?(nil) == false
    end
  end

  describe "valid_progress_token?/1" do
    test "returns true for valid progress tokens" do
      token = ID.generate_progress_token()

      assert ID.valid_progress_token?(token)
    end

    test "returns false for normal IDs" do
      id = ID.generate()

      assert ID.valid_progress_token?(id) == false
    end

    test "returns false for request IDs" do
      id = ID.generate_request_id()

      assert ID.valid_progress_token?(id) == false
    end

    test "returns false for invalid tokens" do
      assert ID.valid_progress_token?("progress_invalid") == false
      assert ID.valid_progress_token?("not-a-progress-token") == false
      assert ID.valid_progress_token?("") == false
      assert ID.valid_progress_token?(nil) == false
    end
  end
end
