defmodule Samen.Web.Billing.PlansLive do
  @moduledoc """
  Framework Billing / Plans page — Tier-0 billing plans + prices config rows, host-agnostic
  (ADR-009). Plans/prices are non-PII config rows; this page introduces NO PII path.

  ## A3 retrofit — ListLive + sanctioned CRUD

  The list rides the A2 kit contract: `use Samen.Web.ListLive` + the BOUNDED
  `Reads.plans_page/3` buys sort/filter/keyset-pagination/empty-state as kit defaults
  (no unbounded `read!`, no list `handle_event/3` of its own). Prices are joined from a
  bounded lookup map AFTER paging. The write side (AC-G1-1/2, the sanctioned "plan
  changes"): "New plan" opens a `modal/1` hosting an `AshPhoenix.Form`-backed
  `simple_form/1` create (`name` is required — the inline-error path is real); each row
  carries an enable/disable toggle (the blueprint's `update: :*`) and a
  `delete_confirm/1`. Write affordances are offered on the tenant plane only
  (`Samen.Web.Billing.Live.writable?/1`); enforcement stays in the kernel — Plan writes
  are ADMIN-gated (`RoleAtLeast :admin`), so writes go through `Reads.write_scope/2`
  (same-org, PLANE-PRESERVING role elevation).
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Billing.Live, only: [assign_mount: 2, billing_sidebar: 1, writable?: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount

  alias Samen.Web.Billing.Reads

  use Samen.Web.ListLive,
    resource: Plan,
    reads: &Samen.Web.Billing.Reads.plans_page/3,
    sortable: [:name, :interval, :enabled],
    filter_fields: [:name, :label],
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
    |> ensure_return_to()
    |> assign(no_org: CurrentOrg.no_org?(socket.assigns[:samen_mount], nil), org_id: nil, prices_by_plan: %{})
    |> assign(page: %Samen.Web.Page{}, list_state: %Samen.Web.ListState{})
    |> assign(show_new: false, new_form: nil)
    |> assign(show_edit: false, edit_form: nil, edit_plan_id: nil)
    |> assign(show_ents: false, subscriptions: [], entitlements: [])
    |> assign_new(:delete_error, fn -> nil end)
  end

  def load(socket, org_id) do
    mount = socket.assigns.samen_mount
    scope = Mount.scope(mount, org_id)

    socket
    |> ensure_return_to()
    |> assign(no_org: false, org_id: org_id, prices_by_plan: Reads.prices_by_plan(mount, scope))
    |> assign(subscriptions: Reads.subscriptions(mount, scope), entitlements: Reads.entitlements(mount, scope))
    |> assign_new(:show_new, fn -> false end)
    |> assign_new(:show_edit, fn -> false end)
    |> assign_new(:edit_plan_id, fn -> nil end)
    |> assign_new(:show_ents, fn -> false end)
    |> assign_new(:delete_error, fn -> nil end)
    |> assign(new_form: new_plan_form(mount, org_id))
    |> assign_new(:edit_form, fn -> nil end)
    |> init_list(mount, scope)
  end

  # -- A3 CRUD events (list events belong to the ListLive hook) -----------------

  @impl true
  def handle_event("new_plan", _params, socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns
    {:noreply, assign(socket, show_new: true, new_form: new_plan_form(mount, org_id))}
  end

  def handle_event("cancel_new", _params, socket) do
    {:noreply, assign(socket, show_new: false)}
  end

  def handle_event("validate_new", %{"form" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.new_form, with_org(params, socket))
    {:noreply, assign(socket, new_form: form)}
  end

  # `org_id` is the server-side fact, never client input. Plans are non-PII config
  # rows; the kernel's OrgScope + admin role gate still apply — no LiveView policy.
  def handle_event("save_new", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.new_form, params: with_org(params, socket)) do
      {:ok, _plan} ->
        {:noreply, socket |> assign(show_new: false) |> load(socket.assigns.org_id)}

      {:error, form} ->
        {:noreply, assign(socket, new_form: form)}
    end
  end

  # -- Edit plan (name/label/description/interval) — sanctioned update: :* ------

  def handle_event("edit_plan", %{"id" => id}, socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns

    case find_plan(socket, id) do
      nil -> {:noreply, socket}
      plan -> {:noreply, assign(socket, show_edit: true, edit_plan_id: id, edit_form: edit_plan_form(mount, org_id, plan))}
    end
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, show_edit: false, edit_plan_id: nil)}
  end

  def handle_event("validate_edit", %{"form" => params}, socket) do
    {:noreply, assign(socket, edit_form: AshPhoenix.Form.validate(socket.assigns.edit_form, params))}
  end

  def handle_event("save_edit", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.edit_form, params: params) do
      {:ok, _plan} ->
        {:noreply, socket |> assign(show_edit: false, edit_plan_id: nil) |> load(socket.assigns.org_id)}

      {:error, form} ->
        {:noreply, assign(socket, edit_form: form)}
    end
  end

  # Feature-map editing — each checkbox flips ONE bounded feature key in the plan's
  # `features` entitlement map via the sanctioned update: :* (fail-closed validated in
  # `Reads.update_plan/4`). Immediate persist keeps the map the source of truth.
  def handle_event("toggle_feature", %{"id" => id, "feature" => feature}, socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns
    current = normalize_features(find_plan(socket, id))

    features =
      if Map.has_key?(current, feature),
        do: Map.delete(current, feature),
        else: Map.put(current, feature, true)

    case Reads.update_plan(mount, Reads.write_scope(mount, org_id), id, %{features: features}) do
      {:ok, _plan} ->
        socket = load(assign(socket, delete_error: nil), org_id)
        {:noreply, assign(socket, edit_form: edit_plan_form(mount, org_id, find_plan(socket, id)), edit_plan_id: id, show_edit: true)}

      {:error, _} ->
        {:noreply, assign(socket, delete_error: "Could not update plan features.")}
    end
  end

  # -- Entitlement grant / revoke (per-subscription, bounded feature) ----------

  def handle_event("open_ents", _params, socket), do: {:noreply, assign(socket, show_ents: true)}
  def handle_event("cancel_ents", _params, socket), do: {:noreply, assign(socket, show_ents: false)}

  def handle_event("grant_ent", %{"subscription_id" => sub, "feature" => feature} = params, socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns

    attrs =
      %{"subscription_id" => sub, "feature" => feature, "org_id" => org_id}
      |> put_expires(params["expires_at"])

    case Reads.grant_entitlement(mount, Reads.write_scope(mount, org_id), attrs) do
      {:ok, _ent} -> {:noreply, load(assign(socket, delete_error: nil), org_id)}
      {:error, _} -> {:noreply, assign(socket, delete_error: "Could not grant this entitlement.")}
    end
  end

  def handle_event("revoke_ent", %{"subscription_id" => sub, "feature" => feature}, socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns
    attrs = %{"subscription_id" => sub, "feature" => feature}

    case Reads.revoke_entitlement(mount, Reads.write_scope(mount, org_id), attrs) do
      {:ok, _ent} -> {:noreply, load(assign(socket, delete_error: nil), org_id)}
      {:error, _} -> {:noreply, assign(socket, delete_error: "Could not revoke this entitlement.")}
    end
  end

  # The sanctioned "plan change" edit — enable/disable via the blueprint's update: :*.
  def handle_event("toggle_plan", %{"id" => id}, socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns

    case Reads.toggle_plan(mount, Reads.write_scope(mount, org_id), id) do
      {:ok, _plan} -> {:noreply, load(assign(socket, delete_error: nil), org_id)}
      {:error, _} -> {:noreply, assign(socket, delete_error: "Could not update this plan.")}
    end
  end

  # FAIL-HONEST delete: a plan with linked prices/subscriptions is refused by the DB
  # (FK) and the refusal is SURFACED on the page.
  def handle_event("delete", %{"id" => id}, socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns

    case Reads.delete_plan(mount, Reads.write_scope(mount, org_id), id) do
      :ok ->
        {:noreply, load(assign(socket, delete_error: nil), org_id)}

      {:error, _reason} ->
        {:noreply,
         assign(socket,
           delete_error: "Could not delete this plan — it still has linked records (prices or subscriptions)."
         )}
    end
  end

  defp new_plan_form(mount, org_id) do
    Mount.resource(mount, Plan)
    |> AshPhoenix.Form.for_create(:create, scope: Reads.write_scope(mount, org_id))
    |> to_form()
  end

  defp edit_plan_form(_mount, _org_id, nil), do: nil

  defp edit_plan_form(mount, org_id, plan) do
    plan
    |> AshPhoenix.Form.for_update(:update, scope: Reads.write_scope(mount, org_id))
    |> to_form()
  end

  defp find_plan(socket, id), do: Enum.find(socket.assigns.page.items, &(&1.id == id))

  defp normalize_features(%{features: features}) when is_map(features),
    do: Map.new(features, fn {k, v} -> {to_string(k), v} end)

  defp normalize_features(_), do: %{}

  defp put_expires(attrs, exp) when exp in [nil, ""], do: attrs
  defp put_expires(attrs, exp), do: Map.put(attrs, "expires_at", exp)

  defp with_org(params, socket), do: Map.put(params, "org_id", socket.assigns.org_id)

  defp ensure_return_to(socket) do
    if Map.has_key?(socket.assigns, :return_to), do: socket, else: assign(socket, return_to: nil)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="billing-plans">
      <.app_shell>
        <:sidebar>
          <.billing_sidebar mount={@samen_mount} org_id={@org_id} active={:billing_plans} return_to={@return_to} />
        </:sidebar>

        <.topbar title="Plans" crumbs={crumbs(@samen_mount, @org_id, "Plans")}>
          <:actions>
            <.button :if={writable?(@samen_mount) and not @no_org} phx-click="open_ents" id="manage-entitlements">
              Entitlements
            </.button>
            <.button :if={writable?(@samen_mount) and not @no_org} variant="primary" phx-click="new_plan" id="new-plan">
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M12 3v18M3 12h18" />
                </svg>
              </:icon>
              New plan
            </.button>
          </:actions>
        </.topbar>

        <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

        <%= if @no_org do %>
          <.no_org_card mount={@samen_mount} />
        <% else %>
          <span id="org-banner" style="display:none">Billing plans org: {@org_id}</span>

          <div :if={@delete_error} class="wrap" style="margin-bottom:0">
            <div class="card form-error" id="delete-error" style="padding:10px 14px;color:var(--bad, #b91c1c);font-size:12px">
              {@delete_error}
            </div>
          </div>

          <div class="wrap">
            <div id="plans">
              <div class="gtitle">
                <h3>Billing Plans</h3>
                <span class="n">{length(@page.items)}</span>
                <span class="lane">· Tier-0 config rows · admin-gated writes · no PII</span>
              </div>
              <.list_view
                id="plans-list"
                page={@page}
                state={@list_state}
                row_class="plan-row"
                filter_placeholder="Filter plans…"
                empty_text="No plans yet."
                empty_icon="◫"
                empty_body="Plans define what your customers can subscribe to."
              >
                <:empty_actions :if={writable?(@samen_mount)}>
                  <.button variant="primary" phx-click="new_plan" id="empty-new-plan">New plan</.button>
                </:empty_actions>
                <:head>
                  <.sort_header field={:name} label="Plan" sort={@list_state.sort} width="20%" />
                  <th scope="col" style="width:14%">Price</th>
                  <.sort_header field={:interval} label="Interval" sort={@list_state.sort} width="12%" />
                  <.sort_header field={:enabled} label="Status" sort={@list_state.sort} width="12%" />
                  <th scope="col" style="width:28%">Entitlements</th>
                  <th :if={writable?(@samen_mount)} scope="col" style="width:14%"><span class="sr-only">Actions</span></th>
                </:head>
                <:row :let={plan}>
                  <td class="plan-name">
                    <div style="display:flex;align-items:center;gap:8px">
                      <div class="av" style={"width:28px;height:28px;border-radius:6px;background:#{plan_bg(plan.name)};color:#{plan_fg(plan.name)};font-size:10px;font-weight:700;display:flex;align-items:center;justify-content:center;flex-shrink:0"}>
                        {String.slice(plan.label || plan.name || "?", 0, 1) |> String.upcase()}
                      </div>
                      <div>
                        <div style="font-weight:600;color:#3a3b45">{plan.label || plan.name}</div>
                        <div style="font-size:11px;color:var(--muted)">{plan.description || plan.name}</div>
                      </div>
                    </div>
                  </td>
                  <td class="plan-price" style="font-weight:500;color:#3a3b45">
                    {primary_price(Map.get(@prices_by_plan, plan.id, []))}
                  </td>
                  <td class="plan-interval" style="color:var(--muted)">
                    {interval_label(plan.interval)}
                  </td>
                  <td class="plan-status">
                    <.pill variant={if plan.enabled, do: "ok", else: "mut"}>
                      {if plan.enabled, do: "active", else: "disabled"}
                    </.pill>
                  </td>
                  <td class="plan-features">
                    <div style="display:flex;flex-wrap:wrap;gap:4px">
                      <span :for={feat <- plan_features(plan)} style="display:inline-block;font-size:11px;padding:2px 7px;background:#F3F4F6;border-radius:4px;color:#374151">
                        {feat}
                      </span>
                    </div>
                  </td>
                  <td :if={writable?(@samen_mount)} class="plan-actions">
                    <div style="display:flex;gap:6px;align-items:center">
                      <.button phx-click="edit_plan" phx-value-id={plan.id} class="edit-plan">Edit</.button>
                      <.button phx-click="toggle_plan" phx-value-id={plan.id}>
                        {if plan.enabled, do: "Disable", else: "Enable"}
                      </.button>
                      <.delete_confirm phx-click="delete" phx-value-id={plan.id} />
                    </div>
                  </td>
                </:row>
              </.list_view>
            </div>
          </div>

          <.modal :if={@show_new and @new_form != nil and writable?(@samen_mount)} id="new-plan-modal" title="New plan" on_cancel="cancel_new">
            <.simple_form :let={f} for={@new_form} id="new-plan-form" phx-change="validate_new" phx-submit="save_new">
              <.form_field field={f[:name]} label="Name" />
              <.form_field field={f[:label]} label="Label" />
              <.form_field field={f[:description]} label="Description" />
              <.form_field
                field={f[:interval]}
                label="Interval"
                type="select"
                options={[{"monthly", "monthly"}, {"annual", "annual"}, {"weekly", "weekly"}, {"daily", "daily"}, {"one-time", "one_time"}]}
              />
              <:actions>
                <.button variant="primary" type="submit">Save plan</.button>
                <.button type="button" phx-click="cancel_new">Cancel</.button>
              </:actions>
            </.simple_form>
          </.modal>

          <.modal
            :if={@show_edit and @edit_form != nil and writable?(@samen_mount)}
            id="edit-plan-modal"
            title="Edit plan"
            on_cancel="cancel_edit"
          >
            <.simple_form :let={f} for={@edit_form} id="edit-plan-form" phx-change="validate_edit" phx-submit="save_edit">
              <.form_field field={f[:name]} label="Name" />
              <.form_field field={f[:label]} label="Label" />
              <.form_field field={f[:description]} label="Description" />
              <.form_field
                field={f[:interval]}
                label="Interval"
                type="select"
                options={[{"monthly", "monthly"}, {"annual", "annual"}, {"weekly", "weekly"}, {"daily", "daily"}, {"one-time", "one_time"}]}
              />
              <:actions>
                <.button variant="primary" type="submit">Save changes</.button>
                <.button type="button" phx-click="cancel_edit">Cancel</.button>
              </:actions>
            </.simple_form>

            <div id="edit-plan-features" style="margin-top:14px;border-top:1px solid #E5E7EB;padding-top:12px">
              <div style="font-size:12px;font-weight:600;margin-bottom:8px">Entitlements (feature map)</div>
              <% features = normalize_features(find_plan(assigns_socket(assigns), @edit_plan_id)) %>
              <div style="display:flex;flex-wrap:wrap;gap:8px">
                <label :for={feat <- Reads.feature_keys()} style="display:flex;align-items:center;gap:5px;font-size:12px;color:#374151">
                  <input
                    type="checkbox"
                    checked={Map.has_key?(features, to_string(feat))}
                    phx-click="toggle_feature"
                    phx-value-id={@edit_plan_id}
                    phx-value-feature={to_string(feat)}
                    data-feature={to_string(feat)}
                  />
                  {humanize_feature(feat)}
                </label>
              </div>
            </div>
          </.modal>

          <.modal :if={@show_ents and writable?(@samen_mount)} id="entitlements-modal" title="Subscription entitlements" on_cancel="cancel_ents">
            <%= if @subscriptions == [] do %>
              <p style="font-size:12px;color:var(--muted)">No subscriptions to entitle yet.</p>
            <% else %>
              <form id="grant-entitlement-form" phx-submit="grant_ent" style="display:flex;flex-wrap:wrap;gap:8px;align-items:end;margin-bottom:14px">
                <label style="display:flex;flex-direction:column;gap:3px;font-size:12px">
                  Subscription
                  <select name="subscription_id" required>
                    <option :for={sub <- @subscriptions} value={sub.id}>{subscription_label(sub)}</option>
                  </select>
                </label>
                <label style="display:flex;flex-direction:column;gap:3px;font-size:12px">
                  Feature
                  <select name="feature" required>
                    <option :for={feat <- Reads.feature_keys()} value={to_string(feat)}>{humanize_feature(feat)}</option>
                  </select>
                </label>
                <label style="display:flex;flex-direction:column;gap:3px;font-size:12px">
                  Expires
                  <input type="date" name="expires_at" />
                </label>
                <.button variant="primary" type="submit" id="grant-entitlement">Grant</.button>
              </form>

              <div id="entitlements-list">
                <div style="font-size:12px;font-weight:600;margin-bottom:6px">Granted entitlements</div>
                <p :if={granted_entitlements(@entitlements) == []} style="font-size:12px;color:var(--muted)">None granted yet.</p>
                <div :for={ent <- granted_entitlements(@entitlements)} class="entitlement-row" style="display:flex;align-items:center;gap:8px;padding:4px 0;font-size:12px">
                  <span style="font-weight:600">{humanize_feature(ent.feature)}</span>
                  <span style="color:var(--muted)">· {subscription_label_for(@subscriptions, ent.subscription_id)}</span>
                  <.button phx-click="revoke_ent" phx-value-subscription_id={ent.subscription_id} phx-value-feature={to_string(ent.feature)} class="revoke-ent">Revoke</.button>
                </div>
              </div>
            <% end %>
          </.modal>
        <% end %>
      </.app_shell>
    </div>
    """
  end

  # `assigns` in a ~H block is the assigns map; the render helpers below need the page
  # items to resolve the plan being edited. A tiny shim keeps `find_plan/2` reusable
  # from both handle_event (socket) and render (assigns).
  defp assigns_socket(assigns), do: %{assigns: assigns}

  # -- helpers -----------------------------------------------------------------

  defp crumbs(mount, org_id, leaf), do: [CurrentOrg.name(mount, org_id), "Billing", leaf]

  defp primary_price([]), do: "—"
  defp primary_price([price | _]), do: dollars(price.unit_amount)

  defp interval_label(:monthly), do: "monthly"
  defp interval_label(:annual), do: "annual"
  defp interval_label(:weekly), do: "weekly"
  defp interval_label(:daily), do: "daily"
  defp interval_label(:one_time), do: "one-time"
  defp interval_label(other), do: to_string(other)

  defp granted_entitlements(entitlements) when is_list(entitlements),
    do: Enum.filter(entitlements, & &1.granted)

  defp granted_entitlements(_), do: []

  defp subscription_label(sub) do
    plan = Map.get(sub, :__plan__)
    plan_name = (plan && (plan.label || plan.name)) || "plan"
    "#{plan_name} · #{String.slice(sub.id, 0, 8)}"
  end

  defp subscription_label_for(subscriptions, sub_id) do
    case Enum.find(subscriptions, &(&1.id == sub_id)) do
      nil -> String.slice(sub_id || "", 0, 8)
      sub -> subscription_label(sub)
    end
  end

  defp plan_features(%{features: features}) when is_map(features) and map_size(features) > 0 do
    features |> Map.keys() |> Enum.map(&humanize_feature/1) |> Enum.sort()
  end

  defp plan_features(_), do: ["basic"]

  defp humanize_feature(key) when is_binary(key), do: String.replace(key, "_", " ")
  defp humanize_feature(key) when is_atom(key), do: key |> to_string() |> String.replace("_", " ")
  defp humanize_feature(other), do: to_string(other)

  defp plan_bg("starter"), do: "#F0FDF4"
  defp plan_bg("growth"), do: "#EFF6FF"
  defp plan_bg("scale"), do: "#F5F3FF"
  defp plan_bg(_), do: "#F3F4F6"

  defp plan_fg("starter"), do: "#16A34A"
  defp plan_fg("growth"), do: "#2563EB"
  defp plan_fg("scale"), do: "#7C3AED"
  defp plan_fg(_), do: "#6B7280"

  # ADR-036 §4.5(3): unit_amount is the Money composite now — a plain integer
  # cents count is no longer the sole call shape (dollars(price.unit_amount)).
  defp dollars(%Money{} = money), do: dollars(Samen.Type.Money.cents(money))
  defp dollars(cents) when is_integer(cents),
    do: "$#{:erlang.float_to_binary(cents / 100, decimals: 2)}"

  defp dollars(_), do: "$0.00"
end
