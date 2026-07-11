defmodule Samen.Web.Operator.Live do
  @moduledoc """
  Shared operator-workspace LiveView helpers: mount assignment (re-exported from
  `Samen.Web.Live`) and the operator sidebar with the four-tab operator nav
  (Accounts · Platform billing · Desk · Portfolio — ADR-010 §7.1).

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
  attr :notifications_path, :string, default: "/notifications"

  attr :notifications_unread, :any,
    default: nil,
    doc: "unread count feeding the Notifications nav badge (nil → unlit; AC-G2-7)"

  @doc "The operator control-plane sidebar — workspace header + the operator nav group."
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
        <.nav_item label="Desk" href="/operator/desk" active={@active == :desk}>
          <:icon>
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z" /></svg>
          </:icon>
        </.nav_item>
        <.nav_item label="Portfolio" href="/operator/aggregate" active={@active == :aggregate}>
          <:icon>
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M4 19V9m6 10V5m6 14v-7" /></svg>
          </:icon>
        </.nav_item>
        <.nav_item
          label="Notifications"
          href={@notifications_path}
          active={@active == :notifications}
          count={@notifications_unread}
        >
          <:icon>
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M18 8a6 6 0 1 0-12 0c0 7-3 9-3 9h18s-3-2-3-9" /><path d="M13.7 21a2 2 0 0 1-3.4 0" /></svg>
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
