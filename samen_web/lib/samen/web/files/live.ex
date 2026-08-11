defmodule Samen.Web.Files.Live do
  @moduledoc """
  Shared files LiveView helpers: mount assignment (re-exported from `Samen.Web.Live`),
  the write-posture gate, and the files sidebar — the inherited `module_nav` for the
  files surface (WS-E E2.1; ADR-026).

  Host-agnostic: title/glyph come from `mount.labels` with neutral defaults.
  """
  use Phoenix.Component

  import Samen.UI
  import Samen.Web.CurrentOrg, only: [switcher: 1]

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount

  @doc "Read the mount out of the session (see `Samen.Web.Live.assign_mount/2`)."
  defdelegate assign_mount(socket, session), to: Samen.Web.Live

  @doc """
  Whether upload/write affordances are OFFERED on this mount — tenant plane only
  (the standard A3 posture). POSTURE only: the kernel enforces size/type + ChokepointGuard
  regardless of plane.
  """
  def writable?(%Mount{plane: %{kind: :operator}}), do: false
  def writable?(_), do: true

  attr :mount, Mount, required: true
  attr :org_id, :string, default: nil
  attr :active, :atom, default: :files
  attr :return_to, :string, default: nil

  @doc """
  The files sidebar — workspace header + the inherited `module_nav` with the files
  group active.
  """
  def files_sidebar(assigns) do
    ~H"""
    <.sidebar
      title={CurrentOrg.name(@mount, @org_id)}
      subtitle="Files"
      logo={Mount.label(@mount, :glyph, "S")}
      logo_style={Mount.label(@mount, :crm_logo_style, "background:linear-gradient(150deg,#B45309,#F59E0B)")}
    >
      <:switcher>
        <.switcher mount={@mount} org_id={@org_id} return_to={@return_to} compact />
      </:switcher>

      <.module_nav org_id={@org_id} active={@active}>
        <:extra><.host_nav_extra mount={@mount} org_id={@org_id} /></:extra>
      </.module_nav>

      <:footer>
        <div class="foot">
          <div class="av" style="background:#FDE9D2;color:#B45309">{Mount.label(@mount, :user_initials, "S")}</div>
          <div class="m">
            <b>{Mount.label(@mount, :user_name, "Signed in")}</b>
            <span>{Mount.label(@mount, :user_role, "member")}</span>
          </div>
        </div>
      </:footer>
    </.sidebar>
    """
  end
end
