defmodule Anubis.Server.Authorization.OutcomeTest do
  use ExUnit.Case, async: true

  alias Anubis.Server.Authorization

  describe "outcome/1" do
    test "maps authorization layer errors to their own outcome" do
      assert Authorization.outcome(:missing_token) == :missing_token
      assert Authorization.outcome(:invalid_audience) == :invalid_audience
      assert Authorization.outcome(:token_expired) == :token_expired
      assert Authorization.outcome(:invalid_expiry) == :invalid_expiry
    end

    test "maps validator token failures to :invalid_token" do
      assert Authorization.outcome(:invalid_token) == :invalid_token
      assert Authorization.outcome(:invalid_signature) == :invalid_token
      assert Authorization.outcome(:jwt_verification_failed) == :invalid_token
      assert Authorization.outcome(:token_inactive) == :invalid_token
    end

    test "maps issuer failures to :invalid_issuer" do
      assert Authorization.outcome(:invalid_issuer) == :invalid_issuer
    end

    test "maps validator availability failures to :validator_unavailable" do
      assert Authorization.outcome(:invalid_jwks_response) == :validator_unavailable
      assert Authorization.outcome(:invalid_introspection_response) == :validator_unavailable
      assert Authorization.outcome({:jwks_fetch_failed, 503}) == :validator_unavailable
      assert Authorization.outcome({:jwks_request_failed, :nxdomain}) == :validator_unavailable
      assert Authorization.outcome({:introspection_error, 500}) == :validator_unavailable
      assert Authorization.outcome({:introspection_failed, :timeout}) == :validator_unavailable
    end

    test "maps unrecognized reasons to :other without leaking their shape" do
      assert Authorization.outcome("unrecognized failure") == :other
      assert Authorization.outcome({:insufficient_scope, ["tools:write"]}) == :other
      assert Authorization.outcome(%{arbitrary: :data}) == :other
      assert Authorization.outcome(nil) == :other
    end
  end
end
