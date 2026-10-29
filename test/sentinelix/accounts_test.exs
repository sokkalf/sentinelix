defmodule Sentinelix.AccountsTest do
  use Sentinelix.DataCase, async: true

  import Sentinelix.AccountsFixtures

  alias Sentinelix.Accounts
  alias Sentinelix.Accounts.{User, UserToken}

  describe "upsert_oidc_user/1" do
    @attrs %{
      oidc_issuer: "https://idp.example.com",
      oidc_subject: "abc",
      email: "a@example.com",
      name: "A"
    }

    test "creates a user" do
      assert {:ok, %User{} = user} = Accounts.upsert_oidc_user(@attrs)
      assert user.oidc_subject == "abc"
      assert user.email == "a@example.com"
      assert user.last_login_at
      refute User.local?(user)
    end

    test "updates the user matched by issuer and subject" do
      {:ok, user} = Accounts.upsert_oidc_user(@attrs)

      {:ok, updated} =
        Accounts.upsert_oidc_user(%{@attrs | email: "new@example.com", name: nil})

      assert updated.id == user.id
      assert updated.email == "new@example.com"
      assert updated.name == nil
      assert Repo.aggregate(User, :count) == 1
    end

    test "the same subject at another issuer is another user" do
      {:ok, user} = Accounts.upsert_oidc_user(@attrs)
      {:ok, other} = Accounts.upsert_oidc_user(%{@attrs | oidc_issuer: "https://other.example"})

      assert user.id != other.id
    end

    test "requires issuer and subject" do
      assert {:error, changeset} = Accounts.upsert_oidc_user(%{email: "a@example.com"})

      assert %{oidc_issuer: ["can't be blank"], oidc_subject: ["can't be blank"]} =
               errors_on(changeset)
    end
  end

  describe "get_user_by_oidc_identity/2" do
    test "finds the user" do
      user = oidc_user_fixture()
      assert Accounts.get_user_by_oidc_identity(user.oidc_issuer, user.oidc_subject).id == user.id
      refute Accounts.get_user_by_oidc_identity(user.oidc_issuer, "unknown")
    end
  end

  describe "create_local_user/1" do
    test "validates email and password" do
      {:error, changeset} = Accounts.create_local_user(%{email: "not valid", password: "short"})

      assert %{
               email: ["must have the @ sign and no spaces"],
               password: ["should be at least 12 character(s)"]
             } = errors_on(changeset)
    end

    test "hashes the password and downcases the email" do
      {:ok, user} =
        Accounts.create_local_user(%{
          email: " Admin@Example.com ",
          password: valid_user_password()
        })

      assert user.email == "admin@example.com"
      assert user.hashed_password
      refute user.password
      assert User.local?(user)
    end

    test "emails are unique (case-insensitive)" do
      user_fixture(%{email: "admin@example.com"})

      {:error, changeset} =
        Accounts.create_local_user(%{email: "ADMIN@example.com", password: valid_user_password()})

      assert "has already been taken" in errors_on(changeset).email
    end
  end

  describe "get_local_user_by_email_and_password/2" do
    test "returns the user for a valid password" do
      user = user_fixture()

      assert Accounts.get_local_user_by_email_and_password(user.email, valid_user_password()).id ==
               user.id
    end

    test "returns nil for wrong passwords, unknown emails and OIDC users" do
      user = user_fixture()
      oidc_user = oidc_user_fixture()

      refute Accounts.get_local_user_by_email_and_password(user.email, "wrong password!")
      refute Accounts.get_local_user_by_email_and_password("x@example.com", valid_user_password())
      refute Accounts.get_local_user_by_email_and_password(oidc_user.email, "")
    end
  end

  describe "create_or_reset_local_user/1" do
    test "creates a user, then resets its password and revokes its sessions" do
      assert {:ok, :created, user} =
               Accounts.create_or_reset_local_user(%{
                 email: "admin@example.com",
                 password: valid_user_password()
               })

      token = Accounts.generate_user_session_token(user)

      assert {:ok, :updated, updated} =
               Accounts.create_or_reset_local_user(%{
                 email: "Admin@example.com",
                 password: "another long password"
               })

      assert updated.id == user.id
      assert Accounts.get_local_user_by_email_and_password(user.email, "another long password")
      refute Accounts.get_user_by_session_token(token)
    end

    test "returns validation errors" do
      user_fixture(%{email: "admin@example.com"})

      assert {:error, changeset} =
               Accounts.create_or_reset_local_user(%{email: "admin@example.com", password: "x"})

      assert errors_on(changeset).password
    end
  end

  describe "ensure_bootstrap_admin/1" do
    test "creates the admin once" do
      config = [email: "boot@example.com", password: valid_user_password()]

      assert {:ok, :created, user} = Accounts.ensure_bootstrap_admin(config)

      assert {:ok, :exists, same} =
               Accounts.ensure_bootstrap_admin(Keyword.put(config, :password, "changed password"))

      assert same.id == user.id
      # the password is not changed by the env vars
      assert Accounts.get_local_user_by_email_and_password(user.email, valid_user_password())
    end

    test "skips without email or password" do
      assert Accounts.ensure_bootstrap_admin(nil) == :skip
      assert Accounts.ensure_bootstrap_admin(email: "boot@example.com") == :skip
      assert Accounts.ensure_bootstrap_admin(email: "", password: "") == :skip
      refute Accounts.local_users_exist?()
    end

    @tag :capture_log
    test "returns errors for invalid input" do
      assert {:error, _} =
               Accounts.ensure_bootstrap_admin(email: "boot@example.com", password: "x")
    end
  end

  describe "session tokens" do
    setup do
      %{user: user_fixture()}
    end

    test "generate and look up", %{user: user} do
      token = Accounts.generate_user_session_token(user)
      assert Accounts.get_user_by_session_token(token).id == user.id
      assert %UserToken{context: "session"} = Repo.get_by(UserToken, token: token)
    end

    test "do not work after expiry", %{user: user} do
      token = Accounts.generate_user_session_token(user)
      offset_user_token(token, -UserToken.session_validity_in_days(), :day)
      refute Accounts.get_user_by_session_token(token)

      assert Accounts.delete_expired_session_tokens() == 1
    end

    test "delete returns the deleted token", %{user: user} do
      token = Accounts.generate_user_session_token(user, oidc_id_token: "id.token")

      assert %UserToken{oidc_id_token: "id.token"} = Accounts.delete_user_session_token(token)
      refute Accounts.get_user_by_session_token(token)
      assert Accounts.delete_user_session_token(token) == nil
    end

    test "delete all sessions of a user", %{user: user} do
      other = user_fixture()
      tokens = for _ <- 1..2, do: Accounts.generate_user_session_token(user)
      other_token = Accounts.generate_user_session_token(other)

      deleted = Accounts.delete_all_user_session_tokens(user)

      assert Enum.sort(Enum.map(deleted, & &1.token)) == Enum.sort(tokens)
      assert Accounts.get_user_by_session_token(other_token)
    end
  end

  test "touch_last_login/1 sets last_login_at" do
    user = user_fixture()
    refute user.last_login_at
    assert Accounts.touch_last_login(user).last_login_at
  end
end
