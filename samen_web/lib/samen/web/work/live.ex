defmodule Samen.Web.Work.Live do
  @moduledoc """
  Shared Work LiveView helpers: mount assignment + the host-agnostic Work sidebar
  (workspace branding from `mount.labels`). Same ADR-009 pattern as
  `Samen.Web.Support.Live`.
  """
  use Phoenix.Component

  import Samen.UI
  import Samen.Web.CurrentOrg, only: [switcher: 1]

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount

  defdelegate assign_mount(socket, session), to: Samen.Web.Live

  @doc """
  Whether write AFFORDANCES (New task, status changes, Delete) are OFFERED on this
  mount — tenant plane only (mirrors `Samen.Web.Support.Live.writable?/1`).

  UX only, not enforcement: the kernel enforces regardless (OrgScope +
  RoleAtLeast on every write) — hiding the affordance never substitutes for the
  write-path red-path tests.
  """
  def writable?(%Mount{plane: %{kind: :operator}}), do: false
  def writable?(_), do: true

  attr :mount, Mount, required: true
  attr :org_id, :string, default: nil
  attr :active, :atom, default: nil
  attr :return_to, :string, default: nil

  def work_sidebar(assigns) do
    ~H"""
    <.sidebar
      title={CurrentOrg.name(@mount, @org_id)}
      subtitle="Work"
      logo={Mount.label(@mount, :glyph, "W")}
      logo_style={Mount.label(@mount, :work_logo_style, "background:linear-gradient(150deg,#1D4ED8,#4338CA)")}
    >
      <:switcher>
        <.switcher mount={@mount} org_id={@org_id} return_to={@return_to} compact />
      </:switcher>
      <:search>
        <.search_box org_id={@org_id} placeholder="Search tasks, projects…" />
      </:search>

      <.nav_group label="Work">
        <.nav_item label="Tasks" href={"#{work_path(@mount)}?org=#{@org_id}"} active={@active == :work_tasks}>
          <:icon>
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M9 12l2 2 4-4" /><circle cx="12" cy="12" r="9" /></svg>
          </:icon>
        </.nav_item>
        <.nav_item label="Projects" href={"#{work_path(@mount)}/projects?org=#{@org_id}"} active={@active == :work_projects}>
          <:icon>
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><rect x="3" y="4" width="18" height="16" rx="2" /><path d="M3 9h18" /></svg>
          </:icon>
        </.nav_item>
      </.nav_group>

      <:footer>
        <div class="foot">
          <div class="av" style="background:#DBEAFE;color:#1E3A8A">{Mount.label(@mount, :user_initials, "W")}</div>
          <div class="m">
            <b>{Mount.label(@mount, :user_name, "Signed in")}</b><span>{Mount.label(@mount, :user_role, "member")}</span>
          </div>
        </div>
      </:footer>
    </.sidebar>
    """
  end

  @doc "The Work mount path prefix, honoring a host label override (default `/work`)."
  def work_path(mount), do: Mount.label(mount, :work_path, "/work")
end
