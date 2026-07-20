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
  session carrying an unauthorized org yields no actor for it here. Dev/test keep the query-param
  convenience unchanged (the gate is off unless the mount opts in).
  """
  @spec resolve(Mount.t() | nil, map(), map()) :: String.t() | nil
  def resolve(mount, params, session) do
    if authn_required?(mount) do
      resolve_authorized(mount, params, session)
    else
      param_org(params) ||
        session_org(session) ||
        default_label(mount) ||
        first_listable_org_id(mount)
    end
  end

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

  # The fail-closed prod path: an authenticated principal, constrained to its authorized orgs.
  defp resolve_authorized(mount, params, session) do
    with user_id when is_binary(user_id) <- Samen.Web.Auth.authenticated_user_id(session),
         [_ | _] = authorized <- authorized_org_ids(mount, user_id) do
      requested = param_org(params) || session_org(session)
      if requested in authorized, do: requested, else: List.first(authorized)
    else
      _ -> nil
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
  "Driftwood Ops" entry (return to the operator plane).

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
      |> assign(:orgs, list_orgs(assigns.mount))
      |> assign(:current_name, name(assigns.mount, assigns.org_id))
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
          ← Driftwood Ops (operator)
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

  attr :mount, Mount, default: nil
  attr :org_id, :string, default: nil
  attr :acting_as, :boolean, default: false

  @doc """
  The "acting as &lt;tenant&gt; · Return to Driftwood Ops" banner (ADR-013 §5.3). Renders on a
  tenant-plane page ONLY during a real operator act-as (`acting_as: true` — an explicit
  `samen_current_org` in the session, set by the `SessionController` via the operator "Open
  account →" or the workspace switcher), NOT on a plain tenant default-org visit. Gives the
  operator a clear way back UP to the operator plane. Purely presentational; navigating away
  just returns to the operator plane (which ignores the session current org — it is cross-tenant).

  The org NAME is resolved in the body from `mount` + `org_id`, so the banner always shows the
  real current-org name (no empty `<b>`).
  """
  def acting_as_banner(assigns) do
    assigns = assign(assigns, :name, name(assigns.mount, assigns.org_id))

    ~H"""
    <div
      :if={@acting_as and tenant_plane?(@mount) and is_binary(@org_id)}
      class="acting-as-bar"
      id="acting-as-bar"
    >
      <span class="acting-as-tx">
        You are viewing <b>{@name}</b> (acting as tenant)
      </span>
      <a class="acting-as-return" href="/operator/accounts">Return to Driftwood Ops →</a>
    </div>
    """
  end

  attr :mount, Mount, default: nil

  @doc """
  The seed-state empty card (ADR-013 §4.5) — replaces the old "No org selected. Append
  `?org=<uuid>`" dead-end. Shown only when no org resolves AND the directory is empty: a
  *seed-state* message, not a *type-a-UUID* instruction, with a link back to the operator
  dashboard. It never appears once seeded.
  """
  def no_org_card(assigns) do
    ~H"""
    <div class="wrap">
      <div class="card" id="no-org" style="padding:22px 20px;color:var(--muted)">
        <div style="font-weight:600;color:#2a2b35;margin-bottom:6px">No tenant accounts yet</div>
        <p style="margin:0 0 10px">
          Seed the demo to populate the workspaces — run <code>mix driftwood.seed</code>.
        </p>
        <a href="/operator/accounts" style="color:#3B4CCA;text-decoration:none">
          ← Back to Driftwood Ops
        </a>
      </div>
    </div>
    """
  end

  defp tenant_plane?(%Mount{plane: %{kind: :operator}}), do: false
  defp tenant_plane?(%Mount{}), do: true
  defp tenant_plane?(_), do: false
end
