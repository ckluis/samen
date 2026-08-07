defmodule Samen.Web.Operator.Live do
  @moduledoc """
  Shared operator-workspace LiveView helpers: mount assignment (re-exported from
  `Samen.Web.Live`) and the operator sidebar with the operator nav
  (Accounts · Platform billing · Revenue · Analytics · Desk · Flags · Portfolio —
  ADR-010 §7.1; Revenue is the WS-B / B3 G7 surface, Analytics the WS-B / B8 G12 seed).

  The operator workspace is host-agnostic: its title/glyph come from `mount.labels` with
  neutral defaults, exactly as the CRM/Billing/Support sidebars (ADR-009). The nav is the
  framework's; a host supplies only branding copy on the mount.
  """
  use Phoenix.Component

  import Samen.UI
  import Samen.Web.CurrentOrg, only: [switcher: 1]

  alias Samen.Web.Mount

  @doc "Read the mount out of the session (see `Samen.Web.Live.assign_mount/2`)."
  defdelegate assign_mount(socket, session), to: Samen.Web.Live

  @doc """
  Whether the operator workspace offers write AFFORDANCES on this mount (A3 posture,
  same rule as the CRM/Billing/Support/Marketing `Live` modules): the operator's own
  book-of-business workspace runs on the operator org's TENANT plane (ADR-010 §7.2) —
  writable. A `plane: :operator` (impersonation) mount is read-only UI. This is
  POSTURE only; the ENFORCEMENT is the kernel's (`OrgScope`, `RoleAtLeast`, and
  `Samen.Pii.WriteGuard` at the Ash write path — MC-1).
  """
  def writable?(%Mount{plane: %{kind: :operator}}), do: false
  def writable?(_), do: true

  attr :mount, Mount, default: nil
  attr :active, :atom, default: nil

  @doc """
  The operator control-plane sidebar — workspace header + the operator nav group.

  INVARIANT (T116 P9-F2/AMB-1, attempt 2): every operator-chrome nav link stays on the
  operator plane (`/operator/*`); the ONLY operator→tenant affordance is the GOVERNED
  "Act as a tenant →" switcher in the footer, which routes through `/session/org/<id>`
  (the `SessionController` write) so the crossing sets the acting-as context and trips the
  `plane_badge` crossing marker. NO operator nav link may target a BARE tenant-plane surface
  (`/notifications`, `/crm`, `/billing`, …): a raw operator→tenant link is the silent-crossing
  bug the verifier reproduced (an operator landing on a tenant inbox with `data-plane=tenant`
  and NO `#acting-as-bar`, byte-identical to a real tenant). The prior `Notifications` item
  linked to bare `/notifications` and is REMOVED — the operator plane mounts no notifications
  surface (no `/operator/notifications` route, no `active: :notifications` LiveView), so it was
  a vestigial mislink, not a feature. `operator_sidebar_link_invariant_test.exs` proves the bar
  (a bare-tenant href fails the test).
  """
  def operator_sidebar(assigns) do
    ~H"""
    <.sidebar
      title={label(@mount, :operator_workspace, "Operator")}
      subtitle="Control plane"
      logo={label(@mount, :operator_glyph, "S")}
      logo_style={label(@mount, :operator_logo_style, "background:linear-gradient(150deg,#3B4CCA,#5B6EE8)")}
    >
      <:search>
        <div class="search">
          <svg class="i" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <circle cx="11" cy="11" r="7" /><path d="m21 21-4.3-4.3" />
          </svg>
          Search accounts, tenants…
          <span class="kbd">⌘K</span>
        </div>
      </:search>

      <.nav_group label="Operator plane">
        <.nav_item label="Accounts" href="/operator/accounts" active={@active == :accounts}>
          <:icon>
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><rect x="3" y="4" width="18" height="16" rx="2" /><path d="M3 9h18" /></svg>
          </:icon>
        </.nav_item>
        <.nav_item label="Platform billing" href="/operator/billing" active={@active == :billing}>
          <:icon>
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M12 2v20M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6" /></svg>
          </:icon>
        </.nav_item>
        <.nav_item label="Revenue" href="/operator/revenue" active={@active == :revenue}>
          <:icon>
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M3 17l6-6 4 4 8-8" /><path d="M14 7h7v7" /></svg>
          </:icon>
        </.nav_item>
        <.nav_item label="Analytics" href="/operator/analytics" active={@active == :analytics}>
          <:icon>
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M3 12h4l3-8 4 16 3-8h4" /></svg>
          </:icon>
        </.nav_item>
        <.nav_item label="Desk" href="/operator/desk" active={@active == :desk}>
          <:icon>
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z" /></svg>
          </:icon>
        </.nav_item>
        <.nav_item label="Flags" href="/operator/flags" active={@active == :flags}>
          <:icon>
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M4 21V4" /><path d="M4 4h12l-2 4 2 4H4" /></svg>
          </:icon>
        </.nav_item>
        <.nav_item label="Webhook DLQ" href="/operator/webhooks" active={@active == :webhooks}>
          <:icon>
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M12 2v6m0 0 3-3m-3 3L9 5" /><path d="M5 12a7 7 0 0 0 7 7 7 7 0 0 0 7-7" /></svg>
          </:icon>
        </.nav_item>
        <%!--
          WS-J fleet cockpit (ADR-044, T84b) — a TOP-LEVEL tier-1/2 platform surface (unlike
          Deliverability/Automation/Activity below, which are per-tenant drill-ins with no
          top-level index). Rendered ONLY on a `fleet_cockpit: true` mount (§6.3's `roles[:fleet]`
          gate runs inside `FleetLive` itself; this nav item is chrome, not the gate).
        --%>
        <.nav_item :if={Mount.label(@mount, :fleet_cockpit, false)} label="Fleet" href="/operator/fleet" active={@active == :fleet}>
          <:icon>
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><rect x="3" y="3" width="7" height="7" rx="1" /><rect x="14" y="3" width="7" height="7" rx="1" /><rect x="3" y="14" width="7" height="7" rx="1" /><rect x="14" y="14" width="7" height="7" rx="1" /></svg>
          </:icon>
        </.nav_item>
        <%!--
          T149 P1 — the Deliverability / Automation / Activity items are REMOVED from the
          top-level operator nav. Each is a per-TENANT drill-in (`/operator/deliverability/:org_id`,
          `/operator/automation/:org_id`, `/operator/activity/:org_id`) with NO top-level index
          route — they are reached by drilling into a SPECIFIC account (the account drill-down's
          "Deliverability → / Automation health → / Activity →" links). Their prior top-level
          `href="/operator/accounts"` dumped the operator on the Accounts page while marking the
          WRONG nav item active — a mislink, not a feature (exactly the vestigial "Notifications"
          mislink the moduledoc above already removed). `operator_sidebar_link_invariant_test.exs`
          proves no bare-tenant/off-plane href remains; there is no `active: :deliverability |
          :automation | :activity` case here because no top-level surface exists to be active.
        --%>
        <.nav_item label="Portfolio" href="/operator/aggregate" active={@active == :aggregate}>
          <:icon>
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M4 19V9m6 10V5m6 14v-7" /></svg>
          </:icon>
        </.nav_item>
      </.nav_group>

      <:footer>
        <div class="op-act-as" id="operator-act-as">
          <div class="grp">Act as a tenant →</div>
          <.switcher :if={@mount} mount={@mount} return_to="/broker" />
        </div>
        <div class="foot">
          <div class="av" style="background:#DDE2F5;color:#3B4CCA">{label(@mount, :operator_initials, "OP")}</div>
          <div class="m">
            <b>{label(@mount, :operator_user, "Operator")}</b><span>{label(@mount, :operator_role, "SaaS staff")}</span>
          </div>
        </div>
      </:footer>
    </.sidebar>
    """
  end

  @doc "Dollars from cents, for the operator money columns."
  def dollars(cents) when is_integer(cents),
    do: "$#{:erlang.float_to_binary(cents / 100, decimals: 2)}"

  def dollars(_), do: "$0.00"

  @doc "Render a resolved PII value (plaintext string or `%Samen.Masked{}`) — NEVER unwraps."
  def render_name(%Samen.Masked{} = masked), do: masked

  def render_name(name) when is_binary(name) do
    case Jason.decode(name) do
      {:ok, %{"first" => first, "last" => last}} -> String.trim("#{first} #{last}")
      _ -> name
    end
  end

  def render_name(%Samen.Type.FullName{first: first, last: last}),
    do: String.trim("#{first} #{last}")

  def render_name(nil), do: "—"
  def render_name(other), do: other

  @doc "Render the first email of a resolved emails value — NEVER unwraps a `%Masked{}`."
  def render_email(%Samen.Masked{} = masked), do: masked
  def render_email(%Samen.Type.Emails{entries: entries}), do: render_email(entries)

  def render_email(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> render_email(list)
      {:ok, %{"address" => addr}} -> addr
      _ -> json
    end
  end

  def render_email(list) when is_list(list) do
    case List.first(list) do
      %{"address" => addr} -> addr
      %{address: addr} -> addr
      _ -> "—"
    end
  end

  def render_email(_), do: "—"

  defp label(nil, _key, default), do: default
  defp label(%Mount{} = mount, key, default), do: Mount.label(mount, key, default)
end
