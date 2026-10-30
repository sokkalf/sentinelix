defmodule Sentinelix.ReleaseTest do
  use Sentinelix.DataCase, async: true

  import ExUnit.CaptureIO

  alias Sentinelix.{Accounts, Release}

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
