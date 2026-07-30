defmodule Samen.Web.Automation.Live do
  @moduledoc """
  Shared AUTOMATION LiveView helpers (ADR-039 §12 done-criterion 4; T118): mount
  assignment (re-exported from `Samen.Web.Live`), the `writable?/1` posture, and the
  builder sidebar.

  ## Tenant plane only (INV-2)

  Unlike `Samen.Web.Flags.Live` (which the `writable?/1` shape is modeled on), THIS
  surface is never mounted on the operator plane at all — `samen_automation_routes/3`
  offers no `:plane` option (see its moduledoc). `writable?/1` is kept for the same
  defensive-posture reason every other module `Live` keeps it (a belt-and-suspenders
  UI guard alongside the kernel's own `OrgScope` + `RoleAtLeast :member` enforcement)
  even though the only mount this framework ships is already tenant.
  """
  use Phoenix.Component

  @doc "Read the mount out of the session (see `Samen.Web.Live.assign_mount/2`)."
  defdelegate assign_mount(socket, session), to: Samen.Web.Live

  @doc """
  Whether write AFFORDANCES (new/edit/pause/resume/run-now) are OFFERED on this
  mount. POSTURE only — the kernel enforces regardless (`OrgScope` +
  `RoleAtLeast :member` on every workflow write; `NonPiiPredicates` refuses an
  ineligible condition/interpolation key at the write boundary either way).
  """
  def writable?(%Samen.Web.Mount{plane: %{kind: :operator}}), do: false
  def writable?(_), do: true

  attr :mount, Samen.Web.Mount, required: true
  attr :org_id, :string, default: nil
  attr :active, :atom, default: :automation
  attr :return_to, :string, default: nil

  @doc "The tenant automation-builder sidebar — workspace header + the Settings nav group."
  def automation_sidebar(assigns) do
    ~H"""
    <Samen.UI.sidebar
      title={Samen.Web.CurrentOrg.name(@mount, @org_id)}
      subtitle="Settings"
      logo={Samen.Web.Mount.label(@mount, :glyph, "S")}
      logo_style={Samen.Web.Mount.label(@mount, :crm_logo_style, "background:linear-gradient(150deg,#3B4CCA,#5B6EE8)")}
    >
      <:switcher>
        <Samen.Web.CurrentOrg.switcher mount={@mount} org_id={@org_id} return_to={@return_to} compact />
      </:switcher>

      <Samen.UI.nav_group label="Settings">
        <Samen.UI.nav_item
          label="Automation"
          href={Samen.Web.Mount.label(@mount, :automation_path, "/automation")}
          active={@active == :automation}
        >
          <:icon>
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
              <path d="M13 2 3 14h7l-1 8 10-12h-7l1-8Z" />
            </svg>
          </:icon>
        </Samen.UI.nav_item>
      </Samen.UI.nav_group>

      <:footer>
        <div class="foot">
          <div class="av" style="background:#DDE2F5;color:#3B4CCA">{Samen.Web.Mount.label(@mount, :user_initials, "S")}</div>
          <div class="m">
            <b>{Samen.Web.Mount.label(@mount, :user_name, "Signed in")}</b><span>{Samen.Web.Mount.label(@mount, :user_role, "admin")}</span>
          </div>
        </div>
      </:footer>
    </Samen.UI.sidebar>
    """
  end
end
