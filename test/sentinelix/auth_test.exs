defmodule Sentinelix.AuthTest do
  use ExUnit.Case, async: false

  import Sentinelix.Test.AuthHelpers

  alias Sentinelix.Auth

  test "OIDC is disabled without issuer and client id" do
    put_app_env(:oidc, issuer: "https://idp.example.com")

    refute Auth.oidc_enabled?()
    assert Auth.oidc_config() == nil
    assert Auth.provider_name() == nil
  end

  test "OIDC config defaults" do
    put_app_env(:oidc, issuer: "https://idp.example.com", client_id: "abc")

    assert %{
             issuer: "https://idp.example.com",
             client_id: "abc",
             client_secret: :unauthenticated,
             scopes: ["openid", "profile", "email"],
             provider_name: "SSO",
             groups_claim: "groups",
             allowed_groups: [],
             allowed_emails: [],
             allowed_domains: [],
             allow_insecure_http: false
           } = Auth.oidc_config()
  end

  describe "local_auth_enabled?/0" do
    test "defaults to true without OIDC" do
      put_app_env(:oidc, [])
      put_app_env(:local_auth_enabled, nil)

      assert Auth.local_auth_enabled?()
    end

    test "defaults to false with OIDC" do
      put_app_env(:oidc, issuer: "https://idp.example.com", client_id: "abc")
      put_app_env(:local_auth_enabled, nil)

      refute Auth.local_auth_enabled?()
    end

    test "can be set explicitly" do
      put_app_env(:oidc, issuer: "https://idp.example.com", client_id: "abc")
      put_app_env(:local_auth_enabled, true)
      assert Auth.local_auth_enabled?()

      put_app_env(:oidc, [])
      put_app_env(:local_auth_enabled, false)
      refute Auth.local_auth_enabled?()
    end
  end
end
