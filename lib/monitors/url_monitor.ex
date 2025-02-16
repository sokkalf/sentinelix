defmodule Sentinelix.Monitors.URLMonitor do
  use GenServer
  require Logger
  alias Phoenix.PubSub

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  def init(opts) do
    name = Keyword.get(opts, :name, nil)
    url = Keyword.get(opts, :url, nil)

    verify_url = fn url ->
      cond do
        url == nil ->
          {:error, "No URL specified"}
        not is_binary(url) ->
          {:error, "URL must be a string"}
        URI.parse(url) ->
          {:ok, url}
      end
    end

    case {name, verify_url.(url)} do
      {nil, _} ->
        Logger.error("No name specified")
        {:stop, "No name specified"}
      {_, {:error, reason}} ->
        Logger.error(reason)
        {:stop, reason}
      {_, {:ok, _url}} ->
        start_monitors(name, url)
    end
  end

  def handle_call(:get_state, _from, state) do
    children = Supervisor.which_children(state)
    pids = Enum.map(children, fn {_, pid, _, _} -> pid end)
    status = Enum.map(pids, fn pid -> GenServer.call(pid, :status) end)

    {:reply, status, state}
  end

  def handle_info(msg, state) do
    Logger.info("Received message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp start_monitors(name, url) do
    children = case URI.parse(url).scheme do
      "https" ->
        Logger.info("Subscribing to CertMonitor_#{name} and HTTPMonitor_#{name}")
        PubSub.subscribe(Sentinelix.PubSub, "HTTPMonitor_" <> name)
        PubSub.subscribe(Sentinelix.PubSub, "CertMonitor_" <> name)
        [{Sentinelix.Monitors.CertMonitor, name: name, url: url, interval: 60}, {Sentinelix.Monitors.HTTPMonitor, name: name, url: url, interval: 60}]
      "http" ->
        PubSub.subscribe(Sentinelix.PubSub, "HTTPMonitor_" <> name)
        [{Sentinelix.Monitors.HTTPMonitor, name: name, url: url, interval: 60}]
    end
    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
