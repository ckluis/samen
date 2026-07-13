defmodule Samen.Web.Flags.SettingsLive do
  @moduledoc """
  Framework TENANT flag admin — `/flags` (WS-B B6; ADR-020; design G6 §3.5), mounted
  via `Samen.Web.Router.samen_flags_routes/2` over the host's Primitives-scope
  `FeatureFlag` (`pff`) rows. A tenant admin sees the flags applicable to THEIR org
  (kernel `OrgScope` — never another org's rows) and each flag's EVALUATED state
  (the cache-free `evaluate_config/4` preview), and manages them without forking the
  product — the bottom rung of the malleability ladder:

    * **Toggle** — the sanctioned `:update` enable/disable (row button).
    * **Percentage ramp** — `rollout_pct` via the kit `simple_form/1` in the edit
      `modal/1` (deterministic `phash2` bucketing: raising the ramp only ever ADDS
      orgs — the B5 monotonic-stability invariant).
    * **Targeting rules** — add/remove bounded non-PII rules. The kernel
      `NonPiiTargeting` validation runs INSIDE the update action; a rule keyed on a
      PII-classified attribute (email/phone/…) is REFUSED at the write boundary and
      the refusal SURFACES here as a friendly inline validation error (RP-F3 —
      the UI cannot submit a PII-keyed rule).

  ## A3 posture + kernel enforcement (AC-G6-7)

  Write affordances render on the tenant plane only (`Flags.Live.writable?/1`) and
  every mutating event is `writable?`-guarded — POSTURE. ENFORCEMENT is the kernel's:
  flag writes are `OrgScope` + `RoleAtLeast :admin` gated, so writes go through
  `Reads.write_scope/2` (same-org, PLANE-PRESERVING role elevation — never built on
  an impersonation mount). No PII on this surface (flags are Tier-0 config rows).
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Flags.Live,
    only: [assign_mount: 2, flags_sidebar: 1, writable?: 1, decision_pill: 1, rules_table: 1]

  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Flags.Reads
  alias Samen.Web.Mount

  use Samen.Web.ListLive,
    resource: FeatureFlag,
    reads: &Samen.Web.Flags.Reads.flags_page/3,
    sortable: [:name, :enabled, :rollout_pct, :stage],
    filter_fields: [:name, :description],
    default_sort: {:name, :asc}

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    org_id = CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)
    {:ok, load(assign(socket, org_id: org_id), org_id)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    org_id = Map.get(params, "org") || socket.assigns.org_id
    {:noreply, load(assign(socket, org_id: org_id, return_to: return_path(uri)), org_id)}
  end

  @doc false
  def load(socket, nil) do
    socket
    |> ensure_defaults()
    |> assign(no_org: CurrentOrg.no_org?(socket.assigns[:samen_mount], nil), org_id: nil)
    |> assign(page: %Samen.Web.Page{}, list_state: %Samen.Web.ListState{})
  end

  def load(socket, org_id) do
    mount = socket.assigns.samen_mount
    scope = Mount.scope(mount, org_id)

    socket
    |> ensure_defaults()
    |> assign(no_org: false, org_id: org_id)
    |> init_list(mount, scope)
    |> refresh_edit()
  end

  defp ensure_defaults(socket) do
    socket
    |> assign_new(:return_to, fn -> nil end)
    |> assign_new(:edit_flag, fn -> nil end)
    |> assign_new(:flag_error, fn -> nil end)
    |> assign_new(:rule_error, fn -> nil end)
    |> assign_new(:ramp_form, fn -> nil end)
    |> assign_new(:rule_form, fn -> blank_rule_form() end)
  end

  # Re-read the flag under edit after any mutation (fresh rules/ramp in the modal).
  defp refresh_edit(%{assigns: %{edit_flag: nil}} = socket), do: socket

  defp refresh_edit(%{assigns: %{edit_flag: flag}} = socket) do
    open_edit(socket, flag.id)
  end

  defp open_edit(socket, id) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns

    case Reads.get_flag(mount, Mount.scope(mount, org_id), id) do
      nil ->
        assign(socket, edit_flag: nil, ramp_form: nil)

      flag ->
        assign(socket,
          edit_flag: flag,
          ramp_form: to_form(%{"rollout_pct" => flag.rollout_pct}, as: :ramp)
        )
    end
  end

  # -- CRUD events (list events belong to the ListLive hook) ---------------------

  @impl true
  def handle_event("toggle_flag", %{"id" => id}, socket) do
    {:noreply, mutate(socket, &Reads.toggle_flag(&1, &2, id))}
  end

  def handle_event("edit_flag", %{"id" => id}, socket) do
    {:noreply, socket |> assign(rule_error: nil, rule_form: blank_rule_form()) |> open_edit(id)}
  end

  def handle_event("close_edit", _params, socket) do
    {:noreply, assign(socket, edit_flag: nil, ramp_form: nil, rule_error: nil)}
  end

  def handle_event("save_ramp", %{"ramp" => %{"rollout_pct" => raw}}, socket) do
    case Integer.parse(to_string(raw)) do
      {pct, _} ->
        {:noreply, mutate(socket, &Reads.set_rollout(&1, &2, socket.assigns.edit_flag.id, pct))}

      :error ->
        {:noreply, assign(socket, flag_error: "Rollout must be a whole percentage (0–100).")}
    end
  end

  def handle_event("add_rule", %{"rule" => params}, socket) do
    %{edit_flag: flag} = socket.assigns
    rules = (flag.target_rules || []) ++ [build_rule(params)]

    case guarded_write(socket, &Reads.put_rules(&1, &2, flag.id, rules)) do
      {:ok, socket} ->
        {:noreply, socket |> assign(rule_error: nil, rule_form: blank_rule_form()) |> reload()}

      {:error, message, socket} ->
        # The kernel NonPiiTargeting refusal (RP-F3), surfaced as a friendly
        # validation error — the rule did NOT persist.
        {:noreply, assign(socket, rule_error: message, rule_form: to_form(params, as: :rule))}
    end
  end

  def handle_event("remove_rule", %{"index" => raw_index}, socket) do
    %{edit_flag: flag} = socket.assigns

    with {index, _} <- Integer.parse(to_string(raw_index)),
         rules when is_list(rules) <- flag.target_rules do
      {:noreply, mutate(socket, &Reads.put_rules(&1, &2, flag.id, List.delete_at(rules, index)))}
    else
      _ -> {:noreply, socket}
    end
  end

  # A guarded write: posture-checked (never elevates on an impersonation mount),
  # then the kernel-enforced Ash action via the plane-preserving admin write scope.
  defp guarded_write(socket, fun) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns

    if writable?(mount) and org_id != nil do
      case fun.(mount, Reads.write_scope(mount, org_id)) do
        {:ok, _flag} -> {:ok, socket}
        {:error, message} -> {:error, message, socket}
      end
    else
      {:error, "Read-only on this plane.", socket}
    end
  end

  defp mutate(socket, fun) do
    case guarded_write(socket, fun) do
      {:ok, socket} -> socket |> assign(flag_error: nil) |> reload()
      {:error, message, socket} -> assign(socket, flag_error: message)
    end
  end

  defp reload(socket), do: load(socket, socket.assigns.org_id)

  # The bounded rule map the kernel validates (attribute/op/values/then — RP-F3 runs
  # on `attribute` at write). Values are comma-separated bounded config scalars.
  defp build_rule(params) do
    %{
      "attribute" => String.trim(params["attribute"] || ""),
      "op" => params["op"] || "eq",
      "values" =>
        (params["values"] || "")
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == "")),
      "then" => params["then"] || "on"
    }
  end

  defp blank_rule_form, do: to_form(%{"attribute" => "", "op" => "eq", "values" => "", "then" => "on"}, as: :rule)

  # -- render --------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div id="flags-settings">
      <.app_shell>
        <:sidebar>
          <.flags_sidebar mount={@samen_mount} org_id={@org_id} active={:flags} return_to={@return_to} />
        </:sidebar>

        <.topbar title="Feature flags" crumbs={crumbs(@samen_mount, @org_id)} />

        <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

        <%= if @no_org do %>
          <.no_org_card mount={@samen_mount} />
        <% else %>
          <span id="org-banner" style="display:none">Feature flags org: {@org_id}</span>

          <div :if={@flag_error} class="wrap" style="margin-bottom:0">
            <div class="card form-error" id="flag-error" style="padding:10px 14px;color:var(--bad, #b91c1c);font-size:12px">
              {@flag_error}
            </div>
          </div>

          <div class="wrap">
            <div id="flags">
              <div class="gtitle">
                <h3>Feature flags</h3>
                <span class="n">{length(@page.items)}</span>
                <span class="lane">· Tier-0 config rows · admin-gated writes · non-PII targeting by construction</span>
              </div>
              <.list_view
                id="flags-list"
                page={@page}
                state={@list_state}
                row_class="flag-row"
                filter_placeholder="Filter flags…"
                empty_text="No feature flags yet."
                empty_icon="⚑"
                empty_body="Feature flags gate features per org — toggle, ramp by percentage, or target by plan/tier without forking the product."
              >
                <:head>
                  <.sort_header field={:name} label="Flag" sort={@list_state.sort} width="26%" />
                  <.sort_header field={:stage} label="Stage" sort={@list_state.sort} width="10%" />
                  <.sort_header field={:enabled} label="Status" sort={@list_state.sort} width="12%" />
                  <.sort_header field={:rollout_pct} label="Rollout" sort={@list_state.sort} width="10%" />
                  <th scope="col" style="width:8%">Rules</th>
                  <th scope="col" style="width:16%">Evaluated for this org</th>
                  <th :if={writable?(@samen_mount)} scope="col" style="width:18%">
                    <span class="sr-only">Actions</span>
                  </th>
                </:head>
                <:row :let={flag}>
                  <td class="flag-name">
                    <div style="font-weight:600;color:#3a3b45">{flag.name}</div>
                    <div style="font-size:11px;color:var(--muted)">{flag.description}</div>
                  </td>
                  <td class="flag-stage"><.pill variant="info">{flag.stage}</.pill></td>
                  <td class="flag-status">
                    <.pill variant={if flag.enabled, do: "ok", else: "mut"}>
                      {if flag.enabled, do: "enabled", else: "disabled"}
                    </.pill>
                  </td>
                  <td class="flag-rollout" style="font-weight:500">{flag.rollout_pct}%</td>
                  <td class="flag-rules-count" style="color:var(--muted)">{length(flag.target_rules || [])}</td>
                  <td class="flag-evaluated">
                    <.decision_pill decision={Reads.decision(flag, %{org_id: @org_id})} />
                  </td>
                  <td :if={writable?(@samen_mount)} class="flag-actions">
                    <div style="display:flex;gap:6px;align-items:center">
                      <.button phx-click="toggle_flag" phx-value-id={flag.id}>
                        {if flag.enabled, do: "Disable", else: "Enable"}
                      </.button>
                      <.button phx-click="edit_flag" phx-value-id={flag.id}>Ramp &amp; rules</.button>
                    </div>
                  </td>
                </:row>
              </.list_view>
            </div>
          </div>

          <.modal
            :if={@edit_flag != nil and writable?(@samen_mount)}
            id="flag-edit-modal"
            title={"#{@edit_flag.name} — ramp & targeting"}
            on_cancel="close_edit"
          >
            <.simple_form :let={f} for={@ramp_form} id="ramp-form" phx-submit="save_ramp">
              <.form_field
                field={f[:rollout_pct]}
                label="Rollout percentage (0–100)"
                type="number"
                min="0"
                max="100"
                step="1"
              />
              <:actions>
                <.button variant="primary" type="submit">Save ramp</.button>
              </:actions>
            </.simple_form>
            <p style="margin:6px 0 14px;font-size:11px;color:var(--muted)">
              Bucketing is deterministic per (flag, org) — raising the ramp only ever ADDS orgs, never reshuffles.
            </p>

            <div class="gtitle" style="margin-top:4px">
              <h3>Targeting rules</h3>
              <span class="n">{length(@edit_flag.target_rules || [])}</span>
              <span class="lane">· first match wins · non-PII attributes only (org_id, plan, tier, stage, role, region)</span>
            </div>

            <.rules_table rules={@edit_flag.target_rules || []} writable={writable?(@samen_mount)} />

            <div :if={@rule_error} class="card form-error" id="rule-error" style="padding:10px 14px;margin:8px 0;color:var(--bad, #b91c1c);font-size:12px">
              {@rule_error}
            </div>

            <.simple_form :let={f} for={@rule_form} id="rule-form" phx-submit="add_rule">
              <.form_field field={f[:attribute]} label="Attribute" placeholder="plan" />
              <.form_field
                field={f[:op]}
                label="Operator"
                type="select"
                options={[{"equals", "eq"}, {"not equals", "neq"}, {"in", "in"}, {"not in", "not_in"}]}
              />
              <.form_field field={f[:values]} label="Values (comma-separated)" placeholder="pro, enterprise" />
              <.form_field
                field={f[:then]}
                label="Then"
                type="select"
                options={[{"on", "on"}, {"off", "off"}, {"allow", "allow"}, {"deny", "deny"}]}
              />
              <:actions>
                <.button variant="primary" type="submit">Add rule</.button>
                <.button type="button" phx-click="close_edit">Done</.button>
              </:actions>
            </.simple_form>
          </.modal>
        <% end %>
      </.app_shell>
    </div>
    """
  end

  defp crumbs(mount, org_id), do: [CurrentOrg.name(mount, org_id), "Settings", "Feature flags"]
end
