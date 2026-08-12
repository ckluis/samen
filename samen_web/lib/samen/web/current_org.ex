defmodule Samen.Web.CurrentOrg do
  @moduledoc """
  The session-resolved CURRENT ORG for tenant-plane + shared LiveViews (ADR-013 §4).

  Before this module, every tenant/shared page read `Map.get(params, "org")` and dead-ended
  (`no_org: true` → "No org selected. Append `?org=<uuid>`") when it was absent — the demo
  required hand-typing a UUID into the URL. This module owns the ONE resolution order every
  such LiveView asks: "what org am I acting on?" — with a sensible dev default and NO dead-end.

  It governs ONLY the tenant + shared planes. The operator/aggregate planes scope to the
  operator org via `Samen.Web.Operator.org_id/1` and do NOT use this resolver.

  ## Resolution order (`resolve/3`, first hit wins)

    1. `params["org"]` — an explicit `?org=<uuid>` deep link / drill-in target / test param.
       Still fully supported; the switcher/drill-in ALSO writes it to the session (via the
       `SessionController`) so subsequent same-plane navigation stays sticky.
    2. `session["samen_current_org"]` — the org last chosen through the switcher or the
       operator "Open account →". This is what makes navigation sticky.
    3. `Mount.label(mount, :default_org_id, nil)` — a host may pin a default tenant org on the
       mount (data on the mount, not code). Driftwood pins Blue Ridge Logistics in dev.
    4. `first_listable_org_id(mount)` — the first org from the mount's directory (§below), so a
       freshly-seeded environment lands on a POPULATED page even with no default set.

  Falls through to `nil` ONLY when nothing resolves (an unseeded DB). The LiveViews render a
  friendly "run `mix driftwood.seed`" seed-state card in that case (`no_org?/1`), never the
  old "type a UUID" instruction.

  ## The tenant directory (`list_orgs/1`) — powers the switcher + the name label

  The switcher and the first-listable default both need "the tenant orgs this seat may act on."
  Framework-side that is the operator org's ACCOUNTS (each account row IS a tenant org). A plain
  tenant/shared mount cannot see the operator namespace, so the host exposes the directory
  through a mount label seam: `Mount.label(mount, :org_directory, {mod, fun, args})` — an MFA the
  host wires that returns `[{org_id, name}, …]`. Absent the seam, `list_orgs/1` returns `[]` and
  the switcher hides (graceful). An operator/aggregate mount that carries `:operator_org_id`
  reads its accounts directly via `Samen.Web.Operator.Reads.accounts/3`.

  ## Masking invariant (unchanged)

  Nothing here reads or writes a mask. Current-org resolution only decides WHICH org's data a
  page reads; `Samen.Api.PiiResolution` still decides clear-vs-`••••` by `actor.plane`. The
  masking line is the plane line (ADR-010 §5), untouched.
  """
  use Phoenix.Component

  alias Samen.Web.Mount

  @session_key "samen_current_org"

  @doc "The session key under which the switcher/drill-in store the current org."
  def session_key, do: @session_key

  @doc """
  The same-module return path for the switcher, derived from the LiveView's `uri` (path only,
  the `?org=` query stripped so the switch endpoint owns the org). A nil/blank uri → `nil`
  (the switch endpoint then falls back to its default).
  """
  @spec return_path(String.t() | nil) :: String.t() | nil
  def return_path(uri) when is_binary(uri) do
    case URI.parse(uri).path do
      "/" <> _ = path -> path
      _ -> nil
    end
  end

  def return_path(_), do: nil

  @doc """
  Resolve the current tenant org id for `mount` given the LiveView `params` + the `session`.

  Resolution order (first non-nil wins): param → session → mount default label → first listable
  org → `nil`. See the moduledoc. Never raises; a mount without a directory simply reaches the
  default label or `nil`.

  ## The authenticated prod-path gate (F2 / ADR-031)

  The order above is the DEV/dogfood convenience path: a `?org=<uuid>` is trusted as identity.
  For a real launch that is an authentication hole — anyone could act as any org's member by
  typing its id. When the mount opts into `authn` (a host label; driftwood wires it to a
  runtime `:auth_required?` flag), `resolve/3` switches to the FAIL-CLOSED prod path:

    1. the session MUST carry an authenticated principal (`Samen.Web.Auth.authenticated_user_id/1`,
       set only by a real host login — never a query param); absent it → `nil` (NO actor);
    2. the org is constrained to the principal's authorized set (the host-wired `:authorized_orgs`
       seam — an `{mod, fun, args}` returning `[org_id, …]`); a `?org=`/session org OUTSIDE that
       set never resolves — the viewer lands on their own first authorized org, never the target;
    3. no principal, no seam, or an empty authorized set → `nil` (NO actor).

  The security boundary is this actor-derivation step, not the `SessionController` write: even a
  session carrying an unauthorized org yields no actor for it here.

  ## Fail-closed default on an ARMED host (PP-1 / PP-3, ADR-031)

  The `?org=`/session convenience is a DEV/dogfood affordance and is trusted ONLY in the
  explicitly DISARMED posture (`param_trust_disarmed?/1` — the host's `:auth_required?` runtime
  flag is false/unset, mirroring `Samen.Web.Operator.Impersonation.auth_disarmed?/1`). On an
  ARMED host (`config otp_app, auth_required?: true`) a mount that carries NO `:authn` label no
  longer falls through to the trusting dev path — it FAILS CLOSED (`nil`, no actor, no PII). This
  closes the class where a vertical mounts a PII-bearing tenant scope but never adopts the
  tenant-auth seam (the pawchart cross-tenant leak): such a mount is safe-because-DENIED, not
  safe-because-trusted. A correctly `:authn`-labelled mount (driftwood) keeps working: armed → the
  authorized path above; disarmed (dev/test) → the query-param convenience, unchanged.
  """
  @spec resolve(Mount.t() | nil, map(), map()) :: String.t() | nil
  def resolve(mount, params, session) do
    cond do
      # 1. The mount ADOPTED the `:authn` seam AND its host is armed → the fail-closed
      #    prod path: an authenticated principal, constrained to its authorized orgs
      #    (driftwood-prod; the positive control). A `?org=` is NEVER trusted as identity.
      authn_required?(mount) ->
        resolve_authorized(mount, params, session)

      # 2. The host is in the explicit DISARMED (dev/dogfood) posture → the sanctioned
      #    query-param convenience identity (LOCAL ergonomics: `?org=`/session trusted).
      param_trust_disarmed?(mount) ->
        param_org(params) ||
          session_org(session) ||
          default_label(mount) ||
          first_listable_org_id(mount)

      # 3. FAIL CLOSED (PP-1 / PP-3, ADR-031). An ARMED host mounted a PII-bearing tenant
      #    scope that never adopted the `:authn` gate (pawchart's unlabeled mounts). The
      #    dev `?org=` convenience is an unauthenticated cross-tenant identity hole in
      #    prod, so this mount derives NO org from a caller-supplied param — it yields
      #    `nil` (no actor, the seed-state/no-org card renders, NO PII) rather than
      #    trusting the param. The org a tenant acts in MUST come from the authenticated,
      #    authorized `:authn` path (branch 1), never a raw param on an armed host.
      true ->
        nil
    end
  end

  @doc """
  Whether the TENANT AUTHZ GATE is ENGAGED for this mount (B-SEC / S1).

  True when EITHER the mount adopted the `:authn` seam and its host is armed, OR the host is
  armed at all (the PP-1/PP-3 fail-closed branch). It is the exact complement of "the sanctioned
  DISARMED dev posture in which `?org=` is trusted as identity" — i.e. it answers "is a
  client-supplied `?org=` FORBIDDEN as an identity on this mount?".

  This is the predicate `Samen.Web.TenantAuthz`'s `on_mount` hook and `reresolve/2` both key on,
  so the `mount/3` answer (`resolve/3`) and the `handle_params/3` answer can never disagree.
  """
  @spec tenant_gate_armed?(Mount.t() | nil) :: boolean()
  def tenant_gate_armed?(mount), do: authn_required?(mount) or not param_trust_disarmed?(mount)

  @doc """
  Whether the session carries ANY authenticated principal this mount can see — the legacy
  BYO-auth `samen_current_user` key OR the framework spine's `samen_session_token`. Never
  raises; never consults a param.
  """
  @spec principal?(Mount.t() | nil, map()) :: boolean()
  def principal?(mount, session) do
    is_binary(Samen.Web.Auth.authenticated_user_id(session)) or
      match?({:ok, _}, spine_credential_id(mount, session))
  end

  @doc """
  The authenticated principal's id for `mount` + `session`, or `nil`. The SPINE credential id
  (`samen_session_token`) first — the id `Samen.Auth.OrgActor` keys a membership lookup on
  (ADR-045 §4.4, the tenant-role residual) — then the legacy BYO `samen_current_user` id. Never
  a param, never raises. `Samen.Web.TenantAuthz` pins this into the socket so the tenant
  `write_scope` helpers + the generated `--live` screens can derive the REAL membership role on an
  armed host instead of a hardcoded `:admin`.
  """
  @spec principal_id(Mount.t() | nil, map()) :: String.t() | nil
  def principal_id(mount, session) do
    case spine_credential_id(mount, session) do
      {:ok, credential_id} when is_binary(credential_id) -> credential_id
      _ -> Samen.Web.Auth.authenticated_user_id(session)
    end
  end

  @doc """
  The org ids the session's authenticated principal is AUTHORIZED to act in, `[]` when there is
  no principal / no seam / an error (deny). Legacy BYO `:authorized_orgs` MFA first, then the
  framework spine's real `Membership` rows — the SAME two-tier order `resolve/3` uses, exposed
  so the `on_mount` gate can PIN the set into the socket and `handle_params/3` can validate a
  `?org=` against it instead of trusting it.
  """
  @spec authorized_orgs(Mount.t() | nil, map()) :: [String.t()]
  def authorized_orgs(mount, session) do
    case legacy_authorized_orgs(mount, session) do
      [_ | _] = list -> list
      _ -> spine_authorized_orgs(mount, session)
    end
  end

  defp legacy_authorized_orgs(mount, session) do
    case Samen.Web.Auth.authenticated_user_id(session) do
      user_id when is_binary(user_id) -> authorized_org_ids(mount, user_id)
      _ -> []
    end
  end

  defp spine_authorized_orgs(mount, session) do
    case spine_credential_id(mount, session) do
      {:ok, credential_id} -> spine_authorized_org_ids(mount, credential_id)
      _ -> []
    end
  end

  @doc """
  Re-resolve the current org inside `handle_params/3` — the ONE shared helper every framework
  tenant LiveView calls in place of the old `Map.get(params, "org") || socket.assigns.org_id`
  idiom (B-SEC / S1, the confirmed BLOCKER).

  ## Why this exists

  In `phoenix_live_view` 1.2.9 `handle_params/3` runs on the INITIAL DEAD RENDER (plain HTTP
  GET, before any socket). The old idiom therefore OVERWROTE the fail-closed `resolve/3` answer
  computed one callback earlier in `mount/3` with a raw, client-supplied `?org=` — reopening the
  cross-tenant read (and, through the `write_scope/2` admin elevators, a cross-tenant admin
  WRITE) on every armed host. The client param was an IDENTITY; here it is downgraded to a
  SELECTOR, exactly as the operator drill-ins already treat `params["org_id"]`.

  ## The rule (strictly narrower than before; never wider)

    * `:samen_authorized_orgs` pinned by `Samen.Web.TenantAuthz`'s `on_mount` — a `?org=` is
      honoured ONLY when it is a member of the authenticated principal's authorized set;
      anything else keeps the org the gate/`mount/3` already resolved. (This is what keeps the
      workspace switcher and legitimate multi-org deep links working.)
    * `:unconstrained` (the explicitly DISARMED dev/dogfood posture, or an operator-plane mount
      whose authorization is the T146/T150 gate) — the historical `?org=` convenience,
      byte-for-byte unchanged.
    * no pin at all (a LiveView mounted outside the framework tenant macros) — the posture is
      re-derived from the mount: DISARMED keeps the convenience; ARMED refuses the param and
      keeps `mount/3`'s fail-closed answer. So the fix holds even where the hook does not run.
  """
  @spec reresolve(Phoenix.LiveView.Socket.t() | map(), map()) :: String.t() | nil
  def reresolve(socket, params) do
    assigns = socket_assigns(socket)
    current = Map.get(assigns, :org_id)
    requested = param_org(params)

    case Map.get(assigns, :samen_authorized_orgs) do
      :unconstrained ->
        requested || current

      list when is_list(list) ->
        if is_binary(requested) and requested in list, do: requested, else: current

      _ ->
        if tenant_gate_armed?(Map.get(assigns, :samen_mount)),
          do: current,
          else: requested || current
    end
  end

  defp socket_assigns(%{assigns: assigns}) when is_map(assigns), do: assigns
  defp socket_assigns(assigns) when is_map(assigns), do: assigns
  defp socket_assigns(_), do: %{}

  # Whether this mount requires an authenticated session before it derives an actor. Off by
  # default (dev/test convenience). A host opts in via the `:authn` label: `:required` (always
  # on) or `{:app_env, app, key}` (runtime-flippable — driftwood points this at
  # `:auth_required?`, false in dev/test, true in prod).
  defp authn_required?(%Mount{} = mount) do
    case Mount.label(mount, :authn, nil) do
      :required ->
        true

      {:app_env, app, key} when is_atom(app) and is_atom(key) ->
        !!Application.get_env(app, key, false)

      _ ->
        false
    end
  end

  defp authn_required?(_), do: false

  # Whether this mount's host is in the DISARMED (dev/dogfood) posture — the ONLY posture
  # in which the `?org=`/session convenience is trusted as identity (PP-1 / PP-3 fix). Mirrors
  # `Samen.Web.Operator.Impersonation.auth_disarmed?/1`, the SEC-batch pattern for the
  # impersonation `?operator_id` dev-leg: trust the dev convenience ONLY when explicitly
  # disarmed, fail closed otherwise. A host is disarmed when its `:auth_required?` runtime flag
  # is false/unset; an ARMED host (`config otp_app, auth_required?: true`) fails closed here EVEN
  # WHEN the mount carries no `:authn` label — so a vertical that never adopted the tenant-auth
  # seam (pawchart) can no longer serve a caller-supplied `?org=` as identity once deployed for
  # prod. A mount with NO resolvable otp_app (a synthetic/unit-test mount that carries no repo
  # config) counts as disarmed, exactly as the impersonation param-leg treats a mountless socket —
  # every framework route populates a real otp_app, so every armed deploy is covered.
  @doc """
  Whether this mount's host is in the DISARMED (dev/dogfood) posture — the ONLY posture in which
  a client-supplied `?org=`/`?user=` is trusted as identity. Public since B-SEC so the sibling
  identity resolvers (`Samen.Web.Settings.Reads`, `Samen.Web.Auth.TotpEnrollLive`) key their own
  param legs on the SAME predicate instead of trusting params unconditionally.
  """
  @spec param_trust_disarmed?(Mount.t() | nil) :: boolean()
  def param_trust_disarmed?(mount) do
    case Samen.Web.Operator.otp_app(mount) do
      nil -> true
      otp_app -> not Application.get_env(otp_app, :auth_required?, false)
    end
  end

  # The fail-closed prod path: an authenticated principal, constrained to its authorized orgs.
  #
  # Two principal shapes are tried, in order (ADR-035 §5 A4's CurrentOrg paragraph — the
  # `:authorized_orgs` seam now ALSO sources from the framework spine's real Membership rows,
  # not just the ADR-031 legacy BYO-auth seam):
  #
  #   1. LEGACY (`samen_current_user` session key) — the host-wired `:authorized_orgs`
  #      `{mod, fun, args}` MFA, UNCHANGED (`authorized_org_ids/2` below). Every existing
  #      BYO-auth host (driftwood's `Driftwood.Auth`) keeps working exactly as before.
  #   2. SPINE (`samen_session_token`) — `Samen.Web.Auth.resolve_principal/2` resolves the
  #      credential, then `Samen.Auth.OrgActor.authorized_org_ids/2` derives the authorized set
  #      from the credential's linked `Identity.User` rows DIRECTLY off this mount's own
  #      materialized Identity resources (no host MFA needed — the mount's namespace IS the
  #      Identity mount for `:auth`/`:settings`-kind scopes).
  defp resolve_authorized(mount, params, session) do
    case authorized_orgs(mount, session) do
      [_ | _] = authorized ->
        requested = param_org(params) || session_org(session)
        if requested in authorized, do: requested, else: List.first(authorized)

      _ ->
        nil
    end
  end

  # The host-wired `:authorized_orgs` membership seam — `{mod, fun, args}`, called with the
  # authenticated `user_id` appended, returning `[org_id, …]`. Absent/erroring → `[]` (deny).
  defp authorized_org_ids(%Mount{} = mount, user_id) do
    case Mount.label(mount, :authorized_orgs, nil) do
      {mod, fun, args} when is_atom(mod) and is_atom(fun) and is_list(args) ->
        case apply(mod, fun, args ++ [user_id]) do
          list when is_list(list) -> Enum.filter(list, &is_binary/1)
          _ -> []
        end

      _ ->
        []
    end
  rescue
    _ -> []
  end

  # ADR-045 §4.4 — the sibling mount carrying the Identity spine (`Session`/`User`/`Membership`).
  # A tenant MODULE mount (crm/flags/billing/…) has a VERTICAL namespace, so the host names the
  # Identity namespace with the `:identity_namespace` label — the `:kb_namespace` sibling-mount
  # seam. Absent the label the mount is used as-is (a settings/auth mount, or a generated `--live`
  # `@samen_authn_mount`, already carries the Identity namespace — backward compatible). This lets
  # a wired module surface be genuinely SPINE-capable (authenticate the principal, read its
  # authorized orgs + Membership role) instead of only legacy-BYO-capable.
  defp identity_ns_mount(%Mount{} = mount) do
    case Mount.label(mount, :identity_namespace, nil) do
      ns when is_atom(ns) and not is_nil(ns) -> %{mount | namespace: ns}
      _ -> mount
    end
  end

  defp spine_credential_id(%Mount{} = mount, session) do
    mount = identity_ns_mount(mount)
    session_mod = Mount.resource(mount, Session)

    case Samen.Web.Auth.resolve_principal(session, %{session: session_mod}) do
      {:ok, %{credential_id: credential_id}} -> {:ok, credential_id}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp spine_credential_id(_mount, _session), do: :error

  defp spine_authorized_org_ids(%Mount{} = mount, credential_id) do
    mount = identity_ns_mount(mount)
    mods = %{user: Mount.resource(mount, User), membership: Mount.resource(mount, Membership)}
    Samen.Auth.OrgActor.authorized_org_ids(mods, credential_id)
  rescue
    _ -> []
  end

  @doc """
  ADR-035 §5 A4/A5 (the CurrentOrg paragraph; T05 binding addendum) — resolve
  a SPINE credential to a per-org ACTOR map (`Samen.Scope`-actor-shaped:
  `id`/`org_id`/`role`/`kind`/`plane`), constrained to a REAL `Membership` row
  — "closing the ADR-031 carry" (the actor's role is READ from the
  Membership, never hardcoded `:member`). `nil` when `credential_id` holds no
  `User`+`Membership` in `org_id` (the RED path: a credential with no
  membership in org X cannot resolve an actor there — `Samen.Auth.OrgActor`).
  """
  @spec resolve_actor(Mount.t() | nil, String.t(), String.t()) :: map() | nil
  def resolve_actor(%Mount{} = mount, credential_id, org_id)
      when is_binary(credential_id) and is_binary(org_id) do
    mount = identity_ns_mount(mount)
    mods = %{user: Mount.resource(mount, User), membership: Mount.resource(mount, Membership)}

    case Samen.Auth.OrgActor.resolve(mods, credential_id, org_id) do
      {:ok, %{user_id: user_id, role: role, org_id: resolved_org_id}} ->
        %{id: user_id, org_id: resolved_org_id, role: role, kind: :tenant, plane: :tenant}

      :error ->
        nil
    end
  rescue
    _ -> nil
  end

  def resolve_actor(_mount, _credential_id, _org_id), do: nil

  defp param_org(params) when is_map(params), do: present(Map.get(params, "org"))
  defp param_org(_), do: nil

  defp session_org(session) when is_map(session), do: present(Map.get(session, @session_key))
  defp session_org(_), do: nil

  @doc """
  Whether the session carries an EXPLICIT act-as current org (`samen_current_org`) — i.e. the
  operator drilled in via the `SessionController` ("Open account →") or the workspace switcher.

  This is the true "impersonation" signal: it is `false` for a plain tenant default-org visit
  (the mount's `:default_org_id`, Blue Ridge in dev), so the "acting as" banner reads as a real
  act-as rather than always-on chrome. Never raises; a non-map/absent session → `false`.
  """
  @spec acting_as?(map() | nil) :: boolean()
  def acting_as?(session), do: session_org(session) != nil

  defp default_label(%Mount{} = mount), do: present(Mount.label(mount, :default_org_id, nil))
  defp default_label(_), do: nil

  defp present(v) when is_binary(v) do
    case String.trim(v) do
      "" -> nil
      _ -> v
    end
  end

  defp present(_), do: nil

  @doc """
  The list of tenant orgs this mount's seat may act on — `[{org_id, name}, …]`, sorted by name.

  Two sources, tried in order:

    1. `Mount.label(mount, :org_directory, mfa)` — a `{mod, fun, args}` the host wires (the
       tenant/shared mount can't see the operator namespace itself). The MFA returns
       `[{org_id, name}, …]`.
    2. A mount carrying `:operator_org_id` (an operator/aggregate mount) reads its accounts
       directly via `Samen.Web.Operator.Reads.accounts/3`.

  Returns `[]` when neither is available (the switcher then hides). Never raises.
  """
  @spec list_orgs(Mount.t() | nil) :: [{String.t(), String.t()}]
  def list_orgs(%Mount{} = mount) do
    case directory_mfa(mount) do
      {mod, fun, args} when is_atom(mod) and is_atom(fun) and is_list(args) ->
        invoke_directory(mod, fun, args)

      _ ->
        operator_directory(mount)
    end
  end

  def list_orgs(_), do: []

  defp directory_mfa(%Mount{} = mount), do: Mount.label(mount, :org_directory, nil)

  defp invoke_directory(mod, fun, args) do
    apply(mod, fun, args) |> normalize_directory()
  rescue
    _ -> []
  end

  # An operator/aggregate mount can read its own accounts (each an org row) directly.
  defp operator_directory(%Mount{} = mount) do
    operator_org_id = Mount.label(mount, :operator_org_id, nil) || Samen.Web.Operator.org_id(mount)

    case operator_org_id do
      nil ->
        []

      org_id ->
        scope = Samen.Web.Operator.scope(mount)

        Samen.Web.Operator.Reads.accounts(mount, scope, org_id)
        |> Enum.map(fn a -> {a.tenant_org_id, a.name} end)
        |> normalize_directory()
    end
  rescue
    _ -> []
  end

  defp normalize_directory(list) when is_list(list) do
    list
    |> Enum.flat_map(fn
      {id, name} when is_binary(id) -> [{id, to_string(name || id)}]
      %{org_id: id, name: name} when is_binary(id) -> [{id, to_string(name || id)}]
      %{id: id, name: name} when is_binary(id) -> [{id, to_string(name || id)}]
      _ -> []
    end)
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.sort_by(&elem(&1, 1))
  end

  defp normalize_directory(_), do: []

  defp first_listable_org_id(%Mount{} = mount) do
    case list_orgs(mount) do
      [{org_id, _name} | _] -> org_id
      _ -> nil
    end
  end

  defp first_listable_org_id(_), do: nil

  @doc """
  The display NAME for `org_id` on this mount — the directory name if the org is listable, else
  the mount's static `:title` label, else `"Workspace"`. This is what fixes the "header says
  Workspace" bug: the header reads the RESOLVED name, not a baked-in router string.
  """
  @spec name(Mount.t() | nil, String.t() | nil) :: String.t()
  def name(%Mount{} = mount, org_id) when is_binary(org_id) do
    case List.keyfind(list_orgs(mount), org_id, 0) do
      {^org_id, display} when is_binary(display) and display != "" -> display
      _ -> Mount.label(mount, :title, "Workspace")
    end
  end

  def name(%Mount{} = mount, _org_id), do: Mount.label(mount, :title, "Workspace")
  def name(_, _), do: "Workspace"

  # T150 F3 — the tenant DISPLAY name for `org_id` ONLY when it resolves to a real directory
  # row, else `nil` (never the mount-title fallback `name/2` uses). Lets the operator-plane
  # badge name the tenant it is viewing and fall back to the operator label otherwise.
  defp viewing_tenant_name(%Mount{} = mount, org_id) when is_binary(org_id) do
    case List.keyfind(list_orgs(mount), org_id, 0) do
      {^org_id, display} when is_binary(display) and display != "" -> display
      _ -> nil
    end
  end

  defp viewing_tenant_name(_, _), do: nil

  @doc """
  Whether the page should render the seed-state empty card: no org resolved AND the directory is
  empty (an unseeded DB). A resolved org, or a non-empty directory, is never a dead-end.
  """
  @spec no_org?(Mount.t() | nil, String.t() | nil) :: boolean()
  def no_org?(_mount, org_id) when is_binary(org_id), do: false
  def no_org?(mount, _org_id), do: list_orgs(mount) == []

  # ---------------------------------------------------------------------------
  # Components (framework — every tenant/shared vertical inherits these)
  # ---------------------------------------------------------------------------

  attr :mount, Mount, default: nil
  attr :org_id, :string, default: nil
  attr :return_to, :string, default: nil
  attr :compact, :boolean, default: false

  @doc """
  The WORKSPACE SWITCHER (ADR-013 §5.1). Renders the current org's name + a chevron; clicking
  opens a native `<details>` dropdown listing every tenant org from `list_orgs/1` plus a pinned
  operator-plane entry (return to the operator plane).

  The operator-plane entry's LABEL is derived from the mount (`operator_label/1` — the host's
  `:operator_workspace` label, neutral `"Operator"` default), NEVER a hardcoded vertical name
  (P9-F2): driftwood renders "Driftwood Ops", pawchart/uxwalk/any gen.app render THEIR own
  operator-plane name (or the neutral default) — the shared switcher no longer mislabels every
  non-driftwood host's boundary with the reference vertical's brand.

  Each tenant row links to `GET /session/org/<org_id>?return_to=<path>` (the framework
  `SessionController`), which writes the session current org and redirects back to the same
  module for the newly chosen org. Plain disclosure + links — works on the dead render, no JS
  hook, matching the ADR-012 "works before the socket connects" posture. Hidden when the
  directory is empty.

  `compact: true` (the default in the CRM/Billing/Support sidebar header, where the `.who`
  block already prints the org name) renders just the chevron so the name is not duplicated.
  """
  def switcher(assigns) do
    assigns =
      assigns
      |> assign(:orgs, switcher_orgs(assigns.mount))
      |> assign(:current_name, name(assigns.mount, assigns.org_id))
      |> assign(:operator_label, operator_label(assigns.mount))
      |> assign_new(:return_to, fn -> nil end)
      |> assign_new(:compact, fn -> false end)

    ~H"""
    <details :if={@orgs != []} class="ws-switcher" id="workspace-switcher">
      <summary class="ws-switcher-summary">
        <span :if={not @compact} class="ws-switcher-name">{@current_name}</span>
        <span class="ws-switcher-chevron">⌄</span>
      </summary>
      <div class="ws-switcher-menu" role="menu">
        <div class="ws-switcher-group">Workspaces</div>
        <a
          :for={{oid, oname} <- @orgs}
          class={["ws-switcher-item", oid == @org_id && "on"]}
          href={switch_href(oid, @return_to)}
          role="menuitem"
        >
          {oname}
        </a>
        <div class="ws-switcher-sep"></div>
        <a class="ws-switcher-item ws-switcher-ops" href="/operator/accounts" role="menuitem">
          ← {@operator_label} (operator)
        </a>
      </div>
    </details>
    """
  end

  # The switch endpoint the SessionController serves (§4.3). `return_to` keeps the viewer on the
  # same module for the newly chosen org.
  defp switch_href(org_id, nil), do: "/session/org/#{org_id}"

  defp switch_href(org_id, return_to),
    do: "/session/org/#{org_id}?return_to=#{URI.encode_www_form(return_to)}"

  # ---------------------------------------------------------------------------
  # ADR-044 Amendment-1 account-level NAME scoping in the switcher (§16.2/§16.4a,
  # T159 switcher residual)
  # ---------------------------------------------------------------------------

  @doc """
  The workspace list the switcher OFFERS as act-as targets, with ADR-044 Amendment-1
  account-level NAME scoping applied (§16.2/§16.4a, the T159 switcher residual).

  On the OPERATOR plane the switcher enumerates cross-tenant ACCOUNTS (each row IS a tenant
  org) — the SAME cross-tenant name+id surface `/operator/accounts` masks. An operator WITHOUT
  the `scope_of/2` right for an account MUST NOT see that account's NAME or `tenant_org_id`
  here, consistent with the accounts list. The mask is BY OMISSION: an out-of-scope entry is
  DROPPED ENTIRELY — no name, no org_id in any `href`/attribute — because a switcher entry is a
  pure identity + act-as affordance with NO non-identifying aggregate to preserve (unlike an
  accounts ROW, which keeps its opaque plan/health/MRR cells). Omitting is the honest analog.

  Same seam as `Samen.Web.Operator.AccountsLive.name_masked?/3`:
  `Samen.Fleet.Resolution.{configured?/1, scope_of/2, in_scope?/2}`. Preserved properties:

    * **no-lockout** — a TENANT/shared switcher, or a product wiring NO `:fleet_resolution`
      seam, keeps EVERY entry (today's behaviour). Scoping engages ONLY on an operator/aggregate
      mount whose product has the seam configured.
    * **fail-closed** — `scope_of/2` collapses to `:none` on any resolver error ⇒ every entry
      is out of scope ⇒ dropped (the switcher then hides), never leaked.

  This is NAME/id VISIBILITY in the list only — layered ON TOP of the T146/T150 act-as gate; it
  never weakens the `/session/org/` act-as authorization the chosen entry still routes through.
  """
  @spec switcher_orgs(Mount.t() | nil) :: [{String.t(), String.t()}]
  def switcher_orgs(%Mount{} = mount) do
    orgs = list_orgs(mount)

    if scope_mask_switcher?(mount) do
      scope =
        Samen.Fleet.Resolution.scope_of(
          Samen.Web.Operator.otp_app(mount),
          switcher_operator_id(mount)
        )

      Enum.filter(orgs, fn {org_id, _name} -> Samen.Fleet.Resolution.in_scope?(scope, org_id) end)
    else
      orgs
    end
  end

  def switcher_orgs(_), do: []

  # Scope-masking engages ONLY on an operator/aggregate mount (the cross-tenant switcher — the
  # residual surface) whose product has a `:fleet_resolution` seam configured. A tenant/shared
  # switcher (the seat's OWN authorized orgs) and a seam-less product both keep every entry —
  # the no-lockout property (§16.4a). `configured?/1` distinguishes "no seam ⇒ inert" from
  # "seam wired, empty scope ⇒ mask", exactly as `AccountsLive.load/1`'s `scope_masking?` does.
  # Only ever reached from `switcher_orgs/1`'s `%Mount{}` clause, so no non-mount fallback is
  # needed (a catch-all clause would be dead code the --warnings-as-errors gate rejects).
  defp scope_mask_switcher?(%Mount{} = mount) do
    badge_plane(mount) == :operator and
      Samen.Fleet.Resolution.configured?(Samen.Web.Operator.otp_app(mount))
  end

  # The operator id `scope_of/2` reads. The switcher is stateless chrome carrying no socket
  # assigns, so it uses the operator seat's well-known org id — the SAME fallback leg
  # `Samen.Web.Operator.AccountsLive.acting_operator_id/2` uses when no authenticated
  # `:samen_operator_id` principal is threaded — so the switcher's scope answer AGREES with the
  # accounts list for the same seat (the consistency property).
  defp switcher_operator_id(%Mount{} = mount), do: Samen.Web.Operator.org_id(mount)

  attr :mount, Mount, default: nil
  attr :org_id, :string, default: nil
  attr :acting_as, :boolean, default: false
  attr :operator_actor, :boolean, default: false

  @doc """
  The PLANE-LEGIBILITY BADGE (T116, P9-F3) — the persistent chrome element that makes the
  current plane + org legible on EVERY shared samen_web surface. Rendered once per page at the
  top of the main pane (via `acting_as_banner/1`, which every tenant/shared LiveView already
  calls with `mount`/`org_id`/`acting_as`, so all hosts inherit it at ≈0 authored LOC).

  It answers the two questions a person on any surface must be able to answer from the screen —
  WHICH plane am I on, and WHOSE org am I viewing — in one of three states:

    * **tenant plane** (the default; the previously UNLABELLED plane) — a tenant-glyph badge
      reading the RESOLVED org name + "Tenant plane · in the clear" (`data-plane="tenant"`).
      This is the marker that also makes an operator's silent O→T crossing legible: whatever
      tenant mount they land on (e.g. the operator-nav Notifications mislink, AMB-1/P5-F1) now
      announces "Tenant plane · <org> · in the clear" on arrival.
    * **operator plane** (masked) — an operator SHIELD-glyph badge reading the operator
      workspace name + "Operator plane · masked" (`data-plane="operator"`). Detected by the
      mount's `:operator`/`:aggregate` scope OR an operator `plane.kind`, so it fires on the
      operator's own book of business (ADR-010: operator scope on the tenant PII plane) too.
    * **operator ACTING AS a tenant** (the dangerous O→T crossing, `acting_as: true` on a
      tenant plane) — a strong-styled CROSSING marker (`data-crossing="true"`, the operator
      shield glyph, id `acting-as-bar`): "You are viewing <org> (acting as tenant)" + a
      "Return to <operator>" link UP to the operator plane. This is the human-facing
      counterpart to the T115/T38 impersonation-write audit — the crossing is VISIBLE, not
      silent. Removing this marker is a legibility regression the tests refute.

  GLYPH DISCIPLINE: exactly two glyphs across all planes — a document/org glyph for the tenant
  plane and a SHIELD glyph for operator presence (operator plane + the acting-as crossing) —
  so tenant vs operator chrome is visually distinguishable even where the sidebar glyph LETTER
  collides (uxwalk's pixel-identical blue "S", P9-F1). The badge derives colour from
  `data-plane` (CSS), so the distinction survives even a colour-blind read via the glyph shape.

  Masking: presentational only — it renders the org DISPLAY name (non-secret) + static plane
  copy. It reads no vault-routed field and carries the same masking guarantees as the page it
  wraps (CLAUDE.md plane discipline; `Samen.Api.PiiResolution` untouched).
  """
  def plane_badge(assigns) do
    mount = assigns[:mount]
    plane = badge_plane(mount)

    assigns =
      assigns
      |> assign(:plane, plane)
      |> assign(:org_name, name(mount, assigns[:org_id]))
      # T150 F3 — the tenant DISPLAY name resolved from the directory, or nil when the
      # target org does not resolve to a real tenant. Distinct from `org_name` (which falls
      # back to the mount title) so the operator badge can name the tenant it is VIEWING and
      # fall back to the operator label only when no tenant is genuinely resolved.
      |> assign(:viewing_tenant, viewing_tenant_name(mount, assigns[:org_id]))
      |> assign(:operator_label, operator_label(mount))
      |> assign(:crossing?, crossing?(assigns, plane))

    ~H"""
    <div
      :if={@crossing?}
      class="plane-badge plane-crossing acting-as-bar"
      id="acting-as-bar"
      data-plane="tenant"
      data-crossing="true"
    >
      <span class="pb-glyph-wrap" aria-hidden="true">
        <svg class="pb-glyph" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M12 3l7 3v5c0 4.5-3 7.6-7 9-4-1.4-7-4.5-7-9V6z" /><rect x="9" y="11" width="6" height="5" rx="1" /><path d="M10.5 11V9.5a1.5 1.5 0 0 1 3 0V11" /></svg>
      </span>
      <span class="acting-as-tx">
        You are viewing <b>{@org_name}</b> (acting as tenant)
      </span>
      <a class="acting-as-return" href="/operator/accounts">Return to {@operator_label} →</a>
    </div>

    <div
      :if={not @crossing? and @plane == :operator}
      class="plane-badge plane-operator"
      id="plane-badge"
      data-plane="operator"
      data-crossing="false"
    >
      <span class="pb-glyph-wrap" aria-hidden="true">
        <svg class="pb-glyph" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M12 3l7 3v5c0 4.5-3 7.6-7 9-4-1.4-7-4.5-7-9V6z" /><rect x="9" y="11" width="6" height="5" rx="1" /><path d="M10.5 11V9.5a1.5 1.5 0 0 1 3 0V11" /></svg>
      </span>
      <%!--
        T150 F3: the operator-plane badge names the TENANT being VIEWED (the resolved org
        name), not the operator workspace — an operator looking at "•••• masked" data must see
        WHOSE house they are in. Falls back to the operator label only when no target tenant is
        resolved (e.g. the cross-tenant desk with no current org). The `{operator_label}` still
        anchors the plane via the return-context pill.
      --%>
      <span class="pb-name"><b>{@viewing_tenant || @operator_label}</b></span>
      <span class="pb-pill">
        <%= if @viewing_tenant do %>Operator plane · viewing tenant · masked<% else %>Operator plane · masked<% end %>
      </span>
    </div>

    <div
      :if={not @crossing? and @plane == :tenant}
      class="plane-badge plane-tenant"
      id="plane-badge"
      data-plane="tenant"
      data-crossing="false"
    >
      <span class="pb-glyph-wrap" aria-hidden="true">
        <svg class="pb-glyph" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><rect x="4" y="3" width="16" height="18" rx="1.5" /><path d="M8 7h3M13 7h3M8 11h3M13 11h3M8 15h3M13 15h3" /></svg>
      </span>
      <span class="pb-name"><b>{@org_name}</b></span>
      <span class="pb-pill">Tenant plane · in the clear</span>
    </div>
    """
  end

  @doc """
  Backwards-compatible entry point for the ≈44 tenant/shared LiveViews that already call
  `<.acting_as_banner mount org_id acting_as />` at the top of their main pane. Delegates to
  `plane_badge/1` — the same three-state plane-legibility badge — so every host inherits the
  persistent tenant/operator plane label AND the acting-as crossing marker with no per-surface
  or per-vertical edit. (Pre-T116 this rendered ONLY the act-as crossing bar; T116 makes the
  tenant/operator plane badge persistent while preserving the exact `acting-as-bar` crossing
  contract.)
  """
  def acting_as_banner(assigns), do: plane_badge(assigns)

  # The operator-plane workspace DISPLAY name for the shared cross-plane affordances (switcher
  # return link, acting-as crossing return, no-org card), read from the host's mount label —
  # NEVER a hardcoded vertical brand (P9-F2). Neutral `"Operator"` default so a host that wires
  # nothing still labels its boundary honestly rather than mislabelling it "Driftwood Ops".
  defp operator_label(%Mount{} = mount), do: Mount.label(mount, :operator_workspace, "Operator")
  defp operator_label(_), do: "Operator"

  # The host's seed command hint for the no-org card, from the mount label (e.g. driftwood wires
  # "mix driftwood.seed"). `nil` (the default) → a generic, vertical-neutral seed instruction
  # with no host-specific mix task named.
  defp seed_command(%Mount{} = mount), do: Mount.label(mount, :seed_command, nil)
  defp seed_command(_), do: nil

  # Which plane the badge speaks for. An operator/aggregate SCOPE (the operator's own book of
  # business — tenant PII plane per ADR-010) OR an operator PLANE (masked impersonation) both
  # read as the operator plane; everything else is the tenant plane.
  defp badge_plane(%Mount{plane: %{kind: :operator}}), do: :operator
  defp badge_plane(%Mount{scope_kind: k}) when k in [:operator, :aggregate], do: :operator
  defp badge_plane(%Mount{}), do: :tenant
  defp badge_plane(_), do: :tenant

  # Whether to render the operator→tenant CROSSING marker (T116 attempt 2, defense-in-depth).
  # DERIVED FROM ACTOR CONTEXT, not solely the `samen_current_org` breadcrumb: an OPERATOR actor
  # rendering a TENANT surface IS a crossing and MUST be marked — regardless of whether the
  # sticky act-as session key happens to be set. So a FUTURE mislink that lands an authenticated
  # operator on a tenant surface can never recreate a SILENT crossing (a plain `data-plane=tenant`
  # badge byte-identical to a real tenant). Fires on EITHER signal:
  #   * `operator_actor` — the caller identified an operator principal on this tenant surface, OR
  #   * `acting_as`      — the governed `/session/org/` act-as write set the current org.
  # Only on the TENANT plane with a resolved org (an operator-plane mount self-labels as operator;
  # the crossing marker is the tenant-surface concern). The reachable-via-UI guarantee in dev —
  # where a bare tenant mount carries NO operator identity — is the STRUCTURAL BAR: operator
  # chrome offers no bare-tenant link, so the only operator→tenant path is the governed act-as.
  defp crossing?(assigns, plane) do
    (!!assigns[:acting_as] or !!assigns[:operator_actor]) and plane == :tenant and
      is_binary(assigns[:org_id])
  end

  attr :mount, Mount, default: nil

  @doc """
  The seed-state empty card (ADR-013 §4.5) — replaces the old "No org selected. Append
  `?org=<uuid>`" dead-end. Shown only when no org resolves AND the directory is empty: a
  *seed-state* message, not a *type-a-UUID* instruction, with a link back to the operator
  dashboard. It never appears once seeded.

  De-hardcoded (P9-F2): the seed command + the operator-plane return label are derived from the
  mount (`:seed_command` / `:operator_workspace` labels), so a non-driftwood host (pawchart,
  any gen.app) no longer shows "run `mix driftwood.seed`" / "Back to Driftwood Ops" in its own
  empty state. Absent a `:seed_command` label the copy is vertical-neutral (no mix task named).
  """
  def no_org_card(assigns) do
    assigns =
      assigns
      |> assign(:operator_label, operator_label(assigns[:mount]))
      |> assign(:seed_command, seed_command(assigns[:mount]))

    ~H"""
    <div class="wrap">
      <div class="card" id="no-org" style="padding:22px 20px;color:var(--muted)">
        <div style="font-weight:600;color:#2a2b35;margin-bottom:6px">No tenant accounts yet</div>
        <p style="margin:0 0 10px">
          Seed the demo to populate the workspaces<span :if={@seed_command}> — run <code>{@seed_command}</code></span>.
        </p>
        <a href="/operator/accounts" style="color:#3B4CCA;text-decoration:none">
          ← Back to {@operator_label}
        </a>
      </div>
    </div>
    """
  end
end
