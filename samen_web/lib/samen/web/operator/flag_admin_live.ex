defmodule Samen.Web.Operator.FlagAdminLive do
  @moduledoc """
  Framework OPERATOR flag admin — `/operator/flags` (WS-B B6; ADR-020; design G6
  §3.5), declared in `samen_operator_routes/2` so every vertical inherits it at 0
  LiveView lines. The SaaS sees its PLATFORM flags — the operator org's OWN
  `FeatureFlag` rows (tenant plane of the operator org, writable) in the host's
  Primitives namespace, wired via the `:flags_namespace` mount label (the
  `crm_namespace` seam pattern) — with:

    * **The KILL SWITCH** — a visually distinct, confirm-gated control
      (`data-confirm` interlock; the incident lever). Flipping it writes
      `enabled → false` through the sanctioned `:update` action and ROUND-TRIPS
      through `Samen.FeatureFlags.Cache.invalidate/1` (the B5 write-through hop),
      so the NEXT `evaluate/2` anywhere in the cluster short-circuits OFF
      (`reason: :kill_switch`) within the staleness bound.
    * **Rollout ramp + targeting over tenant cohorts** — `rollout_pct` and the
      bounded non-PII rule editor (plan / tier / stage / region / org_id — the
      tenant-cohort keys; a PII-keyed rule is kernel-REFUSED at write, RP-F3).
    * **Per-org evaluated state** — for the flag under edit, the cache-free
      `evaluate_config/4` preview per tenant account (bounded cohort read) for
      debugging "why is this org in/out?".

  ## Posture + kernel enforcement (AC-G6-7)

  The operator workspace runs on the operator org's TENANT plane (ADR-010 §7.2) —
  writable. An impersonation (`plane: :operator`) mount renders NO write affordance
  and every mutating event is `writable?`-guarded (POSTURE); ENFORCEMENT is the
  kernel Ash policy (`OrgScope` + `RoleAtLeast :admin`) — a plain member/impersonation
  scope write is refused by the kernel regardless of the UI. Flags are Tier-0
  non-PII config rows; the cohort table renders bounded org name/plan only.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Operator.Live, only: [assign_mount: 2, operator_sidebar: 1, writable?: 1]
  import Samen.Web.Flags.Live, only: [decision_pill: 1, rules_table: 1]

  alias Samen.Web.Flags.Reads
  alias Samen.Web.Mount
  alias Samen.Web.Operator

  use Samen.Web.ListLive,
    resource: FeatureFlag,
    reads: &Samen.Web.Flags.Reads.flags_page/3,
    sortable: [:name, :enabled, :rollout_pct, :stage],
    filter_fields: [:name, :description],
    default_sort: {:name, :asc}

  @impl true
  def mount(_params, session, socket) do
    socket = assign_mount(socket, session)
    {:ok, load(socket)}
  end

  @doc false
  def load(socket) do
    mount = socket.assigns[:samen_mount]
    flags_mount = flags_mount(mount)
    operator_org_id = mount && Operator.org_id(mount)

    socket = ensure_defaults(socket)

    cond do
      is_nil(flags_mount) ->
        assign(socket,
          no_flags_ns: true,
          operator_org_id: operator_org_id,
          flags_mount: nil,
          cohorts: [],
          page: %Samen.Web.Page{},
          list_state: %Samen.Web.ListState{}
        )

      is_nil(operator_org_id) ->
        assign(socket,
          no_flags_ns: false,
          operator_org_id: nil,
          flags_mount: flags_mount,
          cohorts: [],
          page: %Samen.Web.Page{},
          list_state: %Samen.Web.ListState{}
        )

      true ->
        scope = Mount.scope(mount, operator_org_id)

        socket
        |> assign(
          no_flags_ns: false,
          operator_org_id: operator_org_id,
          flags_mount: flags_mount,
          cohorts: Reads.tenant_cohorts(mount, operator_org_id)
        )
        |> init_list(flags_mount, scope)
        |> refresh_edit()
    end
  end

  # The flags resource lives in the host's PRIMITIVES namespace, wired on the
  # operator mount via the `:flags_namespace` label (the marketing `crm_namespace`
  # seam pattern). The derived mount keeps the operator mount's repo + plane.
  defp flags_mount(nil), do: nil

  defp flags_mount(%Mount{} = mount) do
    case Mount.label(mount, :flags_namespace, nil) do
      ns when is_atom(ns) and not is_nil(ns) -> %{mount | namespace: ns, scope_kind: :flags}
      _ -> nil
    end
  end

  defp ensure_defaults(socket) do
    socket
    |> assign_new(:edit_flag, fn -> nil end)
    |> assign_new(:flag_error, fn -> nil end)
    |> assign_new(:rule_error, fn -> nil end)
    |> assign_new(:ramp_form, fn -> nil end)
    |> assign_new(:rule_form, fn -> blank_rule_form() end)
  end

  defp refresh_edit(%{assigns: %{edit_flag: nil}} = socket), do: socket
  defp refresh_edit(%{assigns: %{edit_flag: flag}} = socket), do: open_edit(socket, flag.id)

  defp open_edit(socket, id) do
    %{samen_mount: mount, flags_mount: flags_mount, operator_org_id: org_id} = socket.assigns

    case flags_mount && Reads.get_flag(flags_mount, Mount.scope(mount, org_id), id) do
      nil ->
        assign(socket, edit_flag: nil, ramp_form: nil)

      flag ->
        assign(socket,
          edit_flag: flag,
          ramp_form: to_form(%{"rollout_pct" => flag.rollout_pct}, as: :ramp)
        )
    end
  end

  # -- events (list events belong to the ListLive hook) --------------------------

  @impl true
  def handle_event("kill_flag", %{"id" => id}, socket) do
    # The KILL SWITCH: enabled → false through the sanctioned update; Reads
    # write-through invalidates the cache entry so the flip propagates (RP-F4).
    {:noreply, mutate(socket, fn fm, scope -> kill(fm, scope, id) end)}
  end

  def handle_event("enable_flag", %{"id" => id}, socket) do
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
        {:noreply, socket |> assign(rule_error: nil, rule_form: blank_rule_form()) |> load()}

      {:error, message, socket} ->
        # The kernel NonPiiTargeting refusal (RP-F3), surfaced friendly; nothing persisted.
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

  # A KILLED flag is enabled: false regardless of prior state (idempotent, unlike toggle).
  defp kill(flags_mount, scope, id) do
    case Reads.get_flag(flags_mount, scope, id) do
      nil -> {:error, "Flag not found."}
      %{enabled: false} = flag -> {:ok, flag}
      _flag -> Reads.toggle_flag(flags_mount, scope, id)
    end
  end

  # Posture-checked write (never elevates on an impersonation mount), then the
  # kernel-enforced Ash action via the plane-preserving admin write scope.
  defp guarded_write(socket, fun) do
    %{samen_mount: mount, flags_mount: flags_mount, operator_org_id: org_id} = socket.assigns

    if writable?(mount) and flags_mount != nil and org_id != nil do
      case fun.(flags_mount, Reads.write_scope(mount, org_id)) do
        {:ok, _flag} -> {:ok, socket}
        {:error, message} -> {:error, message, socket}
      end
    else
      {:error, "Read-only on this plane.", socket}
    end
  end

  defp mutate(socket, fun) do
    case guarded_write(socket, fun) do
      {:ok, socket} -> socket |> assign(flag_error: nil) |> load()
      {:error, message, socket} -> assign(socket, flag_error: message)
    end
  end

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
    <div id="operator-flags">
      <.app_shell>
        <:sidebar>
          <.operator_sidebar mount={@samen_mount} active={:flags} />
        </:sidebar>

        <.topbar title="Feature flags" crumbs={["Operator plane", "Flags"]} />

        <%= cond do %>
          <% @no_flags_ns -> %>
            <div class="wrap">
              <.empty_state
                class="flags-ns-empty"
                icon="⚑"
                title="No flags namespace wired."
                body="Wire the host's Primitives namespace on the operator mount via the flags_namespace: label (e.g. flags_namespace: Driftwood.Primitives) to manage platform feature flags here."
              />
            </div>
          <% @operator_org_id == nil -> %>
            <div class="wrap">
              <div class="card" id="no-org" style="padding:22px 20px;color:var(--muted)">
                No operator org resolved.
              </div>
            </div>
          <% true -> %>
            <div :if={@flag_error} class="wrap" style="margin-bottom:0">
              <div class="card form-error" id="flag-error" style="padding:10px 14px;color:var(--bad, #b91c1c);font-size:12px">
                {@flag_error}
              </div>
            </div>

            <div class="wrap">
              <div id="platform-flags">
                <div class="gtitle">
                  <h3>Platform flags</h3>
                  <span class="n">{length(@page.items)}</span>
                  <span class="lane">· the operator org's own config rows · kill switch is fail-safe (unconfirmed = OFF) · writes are kernel admin-gated</span>
                </div>
                <.list_view
                  id="platform-flags-list"
                  page={@page}
                  state={@list_state}
                  row_class="flag-row"
                  filter_placeholder="Filter flags…"
                  empty_text="No platform flags yet."
                  empty_icon="⚑"
                  empty_body="Platform feature flags gate rollouts across tenant cohorts — ramp by percentage, target by plan/tier, and kill instantly in an incident."
                >
                  <:head>
                    <.sort_header field={:name} label="Flag" sort={@list_state.sort} width="24%" />
                    <.sort_header field={:stage} label="Stage" sort={@list_state.sort} width="10%" />
                    <.sort_header field={:enabled} label="Status" sort={@list_state.sort} width="12%" />
                    <.sort_header field={:rollout_pct} label="Rollout" sort={@list_state.sort} width="10%" />
                    <th scope="col" style="width:8%">Rules</th>
                    <th :if={writable?(@samen_mount)} scope="col" style="width:36%">
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
                      <.pill variant={if flag.enabled, do: "ok", else: "bad"}>
                        {if flag.enabled, do: "live", else: "killed / off"}
                      </.pill>
                    </td>
                    <td class="flag-rollout" style="font-weight:500">{flag.rollout_pct}%</td>
                    <td class="flag-rules-count" style="color:var(--muted)">{length(flag.target_rules || [])}</td>
                    <td :if={writable?(@samen_mount)} class="flag-actions">
                      <div style="display:flex;gap:6px;align-items:center;flex-wrap:wrap">
                        <.button phx-click="edit_flag" phx-value-id={flag.id}>Ramp &amp; targeting</.button>
                        <span :if={flag.enabled} class="kill-switch">
                          <.delete_confirm
                            phx-click="kill_flag"
                            phx-value-id={flag.id}
                            label="⛔ Kill switch"
                            message="KILL this flag? Every evaluation, for every org, returns OFF until it is re-enabled. This is the incident lever."
                          />
                        </span>
                        <.button :if={!flag.enabled} phx-click="enable_flag" phx-value-id={flag.id}>
                          Re-enable
                        </.button>
                      </div>
                    </td>
                  </:row>
                </.list_view>
              </div>
            </div>

            <.modal
              :if={@edit_flag != nil and writable?(@samen_mount)}
              id="flag-admin-modal"
              title={"#{@edit_flag.name} — ramp, targeting & per-org state"}
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

              <div class="gtitle" style="margin-top:4px">
                <h3>Targeting rules · tenant cohorts</h3>
                <span class="n">{length(@edit_flag.target_rules || [])}</span>
                <span class="lane">· first match wins · non-PII cohort keys only (org_id, plan, tier, stage, role, region)</span>
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

              <div class="gtitle" style="margin-top:14px">
                <h3>Evaluated state per tenant org</h3>
                <span class="n">{length(@cohorts)}</span>
                <span class="lane">· cache-free preview (no ETS warm, no assignment emit) · bounded cohort</span>
              </div>
              <.empty_state
                :if={@cohorts == []}
                class="cohorts-empty"
                icon="◫"
                title="No tenant accounts yet."
                body="Once tenant orgs exist as accounts, each row here shows this flag's evaluated decision for that org."
              />
              <table :if={@cohorts != []} class="tbl" id="per-org-state">
                <thead>
                  <tr>
                    <th scope="col" style="width:44%">Account</th>
                    <th scope="col" style="width:20%">Plan</th>
                    <th scope="col" style="width:36%">Decision</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={org <- @cohorts} class="cohort-row" id={"cohort-#{org.id}"}>
                    <td class="cohort-name" style="font-weight:500;color:#3a3b45">{org.name}</td>
                    <td class="cohort-plan" style="color:var(--muted)">{org.plan}</td>
                    <td class="cohort-decision">
                      <.decision_pill decision={Reads.decision(@edit_flag, %{org_id: org.id, plan: org.plan})} />
                    </td>
                  </tr>
                </tbody>
              </table>
            </.modal>
        <% end %>
      </.app_shell>
    </div>
    """
  end
end
