defmodule Samen.Web.CRM.Live do
  @moduledoc """
  Shared CRM LiveView helpers: mount assignment (re-exported from `Samen.Web.Live`) and the
  CRM sidebar component. The sidebar is HOST-AGNOSTIC — its workspace title / glyph / logo
  gradient come from `mount.labels` (per-host branding) with neutral framework defaults, so
  Driftwood shows "Blue Ridge Logistics / B" and a bare mount shows "Workspace / S". This is
  the ADR-009 rule: vertical-specific COPY is data on the mount, not forked code.
  """
  use Phoenix.Component

  import Samen.UI
  import Samen.Web.CurrentOrg, only: [switcher: 1]

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount

  @doc "Read the mount out of the session (see `Samen.Web.Live.assign_mount/2`)."
  defdelegate assign_mount(socket, session), to: Samen.Web.Live

  attr :mount, Mount, required: true
  attr :org_id, :string, default: nil
  attr :active, :atom, default: nil
  attr :return_to, :string, default: nil

  @doc """
  The CRM sidebar — workspace header (the RESOLVED current-org name, ADR-013 §4.6) with the
  functional workspace switcher in the header slot + the inherited `module_nav`.
  """
  def crm_sidebar(assigns) do
    ~H"""
    <.sidebar
      title={CurrentOrg.name(@mount, @org_id)}
      subtitle="CRM"
      logo={Mount.label(@mount, :glyph, "S")}
      logo_style={Mount.label(@mount, :crm_logo_style, "background:linear-gradient(150deg,#0E7C5A,#17A06E)")}
    >
      <:switcher>
        <.switcher mount={@mount} org_id={@org_id} return_to={@return_to} compact />
      </:switcher>
      <:search>
        <div class="search">
          <svg class="i" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <circle cx="11" cy="11" r="7" /><path d="m21 21-4.3-4.3" />
          </svg>
          Search companies, contacts…
          <span class="kbd">⌘K</span>
        </div>
      </:search>

      <.module_nav org_id={@org_id} active={@active} />

      <:footer>
        <div class="foot">
          <div class="av" style="background:#D6E9DF;color:#1E7A45">{Mount.label(@mount, :user_initials, "S")}</div>
          <div class="m">
            <b>{Mount.label(@mount, :user_name, "Signed in")}</b><span>{Mount.label(@mount, :user_role, "member")}</span>
          </div>
        </div>
      </:footer>
    </.sidebar>
    """
  end
end
