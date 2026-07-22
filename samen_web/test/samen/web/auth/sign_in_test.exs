defmodule Samen.Web.Auth.SignInTest do
  @moduledoc """
  T03 (binding addendum) — ADR-035 §4.4's sign-in timing-parity dummy-verify,
  assigned to this task ("a dummy verify runs on unknown-bidx sign-in
  attempts (timing parity red test in T03)"). Proves, against the samen_web
  test host's Operator Identity mount:

    1. `Samen.Identity.SignIn.authenticate/3` correctness: right password
       succeeds; wrong password, unknown email, and a passwordless (SSO-only)
       credential all fail through the SAME generic `{:error,
       :invalid_credentials}`.
    2. The timing-parity mechanism: EVERY branch (known-wrong-password,
       unknown-email, passwordless) burns EXACTLY ONE `Samen.Auth.Hasher`
       call — no branch is a "free" early-return, so response latency cannot
       distinguish "no such account" from "wrong password."

  Full sign-in (an `Identity.Session` row, a `LoginLive`, remember-me) is
  A4's contract (T04), built ON this primitive.
  """
  use Samen.WebTest.DataCase, async: false

  require Ash.Query

  alias Samen.Identity.Register
  alias Samen.Identity.SignIn
  alias Samen.WebTest.Operator.AuthToken
  alias Samen.WebTest.Operator.Credential
  alias Samen.WebTest.Operator.Membership
  alias Samen.WebTest.Operator.Org
  alias Samen.WebTest.Operator.User

  defp register_mods do
    %{org: Org, credential: Credential, user: User, membership: Membership, auth_token: AuthToken, repo: Repo}
  end

  defp sign_in_mods, do: %{credential: Credential}

  defp unique_email, do: "signin-#{System.unique_integer([:positive])}@example.test"

  defp register!(password \\ "correct horse battery staple") do
    attrs = %{
      org_name: "SignIn Co #{System.unique_integer([:positive])}",
      first_name: "Ada",
      last_name: "Lovelace",
      email: unique_email(),
      password: password
    }

    {:ok, result} = Register.register(attrs, register_mods())

    result
    |> Map.put(:email, attrs.email)
    |> Map.put(:password, password)
  end

  defp make_passwordless!(credential_id) do
    Credential
    |> Ash.Query.filter(id == ^credential_id)
    |> Ash.read!(authorize?: false)
    |> List.first()
    |> Ash.Changeset.for_update(:update, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:password_hash, nil)
    |> Ash.Changeset.force_change_attribute(:hash_scheme, nil)
    |> Ash.update!()
  end

  # ===========================================================================
  # 1. Correctness
  # ===========================================================================

  describe "SignIn.authenticate/3 — correctness" do
    test "POSITIVE CONTROL: the correct email + password succeeds" do
      result = register!()
      assert {:ok, credential} = SignIn.authenticate(result.email, result.password, sign_in_mods())
      assert credential.id == result.credential.id
    end

    test "RED PATH: the wrong password fails" do
      result = register!()
      assert {:error, :invalid_credentials} = SignIn.authenticate(result.email, "totally-wrong-password", sign_in_mods())
    end

    test "RED PATH: an unknown email fails" do
      assert {:error, :invalid_credentials} =
               SignIn.authenticate(unique_email(), "whatever-password", sign_in_mods())
    end

    test "RED PATH: a passwordless (SSO-only, A6) credential always fails password sign-in" do
      result = register!()
      make_passwordless!(result.credential.id)

      assert {:error, :invalid_credentials} = SignIn.authenticate(result.email, result.password, sign_in_mods())
    end
  end

  # ===========================================================================
  # 2. Timing-parity mechanism proof (ADR-035 §4.4, T03 addendum)
  # ===========================================================================

  describe "timing-parity dummy-verify — every branch burns exactly one Hasher call" do
    defmodule CountingHasher do
      @moduledoc false
      @behaviour Samen.Auth.Hasher

      @impl true
      def hash(password) do
        send(self(), :hasher_called)
        Samen.Auth.Hasher.Pbkdf2.hash(password)
      end

      @impl true
      def verify(password, hash, scheme) do
        send(self(), :hasher_called)
        Samen.Auth.Hasher.Pbkdf2.verify(password, hash, scheme)
      end
    end

    setup do
      prev = Application.get_env(:samen_core, :auth_hasher)
      Application.put_env(:samen_core, :auth_hasher, CountingHasher)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:samen_core, :auth_hasher, prev),
          else: Application.delete_env(:samen_core, :auth_hasher)
      end)

      :ok
    end

    # `register!/1` itself burns one Hasher.hash/1 call (A1 signup password
    # hashing) — drain that BEFORE measuring `SignIn.authenticate/3` in
    # isolation, so each test below counts ONLY the sign-in attempt's cost.
    defp drain_hasher_calls do
      receive do
        :hasher_called -> drain_hasher_calls()
      after
        0 -> :ok
      end
    end

    test "POSITIVE CONTROL: a correct sign-in burns exactly one Hasher call" do
      result = register!()
      drain_hasher_calls()

      SignIn.authenticate(result.email, result.password, sign_in_mods())

      assert_received :hasher_called
      refute_received :hasher_called
    end

    test "a KNOWN credential's wrong-password attempt burns exactly one Hasher call" do
      result = register!()
      drain_hasher_calls()

      SignIn.authenticate(result.email, "wrong-password-xyz", sign_in_mods())

      assert_received :hasher_called
      refute_received :hasher_called
    end

    test "the FIX: an UNKNOWN email's attempt ALSO burns exactly one Hasher call (was: zero — the oracle)" do
      SignIn.authenticate(unique_email(), "whatever-password", sign_in_mods())

      # Before this discipline, an unknown bidx would return immediately with
      # NO Hasher work, so a known email always paid ~100-300ms more latency
      # than an unknown one — an account-existence oracle at the timing
      # plane, even with identical response wording/shape.
      assert_received :hasher_called
      refute_received :hasher_called
    end

    test "a passwordless credential's attempt ALSO burns exactly one Hasher call" do
      result = register!()
      make_passwordless!(result.credential.id)
      drain_hasher_calls()

      SignIn.authenticate(result.email, result.password, sign_in_mods())

      assert_received :hasher_called
      refute_received :hasher_called
    end
  end
end
