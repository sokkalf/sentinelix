defmodule Sentinelix.Auth.PolicyTest do
  use ExUnit.Case, async: true

  alias Sentinelix.Auth.Policy

  @claims %{"sub" => "1", "email" => "Alice@Example.com", "groups" => ["staff", "ops"]}

  test "allows everybody when no allow-list is configured" do
    assert Policy.authorize(@claims, %{}) == :ok
    assert Policy.authorize(%{"sub" => "1"}, %{allowed_groups: [], allowed_emails: []}) == :ok
  end

  describe "groups" do
    test "matches any configured group" do
      assert Policy.authorize(@claims, %{allowed_groups: ["admins", "ops"]}) == :ok
      assert Policy.authorize(@claims, %{allowed_groups: ["admins"]}) == {:error, :not_allowed}
    end

    test "denies users without the groups claim" do
      assert Policy.authorize(%{"sub" => "1"}, %{allowed_groups: ["ops"]}) ==
               {:error, :not_allowed}
    end

    test "uses the configured claim" do
      claims = %{"sub" => "1", "roles" => ["ops"]}
      config = %{allowed_groups: ["ops"], groups_claim: "roles"}

      assert Policy.authorize(claims, config) == :ok
      assert Policy.authorize(claims, %{allowed_groups: ["ops"]}) == {:error, :not_allowed}
    end

    test "supports string, map and nested claims" do
      assert Policy.groups(%{"groups" => "ops"}, "groups") == ["ops"]
      assert Policy.groups(%{"roles" => %{"ops" => %{"x" => "y"}}}, "roles") == ["ops"]

      assert Policy.groups(%{"realm_access" => %{"roles" => ["ops"]}}, "realm_access.roles") ==
               ["ops"]

      assert Policy.groups(%{"a.b" => ["literal"]}, "a.b") == ["literal"]
      assert Policy.groups(%{"groups" => 42}, "groups") == []
    end
  end

  describe "emails and domains" do
    test "matches emails case-insensitively" do
      assert Policy.authorize(@claims, %{allowed_emails: ["alice@example.com"]}) == :ok

      assert Policy.authorize(@claims, %{allowed_emails: ["bob@example.com"]}) ==
               {:error, :not_allowed}
    end

    test "matches domains" do
      assert Policy.authorize(@claims, %{allowed_domains: ["EXAMPLE.com"]}) == :ok
      assert Policy.authorize(@claims, %{allowed_domains: ["@example.com"]}) == :ok

      assert Policy.authorize(@claims, %{allowed_domains: ["example.org"]}) ==
               {:error, :not_allowed}

      # no suffix matching
      assert Policy.authorize(@claims, %{allowed_domains: ["ample.com"]}) ==
               {:error, :not_allowed}
    end

    test "ignores unverified emails" do
      claims = Map.put(@claims, "email_verified", false)

      assert Policy.authorize(claims, %{allowed_emails: ["alice@example.com"]}) ==
               {:error, :not_allowed}

      assert Policy.authorize(claims, %{allowed_domains: ["example.com"]}) ==
               {:error, :not_allowed}
    end

    test "denies users without email" do
      assert Policy.authorize(%{"sub" => "1"}, %{allowed_domains: ["example.com"]}) ==
               {:error, :not_allowed}
    end
  end

  test "any matching rule allows the user" do
    config = %{allowed_groups: ["admins"], allowed_domains: ["example.com"]}
    assert Policy.authorize(@claims, config) == :ok

    config = %{allowed_groups: ["ops"], allowed_domains: ["example.org"]}
    assert Policy.authorize(@claims, config) == :ok
  end
end
