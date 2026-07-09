defmodule Samen.Web.Support.Live do
  @moduledoc """
  Shared Support LiveView helpers: mount assignment + the host-agnostic Support sidebar
  (workspace branding from `mount.labels`). Same ADR-009 pattern as `Samen.Web.CRM.Live`.
  """
  use Phoenix.Component

  import Samen.UI
  import Samen.Web.CurrentOrg, only: [switcher: 1]

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount

  defdelegate assign_mount(socket, session), to: Samen.Web.Live

  attr :mount, Mount, required: true
  attr :org_id, :string, default: nil
  attr :active, :atom, default: nil
  attr :return_to, :string, default: nil

  def support_sidebar(assigns) do
    ~H"""
    <.sidebar
      title={CurrentOrg.name(@mount, @org_id)}
      subtitle="Support"
      logo={Mount.label(@mount, :glyph, "S")}
      logo_style={Mount.label(@mount, :support_logo_style, "background:linear-gradient(150deg,#B45309,#D97706)")}
    >
      <:switcher>
        <.switcher mount={@mount} org_id={@org_id} return_to={@return_to} compact />
      </:switcher>
      <:search>
        <div class="search">
          <svg class="i" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <circle cx="11" cy="11" r="7" /><path d="m21 21-4.3-4.3" />
          </svg>
          Search tickets, agents…
          <span class="kbd">⌘K</span>
        </div>
      </:search>

      <.module_nav org_id={@org_id} active={@active} />

      <:footer>
        <div class="foot">
          <div class="av" style="background:#FEF3C7;color:#92400E">{Mount.label(@mount, :user_initials, "S")}</div>
          <div class="m">
            <b>{Mount.label(@mount, :user_name, "Signed in")}</b><span>{Mount.label(@mount, :user_role, "member")}</span>
          </div>
        </div>
      </:footer>
    </.sidebar>
    """
  end
end
