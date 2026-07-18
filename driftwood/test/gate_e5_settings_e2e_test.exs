defmodule Driftwood.GateE5SettingsE2ETest do
  @moduledoc """
  GATE PROBE (WS-E E5.4) — the self-serve settings surface end-to-end on a REAL host
  (Driftwood): the `samen_settings_routes` macro mount + the settings engines
  (`Samen.Web.Settings.Profile` / `ApiKeys`) over Driftwood's Identity namespace
  (`Driftwood.Operator.{User,ApiKey,Membership}`). Proves at ≈0 authored settings LOC:

    * the profile self-edit routes through the vault chokepoint — a tenant self-edit
      vault-routes `full_name` to `vt_*`; an operator-impersonation plaintext PII write
      is refused (AC-G18-2);
    * API-key mint is show-once / digest-only, authority bounded by the minter ceiling
      (AC-G18-3/4);
    * no framework auth is invented (the Security surface reads the real accountability
      source; AC-G18-5).

  A gate artifact, not part of the shipped suites.
  """
  use Driftwood.DataCase, async: false

  alias Samen.Type.FullName
  alias Samen.Web.Mount
  alias Samen.Web.Plane
  alias Samen.Web.Router
  alias Samen.Web.Settings.ApiKeys
  alias Samen.Web.Settings.Profile
  alias Samen.Web.Settings.SecurityLive

  alias Driftwood.Operator.Membership
  alias Driftwood.Operator.User

  @secret_first "GateVaultedFirst"
  @secret_last "GateVaultedLast"

  defp mount, do: Mount.new(:settings, Driftwood.Operator, Driftwood.Repo, plane: Plane.tenant())

  defp op_mount(org_id),
    do: Mount.new(:settings, Driftwood.Operator, Driftwood.Repo, plane: Plane.operator("op-1", org_id, "s"))

  defp tenant_scope(org_id), do: Plane.scope(Plane.tenant(), org_id)
  defp operator_scope(org_id), do: Plane.scope(Plane.operator("op-1", org_id, "s"), org_id)

  defp admin_scope(user_id, org_id),
    do: %Samen.Scope{actor: %{id: user_id, org_id: org_id, role: :admin, kind: :tenant, plane: :tenant}}

  defp seed!(org_id) do
    user =
      User
      |> Ash.Changeset.for_create(:create, %{
        org_id: org_id,
        handle: "gateadmin",
        full_name: %FullName{first: @secret_first, last: @secret_last},
        emails: [%{address: "gate.secret@example.test"}]
      })
      |> Ash.create!(authorize?: false)

    membership =
      Membership
      |> Ash.Changeset.for_create(:create, %{org_id: org_id, user_id: user.id, role: :admin})
      |> Ash.create!(authorize?: false)

    {user, membership}
  end

  defp raw_full_name(id) do
    %{rows: [[raw]]} =
      Driftwood.Repo.query!("SELECT dou_full_name FROM dou_user WHERE dou_id = $1", [Ecto.UUID.dump!(id)])

    raw
  end

  test "the macro mounts all three settings surfaces at ≈0 LOC" do
    routes = Router.__routes__(:settings, "/settings")
    assert {"/settings", Samen.Web.Settings.ProfileLive} in routes
    assert {"/settings/api-keys", Samen.Web.Settings.ApiKeysLive} in routes
    assert {"/settings/security", Samen.Web.Settings.SecurityLive} in routes
  end

  test "profile self-edit vault-routes on the tenant plane; an operator plaintext write is refused" do
    org_id = Ash.UUID.generate()
    {user, _} = seed!(org_id)

    # Tenant self-edit → vt_* at rest, plaintext nowhere.
    assert {:ok, _} =
             Profile.update(mount(), tenant_scope(org_id), user.id, %{
               full_name: %{first: "NewFirst", last: "NewLast"}
             })

    raw = raw_full_name(user.id)
    assert String.starts_with?(raw, "vt_")
    refute raw =~ "NewFirst"

    # Operator-impersonation plaintext PII write → refused, DB unchanged.
    before = raw_full_name(user.id)

    assert {:error, _} =
             Profile.update(op_mount(org_id), operator_scope(org_id), user.id, %{
               full_name: %{first: "OperatorInjected", last: "Plaintext"}
             })

    assert raw_full_name(user.id) == before
  end

  test "API-key mint is show-once / digest-only, ceiling-bounded" do
    org_id = Ash.UUID.generate()
    {user, membership} = seed!(org_id)
    scope = admin_scope(user.id, org_id)

    assert {:ok, raw, row} =
             ApiKeys.mint(mount(), scope,
               membership_id: membership.id,
               minter_role: membership.role,
               scopes: %{all: [:read, :write]}
             )

    assert String.starts_with?(raw, "sk_")
    assert row.token_digest == :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
    refute row.token_digest == raw

    # The list never re-displays the raw key.
    [view | _] = ApiKeys.list(mount(), scope)
    refute view.digest_prefix == raw

    # The ceiling strips write for a viewer minter.
    assert ApiKeys.effective_scopes(%{all: [:read, :write]}, :viewer) == %{all: [:read]}
  end

  # WS-E E7.2 — resolves the E5-P2 carry ("bind a positive-sessions render at E7 on a
  # host that migrates the impersonation table"). The samen_web test host has no
  # `imp_impersonation_session` table, so E5.3 could only prove the read-only/honesty
  # STRUCTURE against an EMPTY session list. Driftwood DOES migrate the table
  # (`operator_plane.exs`) and configures `:impersonation_repo`, so here we seed a REAL
  # governed session and prove SecurityLive renders it — the positive control that the
  # empty-state RP-ST-4 test lacked. The surface stays read-only (no phx-click/submit).
  test "Security page renders REAL impersonation sessions (positive control; E5-P2 carry resolved)" do
    org_id = Ash.UUID.generate()

    {:ok, session} =
      Samen.Impersonation.Sessions.open(%{
        operator_id: "gate-e7-operator",
        org_id: org_id,
        reason: "E7 gate positive-sessions accountability render",
        repo: Driftwood.Repo
      })

    mount = Mount.new(:settings, Driftwood.Operator, Driftwood.Repo, plane: Plane.tenant())
    html = render_framework(SecurityLive, mount, [org_id, nil])

    # The real session row is rendered — operator id + reason present, in a session row.
    assert html =~ "security-session-row"
    assert html =~ "gate-e7-operator"
    assert html =~ "E7 gate positive-sessions accountability render"
    # The positive control: NOT the empty-state the samen_web host was limited to.
    refute html =~ "No impersonation sessions recorded."

    # Read-only + honest: no auth-mutating control was invented on this page (RP-ST-4).
    refute html =~ "phx-click"
    refute html =~ "phx-submit"
    assert html =~ "managed by your identity provider"

    # Sanity: the rendered session is the one we opened.
    assert session.org_id == org_id
  end
end
