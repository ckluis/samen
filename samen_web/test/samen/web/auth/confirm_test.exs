defmodule Samen.Web.Auth.ConfirmTest do
  @moduledoc """
  T03 — A2 email verification (ADR-035 §5 A2). Proves, against the samen_web
  test host's Operator Identity mount:

    1. `Samen.Identity.Confirm.consume/2` is single-use (a second consume of
       the SAME raw token fails, with a first-use positive control),
       expiring (an already-expired token fails), and context-bound (a
       `:password_reset` token cannot be consumed as `:email_verify`).
    2. `Samen.Policy.Verified` capability-limits an unverified credential:
       denied the invite capability a verified credential holds (real actor,
       real policy evaluation — not `authorize?: false`).
    3. `resend/2`'s uniform no-oracle response, dispatched via
       `Samen.Delivery.AuthMailer` (captured by `LocalSink` in `:test`).
    4. `Samen.Web.Auth.ConfirmLive` renders both outcomes.
    5. Every `AuthToken` row is hashed at rest — never the raw token.
  """
  use Samen.WebTest.DataCase, async: false

  require Ash.Query

  alias Samen.AuditEvent
  alias Samen.Auth.BlindIndex
  alias Samen.Auth.TokenConsume
  alias Samen.Auth.TokenMint
  alias Samen.Identity.Confirm
  alias Samen.Identity.Register
  alias Samen.Web.Auth.ConfirmLive
  alias Samen.WebTest.Operator.AuthToken
  alias Samen.WebTest.Operator.Credential
  alias Samen.WebTest.Operator.Invitation
  alias Samen.WebTest.Operator.Membership
  alias Samen.WebTest.Operator.Org
  alias Samen.WebTest.Operator.User

  # `Samen.Delivery.AuthMailer` resolves its env exactly like
  # `Samen.Delivery.Lifecycle.EmailWorker` does — `Application.get_env(:samen_core,
  # :delivery_env, @compiled_env)`. The house convention (see
  # `samen_core/test/delivery_lifecycle_test.exs`) is to set this EXPLICITLY
  # rather than trust the compiled-at-build-time default, since samen_core is
  # compiled as a path dep of multiple sibling hosts.
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

  defp confirm_mods do
    %{credential: Credential, auth_token: AuthToken, repo: Repo}
  end

  defp unique_email, do: "confirm-#{System.unique_integer([:positive])}@example.test"

  defp register!(overrides \\ %{}) do
    attrs =
      %{
        org_name: "Confirm Co #{System.unique_integer([:positive])}",
        first_name: "Ada",
        last_name: "Lovelace",
        email: unique_email(),
        password: "correct horse battery staple"
      }
      |> Map.merge(overrides)

    {:ok, result} = Register.register(attrs, register_mods())
    # Stash the plaintext email the test itself chose — `email_bidx` is a
    # one-way HMAC, so the plaintext is otherwise unrecoverable after
    # registration. This is a TEST-ONLY convenience, never a production shape.
    Map.put(result, :email, attrs.email)
  end

  defp reread_credential(id) do
    Credential
    |> Ash.Query.ensure_selected([:id, :verified_at, :email_bidx])
    |> Ash.Query.filter(id == ^id)
    |> Ash.read!(authorize?: false)
    |> List.first()
  end

  # ===========================================================================
  # 1. Token single-use / expiring / context-bound (Samen.Auth.TokenConsume)
  # ===========================================================================

  describe "A2 confirm loop — single-use, expiring, context-bound" do
    test "FIRST-USE POSITIVE CONTROL: consuming the fresh raw token verifies the credential" do
      result = register!()
      refute reread_credential(result.credential.id).verified_at

      assert {:ok, updated} = Confirm.consume(result.raw_verify_token, confirm_mods())
      refute is_nil(updated.verified_at)
      refute is_nil(reread_credential(result.credential.id).verified_at)
    end

    test "a successful consume audits identity.email_verified (subject = credential)" do
      result = register!()

      assert {:ok, _updated} = Confirm.consume(result.raw_verify_token, confirm_mods())

      rows = AuditEvent.for_subject(Repo, result.credential.id)
      assert Enum.any?(rows, &(&1.detail =~ "identity.email_verified"))
    end

    test "RED PATH: consuming the SAME token a second time fails (single-use)" do
      result = register!()

      assert {:ok, _} = Confirm.consume(result.raw_verify_token, confirm_mods())
      assert {:error, :invalid_token} = Confirm.consume(result.raw_verify_token, confirm_mods())
    end

    test "RED PATH: an already-expired token fails" do
      result = register!()
      {:ok, bidx} = BlindIndex.compute(result.email)

      # Mint a SECOND token for the same credential, already expired (negative
      # TTL) — proves expiry independent of the fresh signup token above.
      {:ok, _auth_token, raw_expired} =
        TokenMint.mint(AuthToken, result.credential.id, :email_verify, bidx, -10)

      assert {:error, :invalid_token} = Confirm.consume(raw_expired, confirm_mods())
    end

    test "RED PATH: a :password_reset-context token cannot be consumed as :email_verify" do
      result = register!()

      {:ok, _auth_token, raw_reset_token} =
        TokenMint.mint(AuthToken, result.credential.id, :password_reset, nil, 3600)

      assert {:error, :invalid_token} = Confirm.consume(raw_reset_token, confirm_mods())
    end

    test "a garbage/never-minted token fails generically" do
      assert {:error, :invalid_token} = Confirm.consume("not-a-real-token", confirm_mods())
    end

    test "mechanism proof: Samen.Auth.TokenConsume.consume_once/3 directly single-uses" do
      result = register!()
      digest = TokenMint.digest(result.raw_verify_token)

      assert {:ok, row} = TokenConsume.consume_once(AuthToken, digest, :email_verify)
      assert row.credential_id == result.credential.id
      assert TokenConsume.consume_once(AuthToken, digest, :email_verify) == :error
    end

    test "the AuthToken row stores only the digest — never the raw token" do
      result = register!()

      raw = Ash.get!(AuthToken, result.auth_token.id, authorize?: false)
      refute raw.token_digest == result.raw_verify_token
      refute inspect(raw) =~ result.raw_verify_token
    end

    test "DB PROBE: the raw column `wot_token_digest` is the SHA-256 digest, never the raw token at rest" do
      result = register!()

      %{rows: [[digest_col]]} =
        Repo.query!("SELECT wot_token_digest FROM wot_auth_token WHERE wot_id = $1", [
          Ecto.UUID.dump!(result.auth_token.id)
        ])

      refute digest_col == result.raw_verify_token
      refute digest_col =~ result.raw_verify_token
      assert digest_col == TokenMint.digest(result.raw_verify_token)
    end
  end

  # ===========================================================================
  # 2. Capability-limited unverified account (Samen.Policy.Verified)
  # ===========================================================================

  describe "Samen.Policy.Verified — unverified account denied a capability a verified one holds" do
    defp invitation_attrs(org_id), do: %{org_id: org_id, role: :member, email: ["invitee@example.test"]}

    test "RED PATH: an unverified actor is denied Invitation.create" do
      result = register!()
      actor = %{id: result.user.id, org_id: result.org.id, role: :owner, verified?: false}

      assert {:error, _} =
               Invitation
               |> Ash.Changeset.for_create(:create, invitation_attrs(result.org.id), actor: actor)
               |> Ash.create(actor: actor)
    end

    test "POSITIVE CONTROL: a verified actor holds the SAME capability (the deny above is not vacuous)" do
      result = register!()
      actor = %{id: result.user.id, org_id: result.org.id, role: :owner, verified?: true}

      assert {:ok, _invitation} =
               Invitation
               |> Ash.Changeset.for_create(:create, invitation_attrs(result.org.id), actor: actor)
               |> Ash.create(actor: actor)
    end

    test "RED PATH: an actor with no verified? key at all (never wired) is denied, not defaulted open" do
      result = register!()
      actor = %{id: result.user.id, org_id: result.org.id, role: :owner}

      assert {:error, _} =
               Invitation
               |> Ash.Changeset.for_create(:create, invitation_attrs(result.org.id), actor: actor)
               |> Ash.create(actor: actor)
    end
  end

  # ===========================================================================
  # 3. resend/2 — uniform response, dispatched via the Delivery chokepoint
  # ===========================================================================

  describe "Confirm.resend/2" do
    test "an unverified account gets {:ok, :sent} (LocalSink captures in :test)" do
      result = register!()
      assert {:ok, :sent} = Confirm.resend(result.email, confirm_mods())
    end

    test "an unverified account's resend mints a FRESH email_verify token" do
      result = register!()
      before = Ash.count!(AuthToken, authorize?: false)

      assert {:ok, :sent} = Confirm.resend(result.email, confirm_mods())
      assert Ash.count!(AuthToken, authorize?: false) == before + 1
    end

    test "a non-existent email ALSO gets {:ok, :sent} — no account-existence oracle" do
      assert {:ok, :sent} = Confirm.resend(unique_email(), confirm_mods())
    end

    test "an already-verified account gets {:ok, :sent} WITHOUT minting a fresh token (no-op)" do
      result = register!()
      assert {:ok, _} = Confirm.consume(result.raw_verify_token, confirm_mods())

      before = Ash.count!(AuthToken, authorize?: false)
      assert {:ok, :sent} = Confirm.resend(result.email, confirm_mods())
      assert Ash.count!(AuthToken, authorize?: false) == before
    end
  end

  # ===========================================================================
  # 4. Samen.Web.Auth.ConfirmLive — the /verify/:token surface
  # ===========================================================================

  describe "Samen.Web.Auth.ConfirmLive" do
    test "a VALID token renders the verified confirmation" do
      result = register!()
      mount = build_mount(:auth)
      html = mount_smoke(ConfirmLive, mount, %{"token" => result.raw_verify_token})

      assert html =~ "Email verified"
      assert html =~ "confirm-ok"
    end

    test "an INVALID token renders the generic error, without an account-existence oracle" do
      mount = build_mount(:auth)
      html = mount_smoke(ConfirmLive, mount, %{"token" => "totally-bogus-token"})

      assert html =~ "confirm-error-title"
      assert html =~ "invalid or has expired"
    end
  end
end
