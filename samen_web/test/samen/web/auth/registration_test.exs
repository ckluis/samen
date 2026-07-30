defmodule Samen.Web.Auth.RegistrationTest do
  @moduledoc """
  T02 — A1 self-serve registration (ADR-035 §5 A1). Proves, against the
  samen_web test host's Operator Identity mount (`Samen.WebTest.Operator`, the
  ONLY Identity mount in this test host — ADR-010 §8.2):

    1. `Samen.Identity.Register.register/2` creates Org + Credential + User +
       owner Membership + the `:email_verify` AuthToken atomically; a mid-txn
       failure leaves ZERO rows for the attempt (the atomicity assert).
    2. The MaskingCase 3-proof on the registered User's `full_name`/`emails`
       (tenant clear; operator masked `••••`, no `vt_*` in the resolved value;
       sabotage twin) — INV-1.
    3. The password is hashed (never plaintext at rest); a weak password is
       rejected BEFORE any row is created, with an accept-control proving a
       valid password is NOT rejected.
    4. `Samen.Web.Auth.RegistrationLive` renders the form and, on submit, drives
       the SAME registration path end to end.
  """
  use Samen.WebTest.DataCase, async: false
  use Samen.MaskingCase

  require Ash.Query

  alias Samen.Auth.BlindIndex
  alias Samen.Auth.Hasher
  alias Samen.Auth.PasswordPolicy
  alias Samen.Identity.Register
  alias Samen.Web.Auth.RegistrationLive
  alias Samen.WebTest.Operator.AuthToken
  alias Samen.WebTest.Operator.Credential
  alias Samen.WebTest.Operator.Membership
  alias Samen.WebTest.Operator.Org
  alias Samen.WebTest.Operator.User

  defp mods do
    %{org: Org, credential: Credential, user: User, membership: Membership, auth_token: AuthToken, repo: Repo}
  end

  defp unique_email, do: "reg-#{System.unique_integer([:positive])}@example.test"

  defp valid_attrs(overrides \\ %{}) do
    %{
      org_name: "Acme Inc #{System.unique_integer([:positive])}",
      first_name: "Ada",
      last_name: "Lovelace",
      email: unique_email(),
      password: "correct horse battery staple"
    }
    |> Map.merge(overrides)
  end

  defp counts do
    %{
      org: Ash.count!(Org, authorize?: false),
      credential: Ash.count!(Credential, authorize?: false),
      user: Ash.count!(User, authorize?: false),
      membership: Ash.count!(Membership, authorize?: false),
      auth_token: Ash.count!(AuthToken, authorize?: false)
    }
  end

  defp find_org_by_name(name) do
    Org |> Ash.Query.filter(name == ^name) |> Ash.read!(authorize?: false)
  end

  defp find_credential_by_email(email) do
    {:ok, bidx} = BlindIndex.compute(email)
    Credential |> Ash.Query.filter(email_bidx == ^bidx) |> Ash.read!(authorize?: false)
  end

  # This host's default `:read` (like `:create`) does not auto-select every
  # attribute — `org_id`/timestamps/pii_attributes need an explicit select (the
  # SAME `ensure_selected` discipline `Samen.Web.Settings.Reads.get_user/3`
  # uses). Re-reading fresh (rather than trusting the create-return struct)
  # also proves the values were actually PERSISTED, not merely held in memory.
  defp reread_membership(id) do
    Membership
    |> Ash.Query.ensure_selected([:id, :role, :status, :org_id, :user_id])
    |> Ash.Query.filter(id == ^id)
    |> Ash.read!(authorize?: false)
    |> List.first()
  end

  defp reread_user(id) do
    User
    |> Ash.Query.ensure_selected([:id, :handle, :status, :org_id, :credential_id, :full_name, :emails])
    |> Ash.Query.filter(id == ^id)
    |> Ash.read!(authorize?: false)
    |> List.first()
  end

  # ===========================================================================
  # 1. ATOMICITY — Org+User+owner Membership (+Credential+AuthToken), one txn
  # ===========================================================================

  describe "A1 atomic registration" do
    test "creates Org + Credential + User + owner Membership + email_verify AuthToken together" do
      attrs = valid_attrs()

      assert {:ok, result} = Register.register(attrs, mods())
      assert result.status == :registered

      assert result.org.name == attrs.org_name
      assert result.org.plan == "free"

      assert result.membership.role == :owner

      # Re-read fresh (with an explicit select) to prove the FK linkage was
      # actually PERSISTED, not merely assembled in memory.
      membership = reread_membership(result.membership.id)
      assert membership.org_id == result.org.id
      assert membership.user_id == result.user.id

      user = reread_user(result.user.id)
      assert user.org_id == result.org.id
      assert user.credential_id == result.credential.id

      assert result.auth_token.context == :email_verify
      assert result.auth_token.credential_id == result.credential.id
      assert is_nil(result.auth_token.consumed_at)
      refute is_nil(result.auth_token.expires_at)

      # The raw verify token is handed back for the (later) A2 dispatch, but
      # what is PERSISTED is only its digest — never the raw token itself.
      assert is_binary(result.raw_verify_token)
      refute result.auth_token.token_digest == result.raw_verify_token
      # Never plaintext-of-the-email either (credential-class column, INV-1).
      refute result.credential.email_bidx == attrs.email
    end

    test "duplicate email returns the SAME generic response and creates NO second account" do
      attrs = valid_attrs()
      assert {:ok, %{status: :registered}} = Register.register(attrs, mods())
      before = counts()

      # A different org name / same email — must not create a second Org/Credential.
      dup_attrs = valid_attrs(%{email: attrs.email})
      assert {:ok, %{status: :duplicate}} = Register.register(dup_attrs, mods())

      assert counts() == before
      assert find_org_by_name(dup_attrs.org_name) == []
    end

    for step <- [:org, :credential, :user, :membership] do
      @step step

      test "RED PATH: an injected failure right after :#{step} rolls the WHOLE attempt back" do
        attrs = valid_attrs()
        before = counts()

        assert {:error, :injected_test_failure} =
                 Register.register(attrs, mods(), inject_failure_after: @step)

        # No partial commit: every counter is back to its pre-attempt value.
        assert counts() == before

        # Direct non-existence proof (not just count parity): neither the Org
        # nor the Credential this attempt would have created exists.
        assert find_org_by_name(attrs.org_name) == []
        assert find_credential_by_email(attrs.email) == []
      end
    end

    test "POSITIVE CONTROL: the identical attrs with NO injected failure DO commit (anti-tautology)" do
      attrs = valid_attrs()
      before = counts()

      assert {:ok, %{status: :registered}} = Register.register(attrs, mods())

      after_counts = counts()
      assert after_counts.org == before.org + 1
      assert after_counts.credential == before.credential + 1
      assert after_counts.user == before.user + 1
      assert after_counts.membership == before.membership + 1
      assert after_counts.auth_token == before.auth_token + 1
      assert find_org_by_name(attrs.org_name) != []
    end
  end

  # ===========================================================================
  # 2. MASKING 3-PROOF — the registered User's full_name/emails (INV-1)
  # ===========================================================================

  describe "MaskingCase 3-proof on the registered User's PII" do
    test "tenant plane CLEAR ∧ operator plane MASKED ∧ sabotage twin (anti-tautology)" do
      attrs = valid_attrs(%{first_name: "Katherine", last_name: "Johnson"})
      assert {:ok, %{user: user}} = Register.register(attrs, mods())

      raw = reread_user(user.id)
      expected_name = %Samen.Type.FullName{first: "Katherine", last: "Johnson"}

      # GREEN — tenant plane resolves clear. A revealed composite arrives in
      # its JSON-serialized vault form (the established ProfileLive
      # `decode_composite/1` posture) — decode it to compare.
      tenant = resolve_on_plane(raw, User, :tenant, repo: Repo)
      refute match?(%Samen.Masked{}, tenant.full_name)
      decoded_name = Jason.decode!(tenant.full_name)
      assert decoded_name["first"] == "Katherine"
      assert decoded_name["last"] == "Johnson"

      refute match?(%Samen.Masked{}, tenant.emails)
      decoded_emails = Jason.decode!(tenant.emails)
      assert [%{"address" => addr}] = decoded_emails
      assert addr == attrs.email

      # RED — operator (impersonation, no grant) resolves masked: •••• only,
      # never the plaintext, never a vt_* vault token.
      operator = resolve_on_plane(raw, User, :operator, repo: Repo)
      assert_plane_masked!(operator.full_name, expected_name)
      assert_plane_masked!(operator.emails)
      refute to_string(operator.full_name) =~ "Katherine"
      refute to_string(operator.emails) =~ attrs.email

      # SABOTAGE TWIN — the SAME record, flipped to tenant plane, DOES leak the
      # plaintext: proves the operator `refute` scans above are refutable (a
      # real leak would be caught), not vacuously true.
      assert_leak_detected!(inspect(tenant.full_name), "Katherine")
      assert_leak_detected!(inspect(tenant.emails), attrs.email)
    end

    test "the domain row stores vt_ tokens, never the plaintext name/email" do
      attrs = valid_attrs(%{first_name: "Radia", last_name: "Perlman"})
      assert {:ok, %{user: user}} = Register.register(attrs, mods())

      %{rows: [[raw_name, raw_emails]]} =
        Repo.query!(
          "SELECT wou_full_name, wou_emails FROM wou_user WHERE wou_id = $1",
          [Ecto.UUID.dump!(user.id)]
        )

      assert String.starts_with?(raw_name, "vt_")
      assert String.starts_with?(raw_emails, "vt_")
      refute raw_name =~ "Radia"
      refute raw_emails =~ attrs.email
    end
  end

  # ===========================================================================
  # 3. PASSWORD HASHING (ADR-035 §4.4) + weak-password rejection
  # ===========================================================================

  describe "password hashing" do
    test "the stored hash is never the plaintext, verifies under Samen.Auth.Hasher" do
      attrs = valid_attrs(%{password: "s3cure-enough-password"})
      assert {:ok, %{credential: credential}} = Register.register(attrs, mods())

      raw =
        Credential
        |> Ash.Query.filter(id == ^credential.id)
        |> Ash.read!(authorize?: false)
        |> List.first()

      refute raw.password_hash == attrs.password
      refute raw.password_hash =~ attrs.password
      assert raw.hash_scheme == "pbkdf2-sha256$600000"
      assert Hasher.verify(attrs.password, raw.password_hash, raw.hash_scheme)
      refute Hasher.verify("wrong-password", raw.password_hash, raw.hash_scheme)
    end

    test "RED PATH: a weak (too-short) password is rejected BEFORE any row is created" do
      attrs = valid_attrs(%{password: "short1"})
      before = counts()

      assert {:error, :weak_password} = Register.register(attrs, mods())

      assert counts() == before
      assert find_org_by_name(attrs.org_name) == []
    end

    test "ACCEPT CONTROL: a password at the minimum length is accepted" do
      attrs = valid_attrs(%{password: String.duplicate("x", PasswordPolicy.min_length())})
      assert {:ok, %{status: :registered}} = Register.register(attrs, mods())
    end
  end

  # ===========================================================================
  # 3b. TIMING PARITY on the duplicate-email branch (ADR-035 §4.4, addendum P2
  #     — prime orchestrator, post-T02 verification: closes the latency-based
  #     account-existence oracle the T02 verifier flagged).
  # ===========================================================================

  describe "timing parity: the duplicate-email branch burns the SAME Hasher cost as a fresh registration" do
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

    test "RED PATH (was the oracle): a FRESH registration invokes Hasher exactly once" do
      attrs = valid_attrs()
      assert {:ok, %{status: :registered}} = Register.register(attrs, mods())

      assert_received :hasher_called
      refute_received :hasher_called
    end

    test "the FIX: a DUPLICATE-email registration ALSO invokes Hasher exactly once (was: zero)" do
      attrs = valid_attrs()
      assert {:ok, %{status: :registered}} = Register.register(attrs, mods())

      # Drain the fresh registration's own hasher call before measuring the
      # duplicate attempt in isolation.
      assert_received :hasher_called
      refute_received :hasher_called

      dup_attrs = valid_attrs(%{email: attrs.email})
      assert {:ok, %{status: :duplicate}} = Register.register(dup_attrs, mods())

      # Before the P2 fix, the duplicate branch short-circuited BEFORE
      # do_register/4's Hasher.hash/1 call — zero hasher work, so a fresh
      # (available) email always paid ~100-300ms more latency than a
      # registered one, distinguishing account existence by timing even
      # though the response WORDING was identical. The fix burns an
      # equivalent throwaway hash on a fixed dummy password first.
      assert_received :hasher_called
      refute_received :hasher_called
    end
  end

  # ===========================================================================
  # 4. RegistrationLive — the /signup surface (samen_web)
  # ===========================================================================

  describe "Samen.Web.Auth.RegistrationLive" do
    test "renders the signup form (pre-actor, no org data)" do
      mount = build_mount(:auth)
      html = mount_smoke(RegistrationLive, mount)

      assert html =~ "Create your account"
      assert html =~ "registration-form"
      assert html =~ "registration-submit"
    end

    test "the rendered form carries a REAL method=post action (no native GET password leak — T110)" do
      mount = build_mount(:auth)
      html = mount_smoke(RegistrationLive, mount)

      # The escalation (persona F1): without these attrs a no-JS browser submits
      # a native GET, putting `registration[password]=…` in the URL. The form
      # MUST declare a real POST action so the credential rides the body.
      assert html =~ ~s(method="post")
      assert html =~ ~s(action="/signup")
      # And a password field is present (so the assertion is not vacuous).
      assert html =~ ~s(type="password")
    end

    test "submitting valid params arms the real browser POST (phx-trigger-action), never registering inline — T110" do
      mount = build_mount(:auth)
      session = mount_session(mount)
      {:ok, socket} = RegistrationLive.mount(%{}, session, %Phoenix.LiveView.Socket{})

      params = %{
        "org_name" => "Acme Web Co #{System.unique_integer([:positive])}",
        "first_name" => "Grace",
        "last_name" => "Hopper",
        "email" => unique_email(),
        "password" => "correct horse battery staple"
      }

      {:noreply, socket} =
        RegistrationLive.handle_event("register", %{"registration" => params}, socket)

      # The JS path validates inline then ARMS the real browser POST to
      # `AccountController.register/2`; the LiveView itself never mutates (single
      # authority — a no-JS submit hits that SAME controller). The real
      # registration is proven end-to-end in account_controller_test.exs.
      assert socket.assigns.trigger_submit
      assert socket.assigns.error == nil
      refute socket.assigns.registered?
      assert find_org_by_name(params["org_name"]) == []
    end

    test "submitting a weak password shows the inline rejection and does NOT arm the POST (no oracle wording)" do
      mount = build_mount(:auth)
      session = mount_session(mount)
      {:ok, socket} = RegistrationLive.mount(%{}, session, %Phoenix.LiveView.Socket{})

      params = %{
        "org_name" => "Weak Pw Co #{System.unique_integer([:positive])}",
        "first_name" => "Weak",
        "last_name" => "Password",
        "email" => unique_email(),
        "password" => "short"
      }

      {:noreply, socket} =
        RegistrationLive.handle_event("register", %{"registration" => params}, socket)

      refute socket.assigns.registered?
      refute socket.assigns.trigger_submit
      assert socket.assigns.error =~ "Password"
      assert find_org_by_name(params["org_name"]) == []
    end
  end
end
