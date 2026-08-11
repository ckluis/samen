defmodule Samen.Web.Notifications.Live do
  @moduledoc """
  Shared notifications LiveView helpers: mount assignment (re-exported from
  `Samen.Web.Live`) and the notifications sidebar — the inherited `module_nav` with the
  Inbox group's `nav_item` badge FED (`notifications_unread`, AC-G2-7). Host-agnostic:
  title/glyph come from `mount.labels` with neutral defaults (ADR-009).
  """
  use Phoenix.Component

  import Samen.UI
  import Samen.Web.CurrentOrg, only: [switcher: 1]

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount

  @doc "Read the mount out of the session (see `Samen.Web.Live.assign_mount/2`)."
  defdelegate assign_mount(socket, session), to: Samen.Web.Live

  @doc """
  Whether write AFFORDANCES (mark read / mark all read) are OFFERED on this mount —
  tenant plane only (the A3 posture shared by every module `Live`). POSTURE only:
  the kernel enforces regardless (OrgScope on every write; no vaulted attribute is
  ever touched by mark-read).
  """
  def writable?(%Mount{plane: %{kind: :operator}}), do: false
  def writable?(_), do: true

  attr :mount, Mount, required: true
  attr :org_id, :string, default: nil
  attr :active, :atom, default: :notifications
  attr :return_to, :string, default: nil
  attr :unread, :any, default: nil, doc: "the unread count feeding the nav badge (AC-G2-7)"

  @doc """
  The notifications sidebar — workspace header (the resolved current-org name) + the
  inherited `module_nav` with the Notifications badge lit.
  """
  def notifications_sidebar(assigns) do
    ~H"""
    <.sidebar
      title={CurrentOrg.name(@mount, @org_id)}
      subtitle="Inbox"
      logo={Mount.label(@mount, :glyph, "S")}
      logo_style={Mount.label(@mount, :crm_logo_style, "background:linear-gradient(150deg,#B45309,#F59E0B)")}
    >
      <:switcher>
        <.switcher mount={@mount} org_id={@org_id} return_to={@return_to} compact />
      </:switcher>

      <.module_nav org_id={@org_id} active={@active} notifications_unread={@unread}>
        <:extra><.host_nav_extra mount={@mount} org_id={@org_id} /></:extra>
      </.module_nav>

      <:footer>
        <div class="foot">
          <div class="av" style="background:#FDE9D2;color:#B45309">{Mount.label(@mount, :user_initials, "S")}</div>
          <div class="m">
            <b>{Mount.label(@mount, :user_name, "Signed in")}</b><span>{Mount.label(@mount, :user_role, "member")}</span>
          </div>
        </div>
      </:footer>
    </.sidebar>
    """
  end
end
