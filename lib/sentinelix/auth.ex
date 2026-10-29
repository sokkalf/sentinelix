defmodule Sentinelix.Auth do
  @moduledoc """
  Runtime authentication settings.

  Configured in `config/runtime.exs` from environment variables:

      config :sentinelix, :oidc,
        issuer: "https://idp.example.com/application/o/sentinelix/",
        client_id: "...",
        client_secret: "...",
        scopes: ["openid", "profile", "email"],
        provider_name: "Authentik",
        groups_claim: "groups",
        allowed_groups: [],
        allowed_emails: [],
        allowed_domains: []

      # nil means: enabled only when OIDC is not configured
      config :sentinelix, :local_auth_enabled, nil

  OIDC is enabled when `:issuer` and `:client_id` are set.
  """

  @default_scopes ["openid", "profile", "email"]

  @doc """
  Returns the OIDC settings as a map, or nil when OIDC is not configured.
  """
  def oidc_config do
    config = Application.get_env(:sentinelix, :oidc) || []

    if present?(config[:issuer]) and present?(config[:client_id]) do
      %{
        issuer: config[:issuer],
        client_id: config[:client_id],
        client_secret: config[:client_secret] || :unauthenticated,
        scopes: list(config[:scopes], @default_scopes),
        provider_name:
          if(present?(config[:provider_name]), do: config[:provider_name], else: "SSO"),
        groups_claim:
          if(present?(config[:groups_claim]), do: config[:groups_claim], else: "groups"),
        allowed_groups: list(config[:allowed_groups], []),
        allowed_emails: list(config[:allowed_emails], []),
        allowed_domains: list(config[:allowed_domains], []),
        allow_insecure_http: config[:allow_insecure_http] == true
      }
    end
  end

  @doc """
  Returns true when OpenID Connect login is configured.
  """
  def oidc_enabled?, do: oidc_config() != nil

  @doc """
  Returns true when the local (password) break-glass login is enabled.

  Defaults to `true` when OIDC is not configured and `false` when it is,
  unless explicitly set with `LOCAL_AUTH_ENABLED`.
  """
  def local_auth_enabled? do
    case Application.get_env(:sentinelix, :local_auth_enabled) do
      enabled when is_boolean(enabled) -> enabled
      _ -> not oidc_enabled?()
    end
  end

  @doc """
  The label for the "Sign in with ..." button.
  """
  def provider_name do
    case oidc_config() do
      %{provider_name: name} -> name
      nil -> nil
    end
  end

  defp present?(value), do: is_binary(value) and value != ""

  defp list(value, default) when value in [nil, []], do: default
  defp list(value, _default) when is_list(value), do: value
end
