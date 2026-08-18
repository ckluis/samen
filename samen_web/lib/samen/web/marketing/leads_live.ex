defmodule Samen.Web.Marketing.LeadsLive do
  @moduledoc """
  Framework Marketing / Leads lens (`/marketing/leads`) — the prospecting leads list
  (ADR-011 §8). A filtered CRM contacts read: the org's `<crm_ns>.Person` rows whose Tier-1
  `custom["lifecycle_stage"]` is in the early funnel (`lead → mql → sql`), rendered with the
  lifecycle pill + resolved email + a quick "Add to audience" affordance.

  ## Cross-domain read

  The Marketing mount's namespace is the host's Marketing domain, but leads live on the CRM
  `Person`. The host wires the CRM namespace onto the Marketing mount via the `:crm_namespace`
  label; this LiveView derives a CRM-kind mount (same repo + plane) to read contacts through
  the SAME `Samen.Web.CRM.Reads` (so PII is plane-resolved: tenant clear / operator ••••).
  If no `:crm_namespace` label is set, the leads list is empty (the lens is inert rather than
  crashing) — a host that wants the lens sets the label in its `samen_module_routes` call.

  ## MASKING INVARIANT

  Names/emails render through `Samen.Web.CRM.Reads` → `PiiResolution`. A `%Masked{}` renders
  `••••` verbatim; this LiveView has no plaintext bypass.

  ## A3 retrofit — ListLive over the bounded leads read

  The lens rides the A2 kit contract: `use Samen.Web.ListLive` + the BOUNDED
  `Samen.Web.CRM.Reads.leads_page/3` (lifecycle filter applied SERVER-SIDE before the
  keyset window) buys sort/filter/pagination/empty-state as kit defaults — the old
  unbounded `leads/2` read is gone from this surface. The lens is READ-ONLY by design:
  the domain defines no lead-specific write action (leads ARE CRM people; their CRUD
  lives on the CRM surfaces), so this page wires none.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Marketing.Live, only: [assign_mount: 2, marketing_sidebar: 1, marketing_path: 1, marketing_plane_note: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount

  use Samen.Web.ListLive,
    resource: Person,
    reads: &Samen.Web.CRM.Reads.leads_page/3,
    sortable: [:display_name, :job_title],
    filter_fields: [:display_name, :job_title],
    default_sort: {:display_name, :asc}

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    org_id = CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)
    {:ok, load(assign(socket, org_id: org_id), org_id)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    org_id = Samen.Web.CurrentOrg.reresolve(socket, params)
    {:noreply, load(assign(socket, org_id: org_id, return_to: return_path(uri)), org_id)}
  end

  @doc false
  def load(socket, nil) do
    socket
    |> ensure_return_to()
    |> assign(no_org: CurrentOrg.no_org?(socket.assigns[:samen_mount], nil), org_id: nil)
    |> assign(page: %Samen.Web.Page{}, list_state: %Samen.Web.ListState{})
  end

  def load(socket, org_id) do
    mount = socket.assigns.samen_mount

    socket = ensure_return_to(assign(socket, no_org: false, org_id: org_id))

    # The bounded read runs on the DERIVED CRM mount (same repo + plane, CRM namespace),
    # so PII resolves identically to the CRM pages. No :crm_namespace label → the lens
    # stays inert (an empty page), exactly as before.
    case crm_mount(mount) do
      nil -> assign(socket, page: %Samen.Web.Page{}, list_state: %Samen.Web.ListState{})
      crm -> init_list(socket, crm, Mount.scope(crm, org_id))
    end
  end

  defp ensure_return_to(socket) do
    if Map.has_key?(socket.assigns, :return_to), do: socket, else: assign(socket, return_to: nil)
  end

  # Derive a CRM-kind mount from the Marketing mount + the host's `:crm_namespace` label.
  # Same repo, same plane (so PII resolves identically), CRM namespace for resource derivation.
  defp crm_mount(mount) do
    case Mount.label(mount, :crm_namespace, nil) do
      nil ->
        nil

      crm_ns when is_atom(crm_ns) ->
        Mount.new(:crm, crm_ns, mount.repo, plane: mount.plane, domain: crm_ns, labels: mount.labels)

      crm_ns when is_binary(crm_ns) ->
        ns = String.to_existing_atom(crm_ns)
        Mount.new(:crm, ns, mount.repo, plane: mount.plane, domain: ns, labels: mount.labels)
    end
  rescue
    _ -> nil
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="mkt-leads">
      <.app_shell>
        <:sidebar>
          <.marketing_sidebar mount={@samen_mount} org_id={@org_id} active={:marketing_leads} return_to={@return_to} />
        </:sidebar>

        <.topbar title="Leads" crumbs={crumbs(@samen_mount, @org_id, "Leads")}>
          <:actions>
            <a href={segments_path(@samen_mount, @org_id)} class="btn" style="text-decoration:none">Segments</a>
          </:actions>
        </.topbar>

        <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

        <%= if @no_org do %>
          <.no_org_card mount={@samen_mount} />
        <% else %>
          <span id="org-banner" style="display:none">Marketing org: {@org_id}</span>

          <div class="wrap">
            <div id="leads">
              <div class="gtitle">
                <h3>Leads</h3>
                <span class="n">{length(@page.items)}</span>
                <span class="lane">· lifecycle lead / mql / sql · name+email via PiiResolution · {marketing_plane_note(@samen_mount)}</span>
              </div>
              <.list_view
                id="leads-list"
                page={@page}
                state={@list_state}
                row_class="lead-row"
                filter_placeholder="Filter leads…"
                empty_text="No leads in the early funnel yet."
                empty_icon="➤"
                empty_body="This lens surfaces contacts in the lead / MQL / SQL lifecycle stages — set a contact's lifecycle stage in CRM and it appears here."
              >
                <:head>
                  <.sort_header field={:display_name} label="Name" sort={@list_state.sort} width="30%" />
                  <th scope="col" style="width:28%">Email</th>
                  <.sort_header field={:job_title} label="Title" sort={@list_state.sort} width="20%" />
                  <th scope="col" style="width:22%">Stage</th>
                </:head>
                <:row :let={p}>
                  <td class="lead-name" style="font-weight:500">{render_full_name(p.full_name, p.display_name)}</td>
                  <td class="lead-email" style="font-size:12px;color:var(--muted)">{render_email(p.emails)}</td>
                  <td style="font-size:12px;color:var(--muted)">{p.job_title || "—"}</td>
                  <td><.lifecycle_pill stage={lifecycle_stage(p)} /></td>
                </:row>
              </.list_view>
            </div>
          </div>
        <% end %>
      </.app_shell>
    </div>
    """
  end

  defp crumbs(mount, org_id, leaf), do: [CurrentOrg.name(mount, org_id), "Marketing", leaf]

  defp segments_path(mount, org_id), do: "#{marketing_path(mount)}/segments?org=#{org_id}"

  defp lifecycle_stage(%{custom: %{"lifecycle_stage" => stage}}) when is_binary(stage), do: stage
  defp lifecycle_stage(_), do: nil

  # PII renderers — render %Masked{} as-is (copied posture from ContactsLive).
  defp render_full_name(%Samen.Masked{} = masked, _display_name), do: masked

  defp render_full_name(name, _display_name) when is_binary(name) do
    case Jason.decode(name) do
      {:ok, %{"first" => first, "last" => last}} -> String.trim("#{first} #{last}")
      _ -> name
    end
  end

  defp render_full_name(nil, display_name) when is_binary(display_name), do: display_name
  defp render_full_name(nil, _display_name), do: "—"
  defp render_full_name(other, _display_name), do: other

  defp render_email(%Samen.Masked{} = masked), do: masked
  defp render_email(%Samen.Type.Emails{entries: entries}), do: render_email(entries)

  defp render_email(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> render_email(list)
      _ -> "—"
    end
  end

  defp render_email(emails) when is_list(emails) do
    case List.first(emails) do
      %{"address" => addr} -> addr
      %{address: addr} -> addr
      _ -> "—"
    end
  end

  defp render_email(_), do: "—"
end
