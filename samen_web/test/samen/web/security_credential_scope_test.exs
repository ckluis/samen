defmodule Samen.Web.SecurityCredentialScopeTest do
  @moduledoc """
  S6 (luminary panel-2 MED) — `SecurityLive`'s `credential_id_for` seam is a GOVERNED,
  org-scoped read, not a global `user_id → credential_id` oracle.

  ## The hole this closes

  `Samen.Web.Settings.SecurityLive.credential_id_for/2` did
  `Ash.read!(authorize?: false)` on the Identity spine `User` filtered only by a supplied
  `user_id` — no org scope, no actor, no `# authz-scope:` justification. G1 (B-SEC) narrowed
  how a foreign `user_id` can REACH this seam (identity now derives from the session), but
  the read itself stayed ungoverned: any code path handing it a foreign user id resolved
  that user's `credential_id` — the pivot in the S3 chain (a credential id is the key to the
  TOTP-enrollment and session-listing surfaces).

  ## The fix under test

  The read now goes through `Ash.read!(scope: …)` with the caller's org-resolved tenant
  scope (`Samen.Web.Mount.scope/2`) — the SAME governed pattern as
  `Samen.Web.Settings.Reads.get_user/3`. `Samen.Policy.OrgScope` on `Identity.User` means a
  cross-org `user_id` reads ZERO rows: the seam answers `nil`, the 2FA link degrades to the
  bare path, the session list renders empty. No resolvable org (`org_id` nil) → `nil`,
  fail closed. Access was NEVER widened — the same-org read is byte-equivalent.

  ## Anti-tautology

  The denial is paired with the positive control: the SAME seam, driven with the user's OWN
  org scope, still resolves the credential id (the 2FA enroll link carries it, the live
  session list renders).
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Auth.SessionCreate
  alias Samen.Identity.Register
  alias Samen.Web.Mount
  alias Samen.Web.Settings.SecurityLive
  alias Samen.WebTest.Operator, as: Op

  setup do
    # Registration dispatches through the fail-honest Delivery chokepoint; `:test` no-ops it.
    prev_delivery = Application.get_env(:samen_core, :delivery_env)
    Application.put_env(:samen_core, :delivery_env, :test)

    on_exit(fn ->
      case prev_delivery do
        nil -> Application.delete_env(:samen_core, :delivery_env)
        v -> Application.put_env(:samen_core, :delivery_env, v)
      end
    end)

    victim = register_owner!()
    attacker = register_owner!()

    # The victim holds a LIVE spine session — the row the oracle's session-list leg exposes.
    {:ok, _session, _raw} = SessionCreate.create(session_create_mods(), victim.credential.id)

    %{victim: victim, attacker: attacker}
  end

  # ==========================================================================
  # RED — a foreign user_id under the CALLER's org scope resolves NOTHING
  # ==========================================================================

  test "a cross-org user_id resolves NO credential id (the 2FA link carries no foreign credential)", ctx do
    socket = load(ctx.attacker.org.id, ctx.victim.user.id)

    path = socket.assigns.totp_enroll_path
    assert is_binary(path)

    refute path =~ ctx.victim.credential.id,
           "S6 regression: the ungoverned read resolved a FOREIGN user's credential_id (global oracle)"

    refute path =~ "credential_id="
  end

  test "a cross-org user_id lists NO login sessions (the victim's live session is invisible)", ctx do
    socket = load(ctx.attacker.org.id, ctx.victim.user.id)

    assert socket.assigns.login_sessions == [],
           "S6 regression: a foreign user's LIVE sessions were listed across the org boundary"
  end

  test "no resolvable org (org_id nil) → the seam fails closed to nil", ctx do
    socket = load(nil, ctx.victim.user.id)

    refute socket.assigns.totp_enroll_path =~ "credential_id="
    assert socket.assigns.login_sessions == []
  end

  # ==========================================================================
  # POSITIVE CONTROL (anti-tautology) — the OWN-org path still resolves
  # ==========================================================================

  test "POSITIVE CONTROL — the user's own org scope still resolves their credential id", ctx do
    socket = load(ctx.victim.org.id, ctx.victim.user.id)

    assert socket.assigns.totp_enroll_path =~ "credential_id=#{ctx.victim.credential.id}",
           "the governed read must still resolve the caller's OWN credential (never widen, never break)"
  end

  test "POSITIVE CONTROL — the user's own org scope still lists their live session", ctx do
    socket = load(ctx.victim.org.id, ctx.victim.user.id)

    assert [session | _] = socket.assigns.login_sessions
    assert session.credential_id == ctx.victim.credential.id
  end

  # -- harness -----------------------------------------------------------------

  defp load(org_id, user_id) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, settings_mount())
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> Phoenix.Component.assign(:return_to, nil)
    |> SecurityLive.load(org_id, user_id)
  end

  defp settings_mount do
    Mount.new(:settings, Samen.WebTest.Operator, Samen.WebTest.Repo,
      labels: %{spine_totp: true, spine_sessions: true}
    )
  end

  defp register_mods,
    do: %{
      org: Op.Org,
      credential: Op.Credential,
      user: Op.User,
      membership: Op.Membership,
      auth_token: Op.AuthToken,
      repo: Samen.WebTest.Repo
    }

  defp session_create_mods,
    do: %{session: Op.Session, org: Op.Org, membership: Op.Membership, user: Op.User}

  defp register_owner! do
    attrs = %{
      org_name: "S6 Co #{System.unique_integer([:positive])}",
      first_name: "Ada",
      last_name: "Lovelace",
      email: "s6-#{System.unique_integer([:positive])}@example.test",
      password: "correct horse battery staple"
    }

    {:ok, result} = Register.register(attrs, register_mods())
    result
  end
end
