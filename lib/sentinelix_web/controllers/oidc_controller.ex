defmodule SentinelixWeb.OIDCController do
  @moduledoc """
  OpenID Connect login: redirect to the IdP and handle its callback.

  The redirect URI registered at the IdP must be
  `<endpoint url>/auth/oidc/callback`.
  """
  use SentinelixWeb, :controller

  require Logger

  alias Sentinelix.{Accounts, Auth}
  alias Sentinelix.Auth.{OIDC, Policy}
  alias SentinelixWeb.UserAuth

  def request(conn, _params) do
    if Auth.oidc_enabled?() do
      case OIDC.authorization_request(callback_url()) do
        {:ok, url, flow} ->
          conn
          |> put_session(:oidc_flow, flow)
          |> redirect(external: url)

        {:error, reason} ->
          Logger.warning("OIDC login could not be started: #{inspect(reason)}")

          conn
          |> put_flash(:error, "#{Auth.provider_name()} is currently unavailable.")
          |> redirect(to: ~p"/login")
      end
    else
      conn
      |> put_flash(:error, "Single sign-on is not configured.")
      |> redirect(to: ~p"/login")
    end
  end

  def callback(conn, params) do
    flow = get_session(conn, :oidc_flow)
    conn = delete_session(conn, :oidc_flow)

    with true <- Auth.oidc_enabled?() || {:error, :not_configured},
         {:ok, %{claims: claims, id_token: id_token}} <-
           OIDC.callback(params, flow, callback_url()),
         :ok <- authorize(claims),
         {:ok, user} <- Accounts.upsert_oidc_user(user_attrs(claims)) do
      UserAuth.log_in_user(conn, user, oidc_id_token: id_token)
    else
      {:error, {:not_allowed, claims}} ->
        Logger.info(
          "OIDC login denied by allow-list: sub=#{inspect(claims["sub"])} email=#{inspect(claims["email"])}"
        )

        conn
        |> put_status(:forbidden)
        |> render(:denied, page_title: "Access denied")

      {:error, reason} ->
        Logger.warning("OIDC login failed: #{format_reason(reason)}")

        conn
        |> put_flash(
          :error,
          "Sign in with #{Auth.provider_name() || "SSO"} failed. Please try again."
        )
        |> redirect(to: ~p"/login")
    end
  end

  defp authorize(claims) do
    case Policy.authorize(claims, Auth.oidc_config()) do
      :ok -> :ok
      {:error, :not_allowed} -> {:error, {:not_allowed, claims}}
    end
  end

  # Keep personal data (the full claims) out of the logs.
  defp format_reason({:missing_claim, {claim, _expected}, _claims}),
    do: "invalid or missing claim #{inspect(claim)}"

  defp format_reason({:missing_claim, claim, _claims}),
    do: "invalid or missing claim #{inspect(claim)}"

  defp format_reason(%Ecto.Changeset{} = changeset),
    do: "could not save user: #{inspect(changeset.errors)}"

  defp format_reason(reason), do: inspect(reason)

  defp callback_url, do: url(~p"/auth/oidc/callback")

  defp user_attrs(claims) do
    %{
      oidc_issuer: claims["iss"],
      oidc_subject: claims["sub"],
      email: string_claim(claims, "email"),
      name: string_claim(claims, "name") || string_claim(claims, "preferred_username")
    }
  end

  defp string_claim(claims, key) do
    case claims[key] do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end
end
