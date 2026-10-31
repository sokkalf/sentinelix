defmodule Sentinelix.ReleaseTest do
  use Sentinelix.DataCase, async: true

  import ExUnit.CaptureIO

  alias Sentinelix.{Accounts, Release}

  describe "export_monitors/1 and import_monitors/2" do
    @describetag :tmp_dir

    import Sentinelix.MonitoringFixtures

    test "export to a file and import it back like bin/import_monitors", %{tmp_dir: dir} do
      monitor_fixture(:ping, %{name: "Router"})
      Release.export_monitors(["--output", Path.join(dir, "monitors.yaml")])
      assert File.read!(Path.join(dir, "monitors.yaml")) =~ "name: Router"
      assert capture_io(fn -> Release.export_monitors([]) end) =~ "name: Router"

      Sentinelix.Repo.delete_all(Sentinelix.Monitoring.Monitor)

      # The expression bin/import_monitors builds: Base64 arguments (with a
      # trailing comma) and working directory.
      encode = &Base.encode64/1

      expression =
        ~s|Sentinelix.Release.import_monitors(["#{encode.("monitors.yaml")}", "#{encode.("--dry-run")}", ], "#{encode.(dir)}")|

      assert capture_io(fn -> Code.eval_string(expression) end) =~ "1 to create"
      assert Sentinelix.Monitoring.list_monitors() == []

      assert capture_io(fn ->
               Release.import_monitors([encode.("monitors.yaml")], encode.(dir))
             end) =~
               "Created 1"

      assert [%{name: "Router"}] = Sentinelix.Monitoring.list_monitors()
    end

    test "raise on errors" do
      assert_raise ArgumentError, ~r/Invalid selector/, fn ->
        Release.export_monitors(["--selector", "env="])
      end

      assert_raise ArgumentError, ~r/Could not read/, fn ->
        Release.import_monitors([Base.encode64("missing.yaml")], Base.encode64("/nonexistent"))
      end
    end
  end

  describe "create_admin/1" do
    test "creates a local admin and resets its password" do
      assert capture_io(fn ->
               assert {:ok, :created, _user} =
                        Release.create_admin(
                          email: "release-admin@example.com",
                          password: "long-enough-password"
                        )
             end) =~ "Created local admin release-admin@example.com"

      assert Accounts.get_local_user_by_email_and_password(
               "release-admin@example.com",
               "long-enough-password"
             )

      assert capture_io(fn ->
               assert {:ok, :updated, _user} =
                        Release.create_admin(
                          email: "release-admin@example.com",
                          password: "another-long-password"
                        )
             end) =~ "Reset password of local admin release-admin@example.com"

      assert Accounts.get_local_user_by_email_and_password(
               "release-admin@example.com",
               "another-long-password"
             )
    end

    test "raises on invalid input" do
      assert_raise ArgumentError, ~r/should be at least 12/, fn ->
        Release.create_admin(email: "release-admin@example.com", password: "short")
      end
    end

    test "requires an email and a password" do
      assert_raise ArgumentError, ~r/ADMIN_EMAIL and ADMIN_PASSWORD/, fn ->
        Release.create_admin(email: "release-admin@example.com", password: " ")
      end
    end
  end
end
