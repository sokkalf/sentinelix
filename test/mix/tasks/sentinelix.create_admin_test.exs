defmodule Mix.Tasks.Sentinelix.CreateAdminTest do
  use Sentinelix.DataCase, async: false

  alias Mix.Tasks.Sentinelix.CreateAdmin
  alias Sentinelix.Accounts

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
  end

  test "creates a local admin and resets its password" do
    CreateAdmin.run(~w(--email admin@example.com --password long-enough-password))
    assert_received {:mix_shell, :info, ["Created local admin admin@example.com"]}

    assert Accounts.get_local_user_by_email_and_password(
             "admin@example.com",
             "long-enough-password"
           )

    CreateAdmin.run(~w(--email admin@example.com --password another-long-password))
    assert_received {:mix_shell, :info, ["Reset password of local admin admin@example.com"]}

    assert Accounts.get_local_user_by_email_and_password(
             "admin@example.com",
             "another-long-password"
           )
  end

  test "fails on invalid input" do
    assert_raise Mix.Error, ~r/should be at least 12/, fn ->
      CreateAdmin.run(~w(--email admin@example.com --password short))
    end
  end
end
