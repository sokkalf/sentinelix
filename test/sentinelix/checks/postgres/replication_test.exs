defmodule Sentinelix.Checks.Postgres.ReplicationTest do
  use ExUnit.Case, async: true

  alias Sentinelix.Checks.Postgres.Replication
  alias Sentinelix.Monitoring.Settings

  defp settings(attrs \\ %{}) do
    struct!(Settings, Map.merge(Settings.defaults_for(:postgres), attrs))
  end

  defp standby(receiver),
    do: %{mode: "standby", in_recovery: true, privileged: true, receiver: receiver}

  defp primary(standbys, slots \\ []) do
    %{
      mode: "primary",
      in_recovery: false,
      privileged: true,
      standbys: standbys,
      inactive_slots: slots
    }
  end

  defp walsender(attrs) do
    Map.merge(
      %{
        name: "walreceiver",
        client_addr: "192.0.2.10",
        state: "streaming",
        sync_state: "async",
        write_lag: 0.001,
        flush_lag: 0.002,
        replay_lag: 0.003,
        lag_bytes: 0
      },
      attrs
    )
  end

  describe "role and privileges" do
    test "a standby that is not in recovery is down (failover)" do
      assert {:down, %{message: message, meta: %{role: :primary}}} =
               Replication.evaluate(
                 %{mode: "standby", in_recovery: false, privileged: true},
                 settings()
               )

      assert message == "Expected a standby, but the server is not in recovery (failover?)"
    end

    test "a primary that is in recovery is down" do
      assert {:down, %{message: message, meta: %{role: :standby}}} =
               Replication.evaluate(
                 %{mode: "primary", in_recovery: true, privileged: true},
                 settings()
               )

      assert message == "Expected a primary, but the server is in recovery (a standby)"
    end

    test "missing privileges are reported instead of a lag of 0" do
      for mode <- ["primary", "standby"] do
        data = %{mode: mode, in_recovery: mode == "standby", privileged: false}

        assert {:down, %{message: message}} = Replication.evaluate(data, settings())

        assert message ==
                 "Insufficient privileges to read the replication status (grant pg_monitor)"
      end
    end
  end

  describe "standby" do
    test "is up while streaming" do
      data = standby(%{status: "streaming", lag_bytes: 1536, lag_seconds: 0.25})

      assert {:up, %{message: message, warning: false, meta: meta}} =
               Replication.evaluate(data, settings())

      assert message == "Standby streaming, lag 0.3 s (1.5 kB)"
      assert meta == %{role: :standby, lag_seconds: 0.25, lag_bytes: 1536}
    end

    test "is down when the WAL receiver is not streaming" do
      assert {:down, %{message: "WAL receiver is not running"}} =
               Replication.evaluate(
                 standby(%{status: nil, lag_bytes: nil, lag_seconds: nil}),
                 settings()
               )

      assert {:down, %{message: "WAL receiver is waiting, not streaming"}} =
               Replication.evaluate(
                 standby(%{status: "waiting", lag_bytes: 0, lag_seconds: 0.0}),
                 settings()
               )
    end

    test "applies the lag thresholds" do
      thresholds = settings(%{lag_warn_seconds: 30, lag_critical_seconds: 300})
      data = &standby(%{status: "streaming", lag_bytes: 0, lag_seconds: &1})

      assert {:up, %{warning: false}} = Replication.evaluate(data.(29.9), thresholds)

      assert {:up, %{warning: true, message: message}} =
               Replication.evaluate(data.(30.0), thresholds)

      assert message ==
               "Warning: Standby streaming, lag 30 s (0 B); lag reached the warning threshold of 30 s"

      assert {:down, %{message: message}} = Replication.evaluate(data.(301.0), thresholds)

      assert message ==
               "Standby streaming, lag 301 s (0 B) (lag reached the critical threshold of 300 s)"

      bytes = settings(%{lag_warn_bytes: 1_000, lag_critical_bytes: 1_000_000})

      assert {:up, %{warning: true}} =
               Replication.evaluate(
                 standby(%{status: "streaming", lag_bytes: 1_000, lag_seconds: 0.0}),
                 bytes
               )

      assert {:down, _} =
               Replication.evaluate(
                 standby(%{status: "streaming", lag_bytes: 2_000_000, lag_seconds: 0.0}),
                 bytes
               )
    end
  end

  describe "primary" do
    test "needs min_standbys streaming" do
      assert {:down, %{message: "0 of 1 standbys streaming"}} =
               Replication.evaluate(primary([]), settings())

      catching_up = walsender(%{state: "catchup"})

      assert {:down, %{message: "1 of 2 standbys streaming", meta: meta}} =
               Replication.evaluate(
                 primary([walsender(%{}), catching_up]),
                 settings(%{min_standbys: 2})
               )

      assert %{role: :primary, standbys_streaming: 1, standbys: [_, _]} = meta

      assert {:up, %{message: "No standbys streaming", warning: false}} =
               Replication.evaluate(primary([]), settings(%{min_standbys: 0}))
    end

    test "reports the largest lag of the streaming standbys" do
      standbys = [
        walsender(%{replay_lag: 0.5, lag_bytes: 100}),
        walsender(%{name: "b", replay_lag: nil, lag_bytes: 4096}),
        walsender(%{name: "c", state: "startup", replay_lag: 99.0, lag_bytes: 10_000_000})
      ]

      assert {:up, %{message: message, meta: meta}} =
               Replication.evaluate(primary(standbys), settings())

      assert message == "2 standbys streaming, max lag 0.5 s (4.0 kB)"
      assert %{lag_seconds: 0.5, lag_bytes: 4096, standbys_streaming: 2} = meta

      assert {:down, %{message: message}} =
               Replication.evaluate(primary(standbys), settings(%{lag_critical_bytes: 4096}))

      assert message =~ "lag reached the critical threshold of 4096 bytes"
    end

    test "inactive replication slots are a warning" do
      slots = [
        %{name: "old_replica", retained_bytes: 5 * 1024 * 1024 * 1024},
        %{name: "unused", retained_bytes: nil}
      ]

      assert {:up, %{warning: true, message: message}} =
               Replication.evaluate(primary([walsender(%{})], slots), settings())

      assert message ==
               ~s(Warning: 1 standby streaming, max lag 0.0 s \(0 B\); ) <>
                 ~s(inactive replication slot "old_replica" retains 5.0 GB of WAL; ) <>
                 ~s(replication slot "unused" is inactive)
    end
  end

  test "format_bytes/1" do
    assert Replication.format_bytes(0) == "0 B"
    assert Replication.format_bytes(1023) == "1023 B"
    assert Replication.format_bytes(1024) == "1.0 kB"
    assert Replication.format_bytes(1_572_864) == "1.5 MB"
    assert Replication.format_bytes(3 * 1024 ** 5) == "3072.0 TB"
  end
end
