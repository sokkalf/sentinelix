defmodule Sentinelix.Test.FakeOIDCProvider do
  @moduledoc """
  A tiny OpenID Connect provider for tests, served by Bandit on a random
  local port.

  It implements discovery, JWKS, the token endpoint (client_secret_basic /
  client_secret_post, PKCE S256) and userinfo, and signs ID tokens with an
  RS256 test key. The browser-facing `/authorize` step is skipped: tests read
  `state`, `nonce` and `code_challenge` from the redirect URL and call
  `issue_code/2` to get an authorization code, just like a real IdP would
  after a successful login.
  """
  @behaviour Plug

  import Plug.Conn

  defstruct [:agent, :issuer, :client_id, :client_secret]

  @kid "sentinelix-test-key"

  @doc """
  Starts a provider under the test supervisor.

  ## Options

    * `:client_id`, `:client_secret`
    * `:discovery` - map merged into the discovery document; `nil` values
      remove a key (e.g. `%{"end_session_endpoint" => nil}`).
  """
  def start!(opts \\ []) do
    client_id = Keyword.get(opts, :client_id, "sentinelix")
    client_secret = Keyword.get(opts, :client_secret, "sentinelix-secret")

    agent =
      ExUnit.Callbacks.start_supervised!(
        {Agent,
         fn ->
           %{
             issuer: nil,
             client_id: client_id,
             client_secret: client_secret,
             discovery: Keyword.get(opts, :discovery, %{}),
             codes: %{},
             access_tokens: %{},
             token_requests: 0
           }
         end},
        id: {__MODULE__, :agent}
      )

    server =
      ExUnit.Callbacks.start_supervised!(
        {Bandit, plug: {__MODULE__, agent}, port: 0, ip: :loopback, startup_log: false},
        id: {__MODULE__, :server}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    issuer = "http://127.0.0.1:#{port}"
    Agent.update(agent, &%{&1 | issuer: issuer})

    %__MODULE__{agent: agent, issuer: issuer, client_id: client_id, client_secret: client_secret}
  end

  @doc """
  Registers an authorization code.

  ## Options

    * `:nonce`, `:code_challenge`, `:redirect_uri` - from the authorization request
    * `:claims` - ID token claims (`sub` is required); may override `iss`,
      `aud`, `nonce`, `exp`, ... to produce invalid tokens
    * `:userinfo` - extra claims returned by the userinfo endpoint
  """
  def issue_code(%__MODULE__{agent: agent}, opts) do
    code = random()
    Agent.update(agent, &put_in(&1, [:codes, code], Map.new(opts)))
    code
  end

  @doc "Number of requests made to the token endpoint."
  def token_requests(%__MODULE__{agent: agent}), do: Agent.get(agent, & &1.token_requests)

  @doc "The test signing key (private)."
  def jwk do
    case :persistent_term.get({__MODULE__, :jwk}, nil) do
      nil ->
        jwk = JOSE.JWK.generate_key({:rsa, 2048})
        :persistent_term.put({__MODULE__, :jwk}, jwk)
        jwk

      jwk ->
        jwk
    end
  end

  ## Plug

  @impl Plug
  def init(agent), do: agent

  @impl Plug
  def call(conn, agent) do
    state = Agent.get(agent, & &1)

    case {conn.method, conn.path_info} do
      {"GET", [".well-known", "openid-configuration"]} -> json(conn, 200, discovery(state))
      {"GET", ["jwks"]} -> json(conn, 200, jwks())
      {"POST", ["token"]} -> token(conn, agent, state)
      {"GET", ["userinfo"]} -> userinfo(conn, state)
      _ -> json(conn, 404, %{"error" => "not_found"})
    end
  end

  defp discovery(%{issuer: issuer, discovery: overrides}) do
    %{
      "issuer" => issuer,
      "authorization_endpoint" => issuer <> "/authorize",
      "token_endpoint" => issuer <> "/token",
      "userinfo_endpoint" => issuer <> "/userinfo",
      "jwks_uri" => issuer <> "/jwks",
      "end_session_endpoint" => issuer <> "/end_session",
      "scopes_supported" => ["openid", "profile", "email", "groups"],
      "response_types_supported" => ["code"],
      "subject_types_supported" => ["public"],
      "id_token_signing_alg_values_supported" => ["RS256"],
      "token_endpoint_auth_methods_supported" => ["client_secret_basic", "client_secret_post"],
      "code_challenge_methods_supported" => ["S256"],
      "grant_types_supported" => ["authorization_code"]
    }
    |> Map.merge(overrides)
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp jwks do
    {_, public} = JOSE.JWK.to_public_map(jwk())
    %{"keys" => [Map.merge(public, %{"kid" => @kid, "use" => "sig", "alg" => "RS256"})]}
  end

  defp token(conn, agent, state) do
    Agent.update(agent, &%{&1 | token_requests: &1.token_requests + 1})
    {:ok, body, conn} = read_body(conn)
    params = URI.decode_query(body)

    with :ok <- check_client(conn, params, state),
         "authorization_code" <- params["grant_type"],
         {code_data, _} when is_map(code_data) <- pop_code(agent, params["code"]),
         :ok <- check_redirect_uri(code_data, params),
         :ok <- check_pkce(code_data, params) do
      claims = id_token_claims(code_data, state)
      access_token = random()

      Agent.update(agent, fn state ->
        userinfo = Map.merge(%{"sub" => claims["sub"]}, Map.get(code_data, :userinfo, %{}))
        put_in(state, [:access_tokens, access_token], userinfo)
      end)

      json(conn, 200, %{
        "access_token" => access_token,
        "token_type" => "Bearer",
        "expires_in" => 300,
        "id_token" => sign(claims),
        "scope" => "openid profile email"
      })
    else
      {:error, status, error} -> json(conn, status, %{"error" => error})
      _ -> json(conn, 400, %{"error" => "invalid_grant"})
    end
  end

  defp check_client(conn, params, state) do
    credentials =
      case get_req_header(conn, "authorization") do
        ["Basic " <> encoded] ->
          [id, secret] = encoded |> Base.decode64!() |> String.split(":", parts: 2)
          {URI.decode_www_form(id), URI.decode_www_form(secret)}

        _ ->
          {params["client_id"], params["client_secret"]}
      end

    if credentials == {state.client_id, state.client_secret},
      do: :ok,
      else: {:error, 401, "invalid_client"}
  end

  defp pop_code(agent, code) do
    Agent.get_and_update(agent, fn state ->
      {code_data, codes} = Map.pop(state.codes, code)
      {{code_data, code}, %{state | codes: codes}}
    end)
  end

  defp check_redirect_uri(%{redirect_uri: expected}, %{"redirect_uri" => expected}), do: :ok
  defp check_redirect_uri(%{redirect_uri: _}, _params), do: {:error, 400, "invalid_grant"}
  defp check_redirect_uri(_code_data, _params), do: :ok

  defp check_pkce(%{code_challenge: challenge}, %{"code_verifier" => verifier})
       when is_binary(challenge) do
    if Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false) == challenge,
      do: :ok,
      else: {:error, 400, "invalid_grant"}
  end

  defp check_pkce(%{code_challenge: challenge}, _params) when is_binary(challenge),
    do: {:error, 400, "invalid_grant"}

  defp check_pkce(_code_data, _params), do: :ok

  defp id_token_claims(code_data, state) do
    now = System.system_time(:second)

    %{
      "iss" => state.issuer,
      "aud" => state.client_id,
      "azp" => state.client_id,
      "iat" => now,
      "exp" => now + 300,
      "nonce" => code_data[:nonce]
    }
    |> Map.merge(Map.get(code_data, :claims, %{}))
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp sign(claims) do
    {_, token} =
      jwk()
      |> JOSE.JWT.sign(%{"alg" => "RS256", "kid" => @kid}, claims)
      |> JOSE.JWS.compact()

    token
  end

  defp userinfo(conn, state) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         %{} = claims <- state.access_tokens[token] do
      json(conn, 200, claims)
    else
      _ -> json(conn, 401, %{"error" => "invalid_token"})
    end
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
end
