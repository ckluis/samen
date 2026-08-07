defmodule Samen.Web.Operator.Fleet do
  @moduledoc """
  Shared helpers for the WS-J fleet cockpit LiveViews (ADR-044 §5/§6/§7, T84b) —
  the `roles[:fleet]` gate (§6.3, role-gated not session-gated), the app-scope
  atomization for the J3 args-carrier roles map, and small render helpers common
  to `FleetLive`/`FleetDetailLive`/`FleetDirectivesLive`/`FleetRegisterLive`.
  """

  alias Samen.Fleet.Authz
  alias Samen.Web.{Auth, Mount, Operator}

  @typedoc "The resolved fleet context a gated LiveView carries in its assigns."
  @type ctx :: %{
          principal_id: String.t() | nil,
          otp_app: atom() | nil,
          namespace: module() | nil,
          roles: %{atom() => atom()},
          admin?: boolean()
        }

  @doc """
  The tier-1/2 role gate (§6.3: "render the cockpit at all" requires
  `roles[:fleet] != nil`). Resolves the principal from the AUTHENTICATED session
  (never a query param — the same primitive `Samen.Web.Operator.Authz` uses),
  reads the fleet-wide role map via the host's `:fleet_authority` seam, and
  returns `{:ok, ctx}` when `roles[:fleet]` is present, `:denied` otherwise.

  Fail-CLOSED: no mount, no `otp_app`, no `:fleet_authority` seam, or no
  `roles[:fleet]` entry ⇒ `:denied` — the caller renders NOTHING (RP-J-5).
  """
  @spec gate(Mount.t() | nil, map()) :: {:ok, ctx()} | :denied
  def gate(%Mount{} = mount, session) when is_map(session) do
    principal_id = Auth.authenticated_user_id(session)
    otp_app = Operator.otp_app(mount)
    roles = if otp_app, do: Authz.roles_for(otp_app, principal_id), else: %{}

    case Map.get(roles, :fleet) do
      nil ->
        :denied

      role ->
        {:ok,
         %{
           principal_id: principal_id,
           otp_app: otp_app,
           namespace: Mount.label(mount, :fleet_namespace, nil),
           roles: roles,
           admin?: role == :operator_admin
         }}
    end
  end

  def gate(_mount, _session), do: :denied

  @doc """
  Does `roles` grant tier-2 access for the product registered under `slug`
  (§5.4: `roles[:fleet] != nil` AND `roles[app_id] != nil` for the row — the row's
  PRODUCT SCOPE is its registered `slug`, atomized via the SAME bounded shape
  every registered slug already satisfies, `^[a-z][a-z0-9_-]{1,38}$` — so
  atomizing an OPERATOR-REGISTERED slug is bounded, not attacker-controlled
  free text).
  """
  @spec app_role(map(), String.t() | nil) :: atom() | nil
  def app_role(roles, slug) when is_map(roles) and is_binary(slug) do
    Map.get(roles, app_scope(slug))
  end

  def app_role(_roles, _slug), do: nil

  @doc "Atomize a registered app slug for the J3 roles-map lookup. Fail-closed to `nil`."
  @spec app_scope(String.t() | nil) :: atom() | nil
  def app_scope(slug) when is_binary(slug) do
    String.to_existing_atom(slug)
  rescue
    ArgumentError -> nil
  end

  def app_scope(_), do: nil

  @doc "n=1==n=N chrome header (§8.2 rule 5) — the ONE place a row-count literal is allowed."
  @spec pluralize(non_neg_integer(), String.t()) :: String.t()
  def pluralize(1, noun), do: "1 #{noun}"
  def pluralize(n, noun), do: "#{n} #{noun}s"

  @doc "A metric the app cannot compute renders `—`, never `0` (§8.2 rule 2)."
  @spec metric(map(), String.t()) :: String.t()
  def metric(report, key) when is_map(report) do
    case Map.get(report, key) do
      nil -> "—"
      %{"suppressed" => true} -> "⊘"
      value -> to_string(value)
    end
  end

  def metric(_report, _key), do: "—"

  @doc "Fixed precedence: the login redirect target when the fleet gate denies."
  @spec login_path(Mount.t() | nil) :: String.t()
  def login_path(%Mount{} = mount), do: Mount.label(mount, :login_path, "/login")
  def login_path(_), do: "/login"
end
