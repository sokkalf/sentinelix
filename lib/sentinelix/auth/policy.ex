defmodule Sentinelix.Auth.Policy do
  @moduledoc """
  Decides whether a user authenticated by the OIDC provider may use Sentinelix.

  Three optional allow-lists are supported:

    * `:allowed_groups` - matched against the groups claim (`:groups_claim`,
      default `"groups"`). The claim may be a list of strings, a single string
      or a map (its keys are used, e.g. Zitadel role claims). A dotted path
      such as `"realm_access.roles"` (Keycloak) is followed into nested maps
      when no claim with that literal name exists.
    * `:allowed_emails` - exact (case-insensitive) match on the `email` claim.
    * `:allowed_domains` - matches the domain part of the `email` claim.

  Email-based rules are skipped when the IdP says `email_verified: false`.

  If no allow-list is configured, everybody the IdP authenticates is allowed.
  Otherwise the user is allowed when **any** configured rule matches.
  """

  @doc """
  Returns `:ok` or `{:error, :not_allowed}`.
  """
  def authorize(claims, config) when is_map(claims) do
    groups = normalize(config[:allowed_groups], & &1)
    emails = normalize(config[:allowed_emails], &String.downcase/1)
    domains = normalize(config[:allowed_domains], &(&1 |> String.downcase() |> trim_at()))

    cond do
      groups == [] and emails == [] and domains == [] ->
        :ok

      groups != [] and
          Enum.any?(groups(claims, config[:groups_claim] || "groups"), &(&1 in groups)) ->
        :ok

      (email = verified_email(claims)) && (email in emails or email_domain(email) in domains) ->
        :ok

      true ->
        {:error, :not_allowed}
    end
  end

  @doc """
  Extracts the group names from the claims.
  """
  def groups(claims, claim_name) do
    case Map.fetch(claims, claim_name) do
      {:ok, value} -> to_groups(value)
      :error -> claims |> get_path(String.split(claim_name, ".")) |> to_groups()
    end
  end

  defp get_path(value, []), do: value
  defp get_path(%{} = map, [key | rest]), do: get_path(Map.get(map, key), rest)
  defp get_path(_, _), do: nil

  defp to_groups(list) when is_list(list), do: Enum.flat_map(list, &to_groups/1)
  defp to_groups(%{} = map), do: Enum.map(Map.keys(map), &to_string/1)
  defp to_groups(value) when is_binary(value), do: [value]
  defp to_groups(_), do: []

  defp verified_email(%{"email_verified" => verified}) when verified in [false, "false"], do: nil

  defp verified_email(%{"email" => email}) when is_binary(email) and email != "",
    do: String.downcase(email)

  defp verified_email(_), do: nil

  defp email_domain(email), do: email |> String.split("@") |> List.last()

  defp trim_at("@" <> domain), do: domain
  defp trim_at(domain), do: domain

  defp normalize(nil, _fun), do: []
  defp normalize(list, fun), do: list |> Enum.reject(&(&1 in [nil, ""])) |> Enum.map(fun)
end
