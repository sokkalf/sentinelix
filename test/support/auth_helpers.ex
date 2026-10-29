defmodule Sentinelix.Test.AuthHelpers do
  @moduledoc """
  Helpers for tests that change the authentication configuration or log in
  through the fake OIDC provider. Tests using them must not be `async`.
  """

  import ExUnit.Assertions

  alias Sentinelix.Auth.OIDC
  alias Sentinelix.Test.FakeOIDCProvider

  @doc """
  Sets an application env key of `:sentinelix` for the current test only.
  """
  def put_app_env(key, value) do
    previous = Application.fetch_env(:sentinelix, key)
    Application.put_env(:sentinelix, key, value)

    ExUnit.Callbacks.on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:sentinelix, key, value)
        :error -> Application.delete_env(:sentinelix, key)
      end
    end)
  end

  @doc """
  Starts a fake OIDC provider, configures Sentinelix to use it and starts the
  provider configuration worker. Returns the fake provider.

  ## Options

    * `:oidc` - extra OIDC config (e.g. `allowed_groups: ["admins"]`)
    * `:discovery` - overrides for the fake's discovery document
    * `:local_auth_enabled` - defaults to unset (automatic)
  """
  def setup_oidc(opts \\ []) do
    fake = FakeOIDCProvider.start!(discovery: Keyword.get(opts, :discovery, %{}))

    put_app_env(
      :oidc,
      Keyword.merge(
        [
          issuer: fake.issuer,
          client_id: fake.client_id,
          client_secret: fake.client_secret,
          provider_name: "TestIdP",
          allow_insecure_http: true
        ],
        Keyword.get(opts, :oidc, [])
      )
    )

    if Keyword.has_key?(opts, :local_auth_enabled) do
      put_app_env(:local_auth_enabled, opts[:local_auth_enabled])
    end

    ExUnit.Callbacks.start_supervised!(OIDC)
    wait_until(&OIDC.ready?/0)

    fake
  end

  @doc """
  Runs the browser side of an OIDC login against the fake provider.

  Requests `/auth/oidc`, extracts the authorization request parameters from
  the redirect, lets the fake provider issue a code for `claims` and requests
  the callback. Returns the callback conn.

  ## Options

    * `:userinfo` - extra claims served by the userinfo endpoint
    * `:state` - override the `state` sent back to the callback
    * `:redirect_uri` - override the redirect URI the code is bound to
  """
  def oidc_login(conn, fake, claims, opts \\ []) do
    conn = Phoenix.ConnTest.dispatch(conn, SentinelixWeb.Endpoint, :get, "/auth/oidc", nil)
    params = authorization_params(conn, fake)

    code =
      FakeOIDCProvider.issue_code(fake,
        nonce: params["nonce"],
        code_challenge: params["code_challenge"],
        redirect_uri: Keyword.get(opts, :redirect_uri, params["redirect_uri"]),
        claims: claims,
        userinfo: Keyword.get(opts, :userinfo, %{})
      )

    Phoenix.ConnTest.dispatch(conn, SentinelixWeb.Endpoint, :get, "/auth/oidc/callback", %{
      "code" => code,
      "state" => Keyword.get(opts, :state, params["state"])
    })
  end

  @doc """
  Asserts that `conn` redirects to the fake provider's authorization endpoint
  and returns the query params.
  """
  def authorization_params(conn, fake) do
    assert conn.status == 302
    [location] = Plug.Conn.get_resp_header(conn, "location")
    uri = URI.parse(location)
    assert "#{uri.scheme}://#{uri.authority}#{uri.path}" == fake.issuer <> "/authorize"
    URI.decode_query(uri.query)
  end

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition not met in time")

      true ->
        Process.sleep(20)
        wait_until(fun, attempts - 1)
    end
  end
end
