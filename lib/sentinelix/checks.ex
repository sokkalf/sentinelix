defmodule Sentinelix.Checks do
  @moduledoc """
  Registry of check implementations per monitor type.

  Every module implements the `Sentinelix.Checks.Check` behaviour. To add a
  check type, implement the behaviour and add it to `@checks` below; the
  monitoring engine then starts workers for monitors of that type.
  """

  alias Sentinelix.Checks

  @checks %{
    http: Checks.HTTP,
    keyword: Checks.Keyword,
    tcp: Checks.TCP,
    ping: Checks.Ping,
    dns: Checks.DNS,
    cert: Checks.Cert,
    push: Checks.Push,
    postgres: Checks.Postgres
  }

  @doc """
  All registered checks as a map of monitor type => module.
  """
  @spec modules() :: %{atom() => module()}
  def modules, do: @checks

  @doc """
  The check module for a monitor type.
  """
  @spec module_for(atom()) :: {:ok, module()} | :error
  def module_for(type), do: Map.fetch(@checks, type)

  @doc """
  The value sent in the `User-Agent` header of HTTP based checks.
  """
  @spec user_agent() :: String.t()
  def user_agent, do: "Sentinelix/#{Application.spec(:sentinelix, :vsn)}"
end
