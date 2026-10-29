defmodule Sentinelix.Auth.OIDC do
  @moduledoc """
  OpenID Connect login (Authorization Code flow with PKCE) on top of `oidcc`.

  Provider metadata is fetched through discovery
  (`<issuer>/.well-known/openid-configuration`) and kept fresh, together with
  the JWKS, by an `Oidcc.ProviderConfiguration.Worker` registered as
  `#{inspect(__MODULE__)}.Provider`. It is started by
  `Sentinelix.Application` when OIDC is configured and retries with backoff
  while the IdP is unreachable, so the app (and the local break-glass login)
  keeps working when the IdP is down.

  `oidcc` validates the ID token signature, `iss`, `aud`, `exp`, the `nonce`
  and the PKCE verifier; `callback/3` additionally checks `state`.
  """

  require Logger

  alias Sentinelix.Auth

  @provider __MODULE__.Provider

  @doc """
  The registered name of the provider configuration worker.
  """
  def provider, do: @provider

  @doc """
  Child spec for the provider configuration worker.

  ## Options

    * `:config` - OIDC config map, defaults to `Sentinelix.Auth.oidc_config/0`.
  """
  def child_spec(opts) do
    config = Keyword.get_lazy(opts, :config, &Auth.oidc_config/0)

    %{
      id: @provider,
      start:
        {Oidcc.ProviderConfiguration.Worker, :start_link,
         [
           %{
             issuer: config.issuer,
             name: @provider,
             backoff_type: :random_exponential,
             backoff_min: 1_000,
             backoff_max: 30_000,
             provider_configuration_opts: %{
               quirks: %{allow_unsafe_http: config.allow_insecure_http}
             }
           }
         ]}
    }
  end

  @doc """
  Children to add to the application supervisor (none if OIDC is disabled).
  """
  def children do
    if Auth.oidc_enabled?(), do: [child_spec([])], else: []
  end

  @doc """
  Returns true once the provider metadata and keys have been loaded.
  """
  def ready? do
    Process.whereis(@provider) != nil and
      :oidcc_provider_configuration_worker.get_provider_configuration(@provider) != :undefined and
      :oidcc_provider_configuration_worker.get_jwks(@provider) != :undefined
  end

  @doc """
  Starts a login: returns the IdP authorization URL and the flow data
  (`state`, `nonce`, PKCE verifier) that must be kept in the session until
  the callback.
  """
  def authorization_request(redirect_uri) do
    with %{} = config <- Auth.oidc_config() || {:error, :not_configured} do
      flow = %{
        "state" => random_token(),
        "nonce" => random_token(),
        "pkce_verifier" => random_token()
      }

      case Oidcc.create_redirect_url(@provider, config.client_id, config.client_secret, %{
             redirect_uri: redirect_uri,
             state: flow["state"],
             nonce: flow["nonce"],
             pkce_verifier: flow["pkce_verifier"],
             scopes: config.scopes
           }) do
        {:ok, url} -> {:ok, IO.iodata_to_binary(url), flow}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Handles the redirect back from the IdP.

  `params` are the callback query params and `flow` the map returned by
  `authorization_request/1`. Returns `{:ok, %{claims: claims, id_token: raw}}`
  where `claims` are the validated ID token claims, merged with the userinfo
  response when the provider has a userinfo endpoint (ID token claims win).
  """
  def callback(params, flow, redirect_uri)

  def callback(%{"error" => error} = params, _flow, _redirect_uri) do
    {:error, {:provider_error, error, params["error_description"]}}
  end

  def callback(_params, flow, _redirect_uri) when not is_map(flow),
    do: {:error, :missing_flow}

  def callback(%{"code" => code, "state" => state}, %{"state" => expected} = flow, redirect_uri)
      when is_binary(code) and is_binary(state) and is_binary(expected) do
    with :ok <- verify_state(state, expected),
         %{} = config <- Auth.oidc_config() || {:error, :not_configured},
         {:ok, %Oidcc.Token{} = token} <-
           Oidcc.retrieve_token(code, @provider, config.client_id, config.client_secret, %{
             redirect_uri: redirect_uri,
             nonce: flow["nonce"],
             pkce_verifier: flow["pkce_verifier"]
           }) do
      {:ok, %{claims: claims(token, config), id_token: token.id.token}}
    end
  end

  def callback(_params, _flow, _redirect_uri), do: {:error, :invalid_request}

  defp verify_state(state, expected) do
    if Plug.Crypto.secure_compare(state, expected), do: :ok, else: {:error, :invalid_state}
  end

  defp claims(%Oidcc.Token{id: %{claims: id_claims}} = token, config) do
    if userinfo_endpoint?() do
      case Oidcc.retrieve_userinfo(token, @provider, config.client_id, config.client_secret) do
        {:ok, userinfo} ->
          Map.merge(userinfo, id_claims)

        {:error, reason} ->
          Logger.warning("OIDC userinfo request failed: #{inspect(reason)}")
          id_claims
      end
    else
      id_claims
    end
  end

  defp userinfo_endpoint? do
    case :oidcc_provider_configuration_worker.get_provider_configuration(@provider) do
      :undefined ->
        false

      record ->
        is_binary(Oidcc.ProviderConfiguration.record_to_struct(record).userinfo_endpoint)
    end
  end

  @doc """
  Builds the RP-initiated logout URL if the provider advertises an
  `end_session_endpoint`. Returns `{:ok, url}` or `:error`.
  """
  def logout_url(id_token, post_logout_redirect_uri) when is_binary(id_token) do
    with %{} = config <- Auth.oidc_config(),
         true <- Process.whereis(@provider) != nil,
         {:ok, url} <-
           Oidcc.initiate_logout_url(id_token, @provider, config.client_id, %{
             post_logout_redirect_uri: post_logout_redirect_uri
           }) do
      {:ok, IO.iodata_to_binary(url)}
    else
      _ -> :error
    end
  end

  def logout_url(_id_token, _post_logout_redirect_uri), do: :error

  defp random_token, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
end
