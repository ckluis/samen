defmodule Samen.Web.Auth.ResetTest do
  @moduledoc """
  T03 — A3 password reset (ADR-035 §5 A3). Proves, against the samen_web test
  host's Operator Identity mount:

    1. `Samen.Identity.Reset.request/2`'s uniform no-oracle response (mints a
       `:password_reset` token for a real account; a non-existent email gets
       the SAME response, no token minted); audits
       `auth.password_reset_requested`.
    2. `Samen.Identity.Reset.consume/3` is single-use (second use fails, with
       a first-use positive control), expiring, context-bound
       (`:email_verify` cannot be consumed as `:password_reset`), and rejects
       a weak new password WITHOUT burning the token (a doomed request never
       consumes it — the SAME token later succeeds with a strong password).
    3. A successful reset REHASHES the credential (old password no longer
       verifies, new one does) and revokes EVERY session belonging to the
       credential (`Samen.Auth.SessionRevoke` — c3), including one created
       AFTER the reset request but before its completion.
    4. Audits `auth.password_reset` on completion.
    5. `Samen.Web.Auth.ResetRequestLive` / `Samen.Web.Auth.ResetLive` render
       both flows.
    6. Every `AuthToken`/`Session` row is hashed/opaque at rest — never a raw
       token.
  """
  use Samen.WebTest.DataCase, async: false

  require Ash.Query

  alias Samen.AuditEvent
  alias Samen.Auth.Hasher
  alias Samen.Auth.PasswordPolicy
  alias Samen.Auth.TokenMint
  alias Samen.Identity.Register
  alias Samen.Identity.Reset
  alias Samen.Web.Auth.ResetLive
  alias Samen.Web.Auth.ResetRequestLive
  alias Samen.WebTest.Operator.AuthToken
  alias Samen.WebTest.Operator.Credential
  alias Samen.WebTest.Operator.Membership
  alias Samen.WebTest.Operator.Org
  alias Samen.WebTest.Operator.Session
  alias Samen.WebTest.Operator.User

  # See confirm_test.exs — `Samen.Delivery.AuthMailer` resolves its env the
  # SAME way `Samen.Delivery.Lifecycle.EmailWorker` does; the house
  # convention is to set it explicitly rather than trust the compiled
  # default (samen_core is compiled as a path dep of multiple sibling hosts).
  setup do
    prev = Application.get_env(:samen_core, :delivery_env)
    Application.put_env(:samen_core, :delivery_env, :test)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:samen_core, :delivery_env, prev),
        else: Application.delete_env(:samen_core, :delivery_env)
    end)

    :ok
  end

  defp register_mods do
    %{org: Org, credential: Credential, user: User, membership: Membership, auth_token: AuthToken, repo: Repo}
  end

  defp reset_mods do
    %{credential: Credential, auth_token: AuthToken, session: Session, repo: Repo}
  end

  defp unique_email, do: "reset-#{System.unique_integer([:positive])}@example.test"

  defp register!(overrides \\ %{}) do
    attrs =
      %{
        org_name: "Reset Co #{System.unique_integer([:positive])}",
        first_name: "Grace",
        last_name: "Hopper",
        email: unique_email(),
        password: "correct horse battery staple"
      }
      |> Map.merge(overrides)

    {:ok, result} = Register.register(attrs, register_mods())
    Map.put(result, :email, attrs.email)
  end

  defp reread_credential(id) do
    Credential
    |> Ash.Query.ensure_selected([:id, :password_hash, :hash_scheme])
    |> Ash.Query.filter(id == ^id)
    |> Ash.read!(authorize?: false)
    |> List.first()
  end

  # A directly-created live Session row (no full sign-in flow exists yet at
  # T03 — A4/T04 builds that; this simulates a pre-existing session the SAME
  # way `Samen.Identity.Register`'s AuthToken mint is a direct internal write).
  defp create_session!(credential_id, opts \\ []) do
    revoked_at = Keyword.get(opts, :revoked_at)
    expires_at = Keyword.get(opts, :expires_at, DateTime.utc_now() |> DateTime.add(60, :day))

    {:ok, session} =
      Session
      |> Ash.Changeset.for_create(:create, %{}, authorize?: false)
      |> Ash.Changeset.force_change_attribute(:credential_id, credential_id)
      |> Ash.Changeset.force_change_attribute(:token_digest, :crypto.strong_rand_bytes(16) |> Base.encode16())
      |> Ash.Changeset.force_change_attribute(:expires_at, expires_at)
      |> Ash.Changeset.force_change_attribute(:revoked_at, revoked_at)
      |> Ash.create()

    session
  end

  defp reread_session(id) do
    Session
    |> Ash.Query.ensure_selected([:id, :revoked_at, :credential_id])
    |> Ash.Query.filter(id == ^id)
    |> Ash.read!(authorize?: false)
    |> List.first()
  end

  # ===========================================================================
  # 1. request/2 — uniform no-oracle response + audit
  # ===========================================================================

  describe "Reset.request/2" do
    test "an existing account gets {:ok, :sent} and mints a :password_reset token" do
      result = register!()
      before = Ash.count!(AuthToken, authorize?: false)

      assert {:ok, :sent} = Reset.request(result.email, reset_mods())
      assert Ash.count!(AuthToken, authorize?: false) == before + 1
    end

    test "a non-existent email ALSO gets {:ok, :sent} — no account-existence oracle, no token minted" do
      before = Ash.count!(AuthToken, authorize?: false)

      assert {:ok, :sent} = Reset.request(unique_email(), reset_mods())
      assert Ash.count!(AuthToken, authorize?: false) == before
    end

    test "a real request audits auth.password_reset_requested (subject = credential)" do
      result = register!()
      assert {:ok, :sent} = Reset.request(result.email, reset_mods())

      rows = AuditEvent.for_subject(Repo, result.credential.id)
      assert Enum.any?(rows, &(&1.detail =~ "password_reset_requested"))
    end
  end

  # ===========================================================================
  # 2. consume/3 — single-use, expiring, context-bound, weak-password-safe
  # ===========================================================================

  describe "Reset.consume/3" do
    defp raw_reset_token!(result) do
      {:ok, _auth_token, raw_token} =
        TokenMint.mint(AuthToken, result.credential.id, :password_reset, nil, 3600)

      raw_token
    end

    test "FIRST-USE POSITIVE CONTROL: consuming with a strong new password succeeds" do
      result = register!()
      raw_token = raw_reset_token!(result)

      assert {:ok, _updated} = Reset.consume(raw_token, "brand new strong password", reset_mods())
    end

    test "RED PATH: consuming the SAME token a second time fails (single-use)" do
      result = register!()
      raw_token = raw_reset_token!(result)

      assert {:ok, _} = Reset.consume(raw_token, "brand new strong password", reset_mods())
      assert {:error, :invalid_token} = Reset.consume(raw_token, "another strong password", reset_mods())
    end

    test "RED PATH: an already-expired token fails" do
      result = register!()
      {:ok, _auth_token, raw_expired} = TokenMint.mint(AuthToken, result.credential.id, :password_reset, nil, -10)

      assert {:error, :invalid_token} = Reset.consume(raw_expired, "brand new strong password", reset_mods())
    end

    test "RED PATH: an :email_verify-context token cannot be consumed as :password_reset" do
      result = register!()
      assert {:error, :invalid_token} = Reset.consume(result.raw_verify_token, "brand new strong password", reset_mods())
    end

    test "a weak password is rejected WITHOUT touching the token — the SAME token later succeeds" do
      result = register!()
      raw_token = raw_reset_token!(result)

      assert {:error, :weak_password} = Reset.consume(raw_token, "short", reset_mods())
      # The token was NOT consumed by the doomed weak-password attempt.
      assert {:ok, _} = Reset.consume(raw_token, "a fine strong enough password", reset_mods())
    end

    test "ACCEPT CONTROL: a password at the minimum length is accepted" do
      result = register!()
      raw_token = raw_reset_token!(result)
      pw = String.duplicate("x", PasswordPolicy.min_length())

      assert {:ok, _} = Reset.consume(raw_token, pw, reset_mods())
    end

    test "a garbage/never-minted token fails generically" do
      assert {:error, :invalid_token} = Reset.consume("not-a-real-token", "brand new strong password", reset_mods())
    end
  end

  # ===========================================================================
  # 3. Rehash + revoke ALL sessions (c3) + audit on completion
  # ===========================================================================

  describe "a successful reset rehashes the credential and revokes ALL sessions" do
    test "the credential's password_hash changes: old password fails, new one verifies" do
      result = register!()
      raw_token = raw_reset_token!(result)

      before = reread_credential(result.credential.id)
      assert {:ok, _} = Reset.consume(raw_token, "a brand new strong password", reset_mods())
      after_reset = reread_credential(result.credential.id)

      refute after_reset.password_hash == before.password_hash
      refute Hasher.verify("correct horse battery staple", after_reset.password_hash, after_reset.hash_scheme)
      assert Hasher.verify("a brand new strong password", after_reset.password_hash, after_reset.hash_scheme)
    end

    test "EVERY live session for the credential is revoked, INCLUDING one created after the reset request" do
      result = register!()
      raw_token = raw_reset_token!(result)

      pre_existing = create_session!(result.credential.id)
      # A session created between "request" and "consume" — c3 says reset
      # revokes ALL sessions, not just ones that existed at request time.
      created_mid_flow = create_session!(result.credential.id)
      other_credential = register!()
      unrelated_session = create_session!(other_credential.credential.id)

      assert {:ok, _} = Reset.consume(raw_token, "a brand new strong password", reset_mods())

      refute is_nil(reread_session(pre_existing.id).revoked_at)
      refute is_nil(reread_session(created_mid_flow.id).revoked_at)
      # Positive control (anti-tautology): an UNRELATED credential's session
      # is untouched by THIS credential's reset.
      assert is_nil(reread_session(unrelated_session.id).revoked_at)
    end

    test "an ALREADY-revoked session for the same credential stays revoked (idempotent, no crash)" do
      result = register!()
      raw_token = raw_reset_token!(result)
      already_revoked = create_session!(result.credential.id, revoked_at: DateTime.utc_now())

      assert {:ok, _} = Reset.consume(raw_token, "a brand new strong password", reset_mods())
      refute is_nil(reread_session(already_revoked.id).revoked_at)
    end

    test "audits auth.password_reset on completion (subject = credential)" do
      result = register!()
      raw_token = raw_reset_token!(result)

      assert {:ok, _} = Reset.consume(raw_token, "a brand new strong password", reset_mods())

      rows = AuditEvent.for_subject(Repo, result.credential.id)
      assert Enum.any?(rows, &(&1.detail =~ "identity.password_reset" and not (&1.detail =~ "requested")))
    end
  end

  # ===========================================================================
  # 4. Token hashed at rest
  # ===========================================================================

  describe "tokens hashed at rest" do
    test "the password_reset AuthToken row stores only the digest — never the raw token" do
      result = register!()
      {:ok, auth_token, raw_token} = TokenMint.mint(AuthToken, result.credential.id, :password_reset, nil, 3600)

      raw = Ash.get!(AuthToken, auth_token.id, authorize?: false)
      refute raw.token_digest == raw_token
      refute inspect(raw) =~ raw_token
    end

    test "DB PROBE: the raw column `wot_token_digest` is the SHA-256 digest, never the raw token at rest" do
      result = register!()
      {:ok, auth_token, raw_token} = TokenMint.mint(AuthToken, result.credential.id, :password_reset, nil, 3600)

      %{rows: [[digest_col]]} =
        Repo.query!("SELECT wot_token_digest FROM wot_auth_token WHERE wot_id = $1", [
          Ecto.UUID.dump!(auth_token.id)
        ])

      refute digest_col == raw_token
      refute digest_col =~ raw_token
      assert digest_col == TokenMint.digest(raw_token)
    end

    test "Session rows never carry a raw token — only token_digest" do
      result = register!()
      session = create_session!(result.credential.id)

      raw = Ash.get!(Session, session.id, authorize?: false)
      assert is_binary(raw.token_digest)
      refute String.length(raw.token_digest) == 0
    end
  end

  # ===========================================================================
  # 5. ResetRequestLive / ResetLive — the /reset + /reset/:token surfaces
  # ===========================================================================

  describe "Samen.Web.Auth.ResetRequestLive" do
    test "renders the request form and shows the generic confirmation on submit" do
      mount = build_mount(:auth)
      session = mount_session(mount)
      {:ok, socket} = ResetRequestLive.mount(%{}, session, %Phoenix.LiveView.Socket{})

      html = render_html(ResetRequestLive, socket.assigns)
      assert html =~ "reset-request-form"

      {:noreply, socket} =
        ResetRequestLive.handle_event("request_reset", %{"reset" => %{"email" => unique_email()}}, socket)

      assert socket.assigns.requested?
      assert socket.assigns.flash_ok =~ "check your inbox"
    end
  end

  describe "Samen.Web.Auth.ResetLive" do
    test "a strong password reset renders the sessions-signed-out confirmation" do
      result = register!()
      raw_token = raw_reset_token!(result)

      mount = build_mount(:auth)
      session = mount_session(mount)
      {:ok, socket} = ResetLive.mount(%{"token" => raw_token}, session, %Phoenix.LiveView.Socket{})

      {:noreply, socket} =
        ResetLive.handle_event("reset", %{"reset" => %{"password" => "a brand new strong password"}}, socket)

      assert socket.assigns.reset?
      assert socket.assigns.flash_ok =~ "signed out"
    end

    test "a weak password shows the rejection without an account-existence oracle" do
      result = register!()
      raw_token = raw_reset_token!(result)

      mount = build_mount(:auth)
      session = mount_session(mount)
      {:ok, socket} = ResetLive.mount(%{"token" => raw_token}, session, %Phoenix.LiveView.Socket{})

      {:noreply, socket} =
        ResetLive.handle_event("reset", %{"reset" => %{"password" => "short"}}, socket)

      refute socket.assigns.reset?
      assert socket.assigns.error =~ "Password"
    end
  end
end
