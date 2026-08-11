defmodule PawChart.Auth do
  @moduledoc """
  PawChart's operator-ROLE authority seam (T146 / T157) — the REAL operator roster resolver
  wired as `config :pawchart, :operator_authority, {PawChart.Auth, :operator_role, [:pawchart]}`.

  This is the load-bearing T157 requirement: pawchart's operator plane is gated by a REAL roster
  (a configured `:operator_roster` mapping principal → role), NOT the framework dev fallback
  (`Samen.Web.Operator.Authz.dev_operator_role/2`). The roster path grants a LISTED principal its
  role and refuses an UNLISTED one — and it does so even when the dev convenience is disarmed
  (`auth_required?: true`), so a prod-armed pawchart refuses every principal absent from the roster.

  Auth is host-owned (ADR-029). A production deploy provisions `:operator_roster` (or swaps
  `operator_role/2` for real operator `Membership` rows); the seam and the `Samen.Web.Operator.Authz`
  / `Samen.Web.AuthGate` consumers stay exactly the same underneath. Mirrors `Driftwood.Auth`'s
  operator-role seam, scoped to the `:pawchart` product.

  ## Tenant membership seam (PP-2, Batch 5a)

  `authorized_org_ids/1` is the `:authorized_orgs` membership seam `Samen.Web.CurrentOrg.resolve/3`
  calls on an ARMED host to constrain the tenant actor to the authenticated user's OWN orgs. Because
  pawchart is a REAL authenticated product (operator ruling), this resolves from REAL
  `Identity.Membership` rows on `PawChart.Operator` (the SAME spine `samen_auth_routes` /
  `samen_settings_routes` mount) — NOT a static credential map. An unknown user → `[]` (deny). This
  is the "a real deploy points it at Identity.Membership rows" completion `Driftwood.Auth`'s
  reference docstring describes.
  """

  require Ash.Query

  @operator_roles [:operator_admin, :operator_support, :operator_readonly, :operator_break_glass]

  @doc """
  T146 + T157 — the PER-PRODUCT operator-ROLE authority seam, scoped by `app_scope`
  (ADR-044 §6.2). Returns the operator role `principal_id` holds ON `app_scope`, or `nil`
  (NOT an operator on that product — fail CLOSED). Resolution:

    0. **Per-product isolation (RP-J-5).** This host owns exactly the `:pawchart` product. A role
       granted here confers scope ONLY on `:pawchart`; `operator_role(:other, _)` is `nil`.
    1. the configured operator ROSTER (`config :pawchart, :operator_roster, %{principal_id => role}`)
       — the REAL resolver a production deploy provisions;
    2. else, ONLY while `:auth_required?` is false (dev/test) AND `app_scope == :pawchart`, a dev
       convenience grant of `:operator_admin` so the local dogfood console works without a login.
       The instant the app is armed for prod (`config :pawchart, auth_required?: true`), a principal
       ABSENT from the roster is refused — the roster is the only authority.
  """
  @spec operator_role(atom(), String.t() | nil) :: atom() | nil
  def operator_role(app_scope, principal_id) when is_atom(app_scope) do
    if app_scope != :pawchart do
      nil
    else
      roster = Application.get_env(:pawchart, :operator_roster, %{})

      case is_binary(principal_id) && Map.get(roster, principal_id) do
        role when role in @operator_roles ->
          role

        _ ->
          # Dev/test convenience ONLY (unmistakably gated on the prod-arming flag being off).
          if Application.get_env(:pawchart, :auth_required?, false), do: nil, else: :operator_admin
      end
    end
  end

  def operator_role(_app_scope, _principal_id), do: nil

  @doc """
  The valid operator roles (mirror of `Samen.OperatorPlane.Actor.roles/0`) — exposed for tests.
  """
  @spec operator_roles() :: [atom()]
  def operator_roles, do: @operator_roles

  @doc """
  The tenant org ids the authenticated `user_id` may act on — the `:authorized_orgs` membership
  seam `Samen.Web.CurrentOrg` calls on an armed host. Resolves REAL `Identity.Membership` rows on
  `PawChart.Operator` (the identity spine `samen_auth_routes`/`samen_settings_routes` mount): every
  org the user holds a membership in. Read unscoped (`authorize?: false`) BY DESIGN — this function
  IS the authorization boundary that decides which orgs the principal may act on, exactly as
  `Samen.Auth.OrgActor.authorized_org_ids/2` reads the spine directly. Unknown user / error → `[]`
  (deny — fail closed).
  """
  @spec authorized_org_ids(String.t() | nil) :: [String.t()]
  def authorized_org_ids(user_id) when is_binary(user_id) do
    PawChart.Operator.Membership
    |> Ash.Query.filter(user_id == ^user_id)
    |> Ash.Query.ensure_selected([:org_id])
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.org_id)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  rescue
    _ -> []
  end

  def authorized_org_ids(_user_id), do: []
end
