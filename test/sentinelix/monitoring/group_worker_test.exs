defmodule Sentinelix.Monitoring.GroupWorkerTest do
  @moduledoc """
  Group monitors in the engine: re-checks when members change (see
  "Re-checks" in `Sentinelix.Monitoring.Worker`).
  """

  use Sentinelix.DataCase, async: false

  import Sentinelix.MonitoringFixtures

  alias Phoenix.PubSub
  alias Sentinelix.Checks
  alias Sentinelix.FakeCheck
  alias Sentinelix.Monitoring
  alias Sentinelix.Monitoring.Supervisor, as: Engine
  alias Sentinelix.Monitoring.Worker

  @engine __MODULE__.Engine

  # A check that reacts to `:poke` messages on a test topic and takes a
  # while to run.
  defmodule SlowReactiveCheck do
    @behaviour Sentinelix.Checks.Check

    def topic(monitor), do: "slow_reactive_check:#{monitor.id}"

    @impl true
    def run(monitor) do
      Process.sleep(150)
      FakeCheck.run(monitor)
    end

    @impl true
    def subscribe(monitor), do: PubSub.subscribe(Sentinelix.PubSub, topic(monitor))

    @impl true
    def recheck?(_monitor, message), do: message == :poke
  end

  setup do
    start_supervised!(FakeCheck)

    start_supervised!(
      {Engine,
       name: @engine,
       manager: false,
       jitter: 0,
       recheck_delay_ms: 20,
       checks: %{tcp: FakeCheck, group: Checks.Group, http: SlowReactiveCheck}}
    )

    :ok
  end

  defp group_fixture(attrs \\ %{}) do
    monitor_fixture(:group, Map.merge(%{name: "Shop", settings: %{members: "app=shop"}}, attrs))
  end

  defp member_fixture(name), do: monitor_fixture(:tcp, %{name: name, labels: %{"app" => "shop"}})

  defp start(monitor) do
    :ok = Monitoring.subscribe_monitor(monitor)
    {:ok, pid} = Engine.start_worker(monitor, @engine)
    pid
  end

  defp assert_result(monitor, status) do
    id = monitor.id
    assert_receive {:check_result, %{monitor_id: ^id, status: ^status} = result}, 2_000
    result
  end

  test "re-checks when a member's status changes" do
    group = group_fixture()
    web = member_fixture("Web")
    db = member_fixture("DB")
    check_result_fixture(db, status: :up)

    start(group)
    assert_result(group, :up)

    FakeCheck.push(web, [{:down, %{message: "refused"}}])
    start(web)
    assert_result(web, :down)

    result = assert_result(group, :down)
    assert result.message == "1 of 2 members down: Web"
    assert result.response_time_ms == nil
    assert %{status: :down} = Worker.info(group, @engine)

    # Recovers when the member does.
    :ok = Worker.check_now(web, @engine)
    assert_result(web, :up)
    assert assert_result(group, :up).message == "All 2 members up"
  end

  test "re-checks when a member leaves the group" do
    group = group_fixture()
    web = member_fixture("Web")
    check_result_fixture(web, status: :down)
    check_result_fixture(member_fixture("DB"), status: :up)

    start(group)
    assert_result(group, :down)

    {:ok, _web} = Monitoring.update_monitor(web, %{labels: %{"app" => "blog"}})
    assert assert_result(group, :up).message == "1 member up"
  end

  test "ignores status changes of other monitors" do
    group = group_fixture()
    check_result_fixture(member_fixture("Web"), status: :up)
    other = monitor_fixture(:tcp, %{name: "Other"})

    start(group)
    assert_result(group, :up)

    Monitoring.broadcast_status_event(other, {:status_changed, other, :up, :down, nil})
    refute_receive {:check_result, _}, 200
  end

  test "makes one check of a burst of changes" do
    group = group_fixture()
    web = member_fixture("Web")
    check_result_fixture(web, status: :up)

    pid = start(group)
    assert_result(group, :up)

    for _ <- 1..5, do: send(pid, {:status_changed, web, :up, :down, nil})

    assert_result(group, :up)
    refute_receive {:check_result, _}, 200
  end

  test "checks again after a running check when asked during it" do
    monitor = monitor_fixture(:http)
    start(monitor)
    # The first check runs for 150 ms.
    Process.sleep(50)
    PubSub.broadcast(Sentinelix.PubSub, SlowReactiveCheck.topic(monitor), :poke)

    assert_result(monitor, :up)
    assert_result(monitor, :up)
    refute_receive {:check_result, _}, 300
  end
end
