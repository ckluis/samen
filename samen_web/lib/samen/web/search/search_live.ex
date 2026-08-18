defmodule Samen.Web.Search.SearchLive do
  @moduledoc """
  The framework ⌘K SEARCH page (WS-E E4.3; ADR-027) — mounted at `/search` by
  `Samen.Web.Router.samen_search_routes/3`. Zero authored search LiveViews per vertical:
  this one page drives the `Samen.UI.command_palette` over the KERNEL `Samen.Search`
  engine for whatever resources the mount's domain registered in its `SearchIndex`.

  ## What it wires (and what it does NOT re-implement)

    * The QUERY is the kernel `Samen.Search.query/3` — registry-gated, org-scoped,
      ranked, bounded, and per-plane PII-projected. This LiveView adds NO query logic;
      it hands the mount's facts (candidate resources, the `SearchIndex` module, the
      repo) and the acting scope to the engine.
    * The RENDER is `Samen.UI.command_palette/1`, which shows ONLY the engine's bounded
      NON-PII `display` allowlist — the masking guarantee lives at the query seam, so
      this surface cannot re-introduce a leak.

  ## Plane posture

  On the operator plane the SAME page runs the SAME engine — every result row's vaulted
  fields are `%Samen.Masked{}` (`••••`) by construction (the E4.2 red-path proves it).
  The palette renders identically on either plane; only the resolver decides
  clear-vs-`••••`.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Live, only: [assign_mount: 2]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1]

  alias Samen.Search
  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount

  @limit 20

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    mount = socket.assigns[:samen_mount]
    org_id = CurrentOrg.resolve(mount, params, session)

    socket =
      socket
      |> assign(:return_to, CurrentOrg.return_path(params))
      |> load(org_id, params["q"] || "")

    {:ok, socket}
  end

  @doc """
  Assign the page state for `org_id` + term `q`: the acting org, the echoed term, and
  the ranked masked-safe results from the engine. Exposed as the framework page-load
  seam (the same shape the render harness drives).
  """
  def load(socket, org_id, q \\ "") do
    socket
    |> Phoenix.Component.assign(:org_id, org_id)
    |> Phoenix.Component.assign(:q, q)
    |> Phoenix.Component.assign(:results, run(socket.assigns[:samen_mount], org_id, q))
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, load(socket, socket.assigns.org_id, q)}
  end

  # The one call into the engine — mount facts + acting scope in, ranked masked-safe
  # results out. No org / blank term → no results (the engine is fail-closed anyway).
  defp run(_mount, nil, _q), do: []

  defp run(%Mount{} = mount, org_id, q) do
    Search.query(Mount.scope(mount, org_id), q,
      resources: searchable_resources(mount),
      search_index: Mount.resource(mount, SearchIndex),
      repo: mount.repo,
      limit: @limit
    )
  rescue
    _ -> []
  end

  defp run(_mount, _org_id, _q), do: []

  # The candidate resources are the mount domain's resources MINUS the registry itself.
  defp searchable_resources(%Mount{domain: domain} = mount) do
    index = Mount.resource(mount, SearchIndex)

    domain
    |> Ash.Domain.Info.resources()
    |> Enum.reject(&(&1 == index))
  rescue
    _ -> []
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.app_shell>
      <:sidebar>
        <.sidebar
          title={CurrentOrg.name(@samen_mount, @org_id)}
          subtitle="Search"
          logo={Mount.label(@samen_mount, :glyph, "S")}
        >
          <:search>
            <.search_box org_id={@org_id} />
          </:search>
          <.module_nav org_id={@org_id} active={:search}>
            <:extra><.host_nav_extra mount={@samen_mount} org_id={@org_id} /></:extra>
          </.module_nav>
        </.sidebar>
      </:sidebar>

      <.topbar title="Search" crumbs={["Search"]} />

      <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

      <%= if is_nil(@org_id) do %>
        <.no_org_card mount={@samen_mount} />
      <% else %>
        <div class="pane">
          <.command_palette id="cmdk" q={@q} results={@results} event="search" />
        </div>
      <% end %>
    </.app_shell>
    """
  end
end
