defmodule Samen.Web.Marketing.Live do
  @moduledoc """
  Shared Marketing LiveView helpers (ADR-011 §7): mount assignment (re-exported from
  `Samen.Web.Live`) and the Marketing sidebar. Mirrors `Samen.Web.CRM.Live` — the sidebar is
  HOST-AGNOSTIC (workspace title / glyph from `mount.labels`), and the Marketing nav group is
  the framework single source of truth (`Samen.UI.module_nav/1`), so every vertical inherits
  the campaigns / segments / leads nav identically.
  """
  use Phoenix.Component

  import Samen.UI

  alias Samen.Web.Mount

  @doc "Read the mount out of the session (see `Samen.Web.Live.assign_mount/2`)."
  defdelegate assign_mount(socket, session), to: Samen.Web.Live

  attr :mount, Mount, required: true
  attr :org_id, :string, default: nil
  attr :active, :atom, default: nil

  @doc "The Marketing sidebar — workspace header (from `mount.labels`) + the inherited `module_nav`."
  def marketing_sidebar(assigns) do
    ~H"""
    <.sidebar
      title={Mount.label(@mount, :title, "Workspace")}
      subtitle="Marketing"
      logo={Mount.label(@mount, :glyph, "S")}
      logo_style={Mount.label(@mount, :crm_logo_style, "background:linear-gradient(150deg,#0E7C5A,#17A06E)")}
    >
      <:search>
        <div class="search">
          <svg class="i" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <circle cx="11" cy="11" r="7" /><path d="m21 21-4.3-4.3" />
          </svg>
          Search campaigns, segments…
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

  @doc "The Marketing plane note copy (tenant = clear / operator = masked), reused across pages."
  def marketing_plane_note(%Mount{plane: %{kind: :operator}}), do: "operator plane · masked"
  def marketing_plane_note(_), do: "your org in the clear"

  @doc "The mount's Marketing path prefix (labels-driven, default `/marketing`)."
  def marketing_path(mount), do: Mount.label(mount, :marketing_path, "/marketing")
end
