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

  @doc """
  Whether write AFFORDANCES (New ticket, the reply composer, status changes, Delete)
  are OFFERED on this mount — tenant plane only (the ADR-011 §6.3 posture, same as
  `Samen.Web.CRM.Live.writable?/1`).

  This is UX, not enforcement: the kernel enforces regardless (OrgScope + RoleAtLeast
  on every write; `Samen.Pii.WriteGuard` rejects an operator-plane plaintext write to
  the vaulted `Message.body` at the Ash write path — MC-1 / Invariant L1). Hiding the
  affordance never substitutes for the write-path red-path tests.
  """
  def writable?(%Mount{plane: %{kind: :operator}}), do: false
  def writable?(_), do: true

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
        <.search_box org_id={@org_id} placeholder="Search tickets, agents…" />
      </:search>

      <.module_nav org_id={@org_id} active={@active}>
        <:extra><.host_nav_extra mount={@mount} org_id={@org_id} /></:extra>
      </.module_nav>

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
