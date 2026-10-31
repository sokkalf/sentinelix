defmodule SentinelixWeb.OIDCControllerTest do
  use SentinelixWeb.ConnCase, async: false

  import Sentinelix.Test.AuthHelpers
  import Sentinelix.AccountsFixtures

  alias Sentinelix.Accounts
  alias Sentinelix.Test.FakeOIDCProvider

  @moduletag :capture_log

  @claims %{
    "sub" => "user-123",
    "email" => "alice@example.com",
    "email_verified" => true,
    "name" => "Alice"
  }

  describe "with OIDC configured" do
    setup do
      %{fake: setup_oidc()}
    end

    test "login page shows the provider button and hides the local form", %{conn: conn} do
      html = conn |> get(~p"/login") |> html_response(200)

      assert html =~ "Sign in with TestIdP"
      assert html =~ ~s(href="/auth/oidc")
      refute html =~ "local-login-form"
    end

    test "redirects to the provider with state, nonce and PKCE", %{conn: conn, fake: fake} do
      conn = get(conn, ~p"/auth/oidc")
      params = authorization_params(conn, fake)

      assert params["response_type"] == "code"
      assert params["client_id"] == fake.client_id
      assert params["redirect_uri"] == "http://localhost:4002/auth/oidc/callback"
      assert params["code_challenge_method"] == "S256"
      assert params["state"] && params["nonce"] && params["code_challenge"]
      assert params["scope"] |> String.split() |> Enum.sort() == ["email", "openid", "profile"]
      assert %{"state" => state} = get_session(conn, :oidc_flow)
      assert state == params["state"]
    end

    test "logs in and provisions the user just in time", %{conn: conn, fake: fake} do
      conn = oidc_login(conn, fake, @claims)

      assert redirected_to(conn) == ~p"/"
      assert get_session(conn, :user_token)
      refute get_session(conn, :oidc_flow)

      user = Accounts.get_user_by_oidc_identity(fake.issuer, "user-123")
      assert user.email == "alice@example.com"
      assert user.name == "Alice"
      assert user.last_login_at
      refute user.hashed_password

      conn = get(conn, ~p"/")
      assert html_response(conn, 200) =~ "Alice"
    end

    test "matches returning users by subject even if the email changed", %{
      conn: conn,
      fake: fake
    } do
      conn = oidc_login(conn, fake, @claims)
      user = Accounts.get_user_by_oidc_identity(fake.issuer, "user-123")

      conn = delete(conn, ~p"/logout")

      claims = %{@claims | "email" => "alice@new.example.com", "name" => "Alice B"}
      conn = oidc_login(recycle(conn), fake, claims)
      assert redirected_to(conn) == ~p"/"

      updated = Accounts.get_user_by_oidc_identity(fake.issuer, "user-123")
      assert updated.id == user.id
      assert updated.email == "alice@new.example.com"
      assert updated.name == "Alice B"
      assert Sentinelix.Repo.aggregate(Accounts.User, :count) == 1
    end

    test "does not match an existing user with the same email but another subject", %{
      conn: conn,
      fake: fake
    } do
      existing = oidc_user_fixture(%{oidc_issuer: fake.issuer, email: "alice@example.com"})

      conn = oidc_login(conn, fake, @claims)
      assert redirected_to(conn) == ~p"/"

      user = Accounts.get_user_by_oidc_identity(fake.issuer, "user-123")
      assert user.id != existing.id
    end

    test "returns to the originally requested page", %{conn: conn, fake: fake} do
      conn = get(conn, ~p"/monitors/1")
      assert redirected_to(conn) == ~p"/login"

      conn = oidc_login(recycle(conn), fake, @claims)
      assert redirected_to(conn) == ~p"/monitors/1"
    end

    test "uses claims from the userinfo endpoint", %{conn: conn, fake: fake} do
      claims = Map.drop(@claims, ["name"])
      conn = oidc_login(conn, fake, claims, userinfo: %{"name" => "From Userinfo"})

      assert redirected_to(conn) == ~p"/"
      assert Accounts.get_user_by_oidc_identity(fake.issuer, "user-123").name == "From Userinfo"
    end

    test "rejects a callback with a wrong state", %{conn: conn, fake: fake} do
      conn = oidc_login(conn, fake, @claims, state: "forged")

      assert redirected_to(conn) == ~p"/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "failed"
      refute get_session(conn, :user_token)
      assert FakeOIDCProvider.token_requests(fake) == 0
      assert Sentinelix.Repo.aggregate(Accounts.User, :count) == 0
    end

    test "rejects a callback without a pending login", %{conn: conn} do
      conn = get(conn, ~p"/auth/oidc/callback", %{"code" => "abc", "state" => "xyz"})

      assert redirected_to(conn) == ~p"/login"
      refute get_session(conn, :user_token)
    end

    test "a flow can only be used once", %{conn: conn, fake: fake} do
      conn = get(conn, ~p"/auth/oidc")
      params = authorization_params(conn, fake)

      code =
        FakeOIDCProvider.issue_code(fake,
          nonce: params["nonce"],
          code_challenge: params["code_challenge"],
          claims: @claims
        )

      callback = %{"code" => code, "state" => params["state"]}
      conn = get(conn, ~p"/auth/oidc/callback", callback)
      assert redirected_to(conn) == ~p"/"

      # replaying the callback with a fresh browser session fails
      conn = get(build_conn(), ~p"/auth/oidc/callback", callback)
      assert redirected_to(conn) == ~p"/login"
      refute get_session(conn, :user_token)
    end

    test "rejects an ID token with a wrong nonce", %{conn: conn, fake: fake} do
      conn = oidc_login(conn, fake, Map.put(@claims, "nonce", "other-nonce"))

      assert redirected_to(conn) == ~p"/login"
      refute get_session(conn, :user_token)
      assert Sentinelix.Repo.aggregate(Accounts.User, :count) == 0
    end

    test "rejects an ID token for another audience", %{conn: conn, fake: fake} do
      conn = oidc_login(conn, fake, Map.put(@claims, "aud", "someone-else"))

      assert redirected_to(conn) == ~p"/login"
      refute get_session(conn, :user_token)
    end

    test "rejects an ID token from another issuer", %{conn: conn, fake: fake} do
      conn = oidc_login(conn, fake, Map.put(@claims, "iss", "https://evil.example.com"))

      assert redirected_to(conn) == ~p"/login"
      refute get_session(conn, :user_token)
    end

    test "rejects an expired ID token", %{conn: conn, fake: fake} do
      claims = Map.put(@claims, "exp", System.system_time(:second) - 3600)
      conn = oidc_login(conn, fake, claims)

      assert redirected_to(conn) == ~p"/login"
      refute get_session(conn, :user_token)
    end

    test "shows the provider's error", %{conn: conn} do
      conn = get(conn, ~p"/auth/oidc")

      conn =
        get(conn, ~p"/auth/oidc/callback", %{
          "error" => "access_denied",
          "state" => get_session(conn, :oidc_flow)["state"]
        })

      assert redirected_to(conn) == ~p"/login"
      refute get_session(conn, :user_token)
    end

    test "logout redirects to the provider's end_session_endpoint", %{conn: conn, fake: fake} do
      conn = oidc_login(conn, fake, @claims)
      token = get_session(conn, :user_token)

      conn = delete(conn, ~p"/logout")

      location = redirected_to(conn)
      uri = URI.parse(location)
      assert "#{uri.scheme}://#{uri.authority}#{uri.path}" == fake.issuer <> "/end_session"
      query = URI.decode_query(uri.query)
      assert query["id_token_hint"]
      assert query["client_id"] == fake.client_id
      assert query["post_logout_redirect_uri"] == "http://localhost:4002/login"

      refute get_session(conn, :user_token)
      refute Accounts.get_user_by_session_token(token)
    end

    test "local login is disabled by default", %{conn: conn} do
      user = user_fixture()

      conn =
        post(conn, ~p"/login", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      assert redirected_to(conn) == ~p"/login"
      refute get_session(conn, :user_token)
    end
  end

  describe "without end_session_endpoint" do
    setup do
      %{fake: setup_oidc(discovery: %{"end_session_endpoint" => nil})}
    end

    test "logout redirects to the login page", %{conn: conn, fake: fake} do
      conn = oidc_login(conn, fake, @claims)
      conn = delete(conn, ~p"/logout")

      assert redirected_to(conn) == ~p"/login"
      refute get_session(conn, :user_token)
    end
  end

  describe "allow-lists" do
    test "denies users outside the allowed groups", %{conn: conn} do
      fake = setup_oidc(oidc: [allowed_groups: ["sentinelix-admins"]])

      conn = oidc_login(conn, fake, Map.put(@claims, "groups", ["staff"]))

      assert html_response(conn, 403) =~ "Access denied"
      refute get_session(conn, :user_token)
      assert Sentinelix.Repo.aggregate(Accounts.User, :count) == 0
    end

    test "allows users in an allowed group", %{conn: conn} do
      fake = setup_oidc(oidc: [allowed_groups: ["sentinelix-admins"]])

      conn = oidc_login(conn, fake, Map.put(@claims, "groups", ["staff", "sentinelix-admins"]))

      assert redirected_to(conn) == ~p"/"
    end

    test "stores the user's groups and refreshes them on every login", %{conn: conn} do
      fake = setup_oidc()

      oidc_login(conn, fake, Map.put(@claims, "groups", ["staff", "ops"]))
      user = Accounts.get_user_by_oidc_identity(fake.issuer, "user-123")
      assert user.groups == ["ops", "staff"]

      oidc_login(build_conn(), fake, Map.put(@claims, "groups", ["staff"]))
      assert Sentinelix.Repo.reload!(user).groups == ["staff"]

      oidc_login(build_conn(), fake, @claims)
      assert Sentinelix.Repo.reload!(user).groups == []
    end

    test "stores groups from a custom (nested) claim", %{conn: conn} do
      fake = setup_oidc(oidc: [groups_claim: "realm_access.roles"])

      oidc_login(conn, fake, Map.put(@claims, "realm_access", %{"roles" => ["ops"]}))

      assert Accounts.get_user_by_oidc_identity(fake.issuer, "user-123").groups == ["ops"]
    end

    test "reads groups from a custom claim, also via userinfo", %{conn: conn} do
      fake = setup_oidc(oidc: [allowed_groups: ["ops"], groups_claim: "roles"])

      conn = oidc_login(conn, fake, @claims, userinfo: %{"roles" => ["ops"]})

      assert redirected_to(conn) == ~p"/"
    end

    test "denies emails that are not allowed", %{conn: conn} do
      fake = setup_oidc(oidc: [allowed_emails: ["bob@example.com"]])

      conn = oidc_login(conn, fake, @claims)

      assert html_response(conn, 403) =~ "Access denied"
    end

    test "allows allowed emails", %{conn: conn} do
      fake = setup_oidc(oidc: [allowed_emails: ["Alice@Example.com"]])

      assert conn |> oidc_login(fake, @claims) |> redirected_to() == ~p"/"
    end

    test "denies other domains", %{conn: conn} do
      fake = setup_oidc(oidc: [allowed_domains: ["corp.example"]])

      conn = oidc_login(conn, fake, @claims)

      assert html_response(conn, 403) =~ "Access denied"
    end

    test "allows allowed domains", %{conn: conn} do
      fake = setup_oidc(oidc: [allowed_domains: ["example.com"]])

      assert conn |> oidc_login(fake, @claims) |> redirected_to() == ~p"/"
    end
  end

  describe "with OIDC and local auth enabled" do
    setup do
      %{fake: setup_oidc(local_auth_enabled: true)}
    end

    test "login page shows both options", %{conn: conn} do
      html = conn |> get(~p"/login") |> html_response(200)

      assert html =~ "Sign in with TestIdP"
      assert html =~ "local-login-form"
    end

    test "logout of a local user does not redirect to the provider", %{conn: conn} do
      user = user_fixture()

      conn =
        post(conn, ~p"/login", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      assert redirected_to(conn) == ~p"/"

      conn = delete(conn, ~p"/logout")
      assert redirected_to(conn) == ~p"/login"
    end
  end

  describe "with the provider unreachable" do
    test "shows an error instead of crashing", %{conn: conn} do
      put_app_env(:oidc,
        issuer: "http://127.0.0.1:1",
        client_id: "sentinelix",
        client_secret: "secret",
        provider_name: "TestIdP",
        allow_insecure_http: true
      )

      start_supervised!(Sentinelix.Auth.OIDC)

      conn = get(conn, ~p"/auth/oidc")

      assert redirected_to(conn) == ~p"/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "TestIdP is currently unavailable"
    end
  end

  describe "without OIDC configured" do
    test "the OIDC routes redirect to the login page", %{conn: conn} do
      conn = get(conn, ~p"/auth/oidc")
      assert redirected_to(conn) == ~p"/login"

      conn = get(build_conn(), ~p"/auth/oidc/callback", %{"code" => "a", "state" => "b"})
      assert redirected_to(conn) == ~p"/login"
    end
  end
end
