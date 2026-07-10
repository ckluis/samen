defmodule Samen.Web.Billing.OverviewLive do
  @moduledoc """
  Framework Billing / Customers + Subscriptions dashboard — the inherited Billing domain
  rendered as real UI, host-agnostic (ADR-009).

  The customer's `billing_name` / `billing_email` are PII:

    * TENANT plane — CLEAR (the org reads its own customers).
    * OPERATOR plane — `%Masked{}` → •••• via `Phoenix.HTML.Safe`.

  Metric cards (MRR, active subs, outstanding, collected) are non-PII DB aggregates.
  NEVER calls the vault; renders whatever the resolver returned.

  ## A3 retrofit — ListLive + the customer-create PII write surface

  The subscription list rides the A2 kit contract: `use Samen.Web.ListLive` + the
  BOUNDED `Reads.subscriptions_page/3` (customer + plan joined AFTER paging). The
  write side (AC-G1-1/2 + MC-1/MC-2): "New customer" opens a `modal/1` hosting an
  `AshPhoenix.Form`-backed `simple_form/1` create — `billing_name` / `billing_email`
  are VAULT-ROUTED scalars, so this is a NEW PII WRITE SURFACE:

    * the tenant's plaintext submits through the vault write path — the same
      `Samen.Vault.Change` chokepoint as seeds (MC-2); never a raw column write;
    * on the operator plane the affordance is absent (posture) AND the write itself
      is REJECTED by `Samen.Pii.WriteGuard` at the Ash write path (MC-1 / RP-G1-7) —
      this LiveView adds no policy of its own and never sees a token or unwraps a
      `%Masked{}`. The kit `form_field/1` masked branch guarantees a `%Masked{}` is
      never echoed into an editable input.

  Each subscription row carries a `delete_confirm/1` (the blueprint's sanctioned
  destroy; admin-gated, so the delete goes through `Reads.write_scope/2` — same-org,
  PLANE-PRESERVING role elevation). Customer creates are member-gated and use the
  plain mount scope.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Billing.Live, only: [assign_mount: 2, billing_sidebar: 1, writable?: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount

  alias Samen.Web.Billing.Reads

  use Samen.Web.ListLive,
    resource: Subscription,
    reads: &Samen.Web.Billing.Reads.subscriptions_page/3,
    sortable: [:status, :current_period_end],
    filter_fields: [],
    default_sort: {:status, :asc}

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
    |> assign(no_org: CurrentOrg.no_org?(socket.assigns[:samen_mount], nil), org_id: nil, metrics: nil)
    |> assign(page: %Samen.Web.Page{}, list_state: %Samen.Web.ListState{})
    |> assign(show_new: false, new_form: nil)
    |> assign_new(:delete_error, fn -> nil end)
  end

  def load(socket, org_id) do
    mount = socket.assigns.samen_mount
    scope = Mount.scope(mount, org_id)

    socket
    |> ensure_return_to()
    |> assign(no_org: false, org_id: org_id, metrics: Reads.metrics(mount, scope))
    |> assign_new(:show_new, fn -> false end)
    |> assign_new(:delete_error, fn -> nil end)
    |> assign(new_form: new_customer_form(mount, scope))
    |> init_list(mount, scope)
  end

  # -- A3 CRUD events (list events belong to the ListLive hook) -----------------

  @impl true
  def handle_event("new_customer", _params, socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns
    scope = Mount.scope(mount, org_id)
    {:noreply, assign(socket, show_new: true, new_form: new_customer_form(mount, scope))}
  end

  def handle_event("cancel_new", _params, socket) do
    {:noreply, assign(socket, show_new: false)}
  end

  def handle_event("validate_new", %{"form" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.new_form, with_org(params, socket))
    {:noreply, assign(socket, new_form: form)}
  end

  # The customer create submit. `org_id` is the server-side fact, never client input.
  # On the tenant plane the vaulted billing_name/billing_email route through the vault
  # (MC-2); on the operator plane `Samen.Pii.WriteGuard` REJECTS the plaintext at the
  # write path (MC-1) and the error renders inline — no LiveView policy.
  def handle_event("save_new", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.new_form, params: with_org(params, socket)) do
      {:ok, _customer} ->
        {:noreply, socket |> assign(show_new: false) |> load(socket.assigns.org_id)}

      {:error, form} ->
        {:noreply, assign(socket, new_form: form)}
    end
  end

  # FAIL-HONEST delete: a subscription with linked invoices is refused by the DB (FK)
  # and the refusal is SURFACED on the page.
  def handle_event("delete", %{"id" => id}, socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns

    case Reads.delete_subscription(mount, Reads.write_scope(mount, org_id), id) do
      :ok ->
        {:noreply, load(assign(socket, delete_error: nil), org_id)}

      {:error, _reason} ->
        {:noreply,
         assign(socket,
           delete_error: "Could not delete this subscription — it still has linked records (invoices)."
         )}
    end
  end

  defp new_customer_form(mount, scope) do
    Mount.resource(mount, Customer)
    |> AshPhoenix.Form.for_create(:create, scope: scope)
    |> to_form()
  end

  defp with_org(params, socket), do: Map.put(params, "org_id", socket.assigns.org_id)

  defp ensure_return_to(socket) do
    if Map.has_key?(socket.assigns, :return_to), do: socket, else: assign(socket, return_to: nil)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="billing">
      <.app_shell>
        <:sidebar>
          <.billing_sidebar mount={@samen_mount} org_id={@org_id} active={:billing_overview} return_to={@return_to} />
        </:sidebar>

        <.topbar title="Billing" crumbs={crumbs(@samen_mount, @org_id, "Overview")}>
          <:actions>
            <.button :if={writable?(@samen_mount) and not @no_org} variant="primary" phx-click="new_customer" id="new-customer">
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M12 3v18M3 12h18" />
                </svg>
              </:icon>
              New customer
            </.button>
          </:actions>
        </.topbar>

        <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

        <%= if @no_org do %>
          <.no_org_card mount={@samen_mount} />
        <% else %>
          <span id="org-banner" style="display:none">Billing org: {@org_id}</span>

          <div :if={@delete_error} class="wrap" style="margin-bottom:0">
            <div class="card form-error" id="delete-error" style="padding:10px 14px;color:var(--bad, #b91c1c);font-size:12px">
              {@delete_error}
            </div>
          </div>

          <div class="metrics">
            <.metric label="MRR" value={dollars((@metrics && @metrics.mrr_cents) || 0)} sub="monthly recurring">
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M12 2v20M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6" />
                </svg>
              </:icon>
            </.metric>
            <.metric label="Active subscriptions" value={(@metrics && @metrics.active_subs) || 0}>
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <rect x="3" y="4" width="18" height="16" rx="2" /><path d="M3 9h18" /><path d="M8 15h4M8 12h8" />
                </svg>
              </:icon>
            </.metric>
            <.metric label="Outstanding" value={dollars((@metrics && @metrics.outstanding_cents) || 0)} sub="open invoices">
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M9 14l2 2 4-4" /><rect x="3" y="3" width="18" height="18" rx="2" />
                </svg>
              </:icon>
            </.metric>
            <.metric label="Collected this month" value={dollars((@metrics && @metrics.collected_cents) || 0)}>
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <circle cx="12" cy="12" r="9" /><path d="M9 12l2 2 4-4" />
                </svg>
              </:icon>
            </.metric>
          </div>

          <div class="wrap">
            <div id="subscriptions">
              <div class="gtitle">
                <h3>Customers &amp; Subscriptions</h3>
                <span class="n">{length(@page.items)}</span>
                <span class="lane">· billing_name / billing_email via PiiResolution · {plane_note(@samen_mount)}</span>
              </div>
              <.list_view
                id="subscriptions-list"
                page={@page}
                state={@list_state}
                row_class="subscription-row"
                filter_placeholder="Filter subscriptions…"
                empty_text="No subscriptions yet."
              >
                <:head>
                  <th scope="col" style="width:26%">Customer</th>
                  <th scope="col" style="width:16%">Plan</th>
                  <th scope="col" style="width:14%">MRR</th>
                  <.sort_header field={:status} label="Status" sort={@list_state.sort} width="14%" />
                  <.sort_header field={:current_period_end} label="Period end" sort={@list_state.sort} width="16%" />
                  <th :if={writable?(@samen_mount)} scope="col" style="width:10%"><span class="sr-only">Actions</span></th>
                </:head>
                <:row :let={sub}>
                  <td class="sub-customer">
                    <div style="display:flex;align-items:center;gap:8px">
                      <div class="av" style="width:28px;height:28px;border-radius:6px;background:#EDE9FE;color:#5B21B6;font-size:10px;font-weight:700;display:flex;align-items:center;justify-content:center;flex-shrink:0">
                        {customer_initials(sub.__customer__)}
                      </div>
                      <div>
                        <div class="sub-name" style="font-weight:500;color:#3a3b45">
                          {render_billing_name(sub.__customer__)}
                        </div>
                        <div class="sub-email" style="font-size:11px;color:var(--muted)">
                          {render_billing_email(sub.__customer__)}
                        </div>
                      </div>
                    </div>
                  </td>
                  <td class="sub-plan">
                    <.pill variant={plan_variant(plan_name(sub.__plan__))}>{plan_label(sub.__plan__)}</.pill>
                  </td>
                  <td class="sub-mrr" style="font-weight:500;color:#3a3b45">
                    {plan_mrr(sub.__plan__)}
                  </td>
                  <td class="sub-status">
                    <.pill variant={sub_status_variant(sub.status)}>{sub.status}</.pill>
                  </td>
                  <td class="sub-period" style="color:var(--muted);font-size:12px">
                    {format_date(sub.current_period_end)}
                  </td>
                  <td :if={writable?(@samen_mount)} class="sub-actions">
                    <.delete_confirm phx-click="delete" phx-value-id={sub.id} />
                  </td>
                </:row>
              </.list_view>
            </div>
          </div>

          <.modal :if={@show_new and @new_form != nil and writable?(@samen_mount)} id="new-customer-modal" title="New customer" on_cancel="cancel_new">
            <.simple_form :let={f} for={@new_form} id="new-customer-form" phx-change="validate_new" phx-submit="save_new">
              <.form_field field={f[:billing_name]} label="Billing name (🔒 PII)" />
              <.form_field field={f[:billing_email]} label="Billing email (🔒 PII)" type="email" />
              <.form_field
                field={f[:status]}
                label="Status"
                type="select"
                options={[{"active", "active"}, {"inactive", "inactive"}]}
              />
              <.form_field field={f[:currency]} label="Currency" />
              <:actions>
                <.button variant="primary" type="submit">Save customer</.button>
                <.button type="button" phx-click="cancel_new">Cancel</.button>
              </:actions>
            </.simple_form>
          </.modal>
        <% end %>
      </.app_shell>
    </div>
    """
  end

  # -- helpers (MASKING INVARIANT) -------------------------------------------

  defp crumbs(mount, org_id, leaf), do: [CurrentOrg.name(mount, org_id), "Billing", leaf]

  defp plane_note(%Mount{plane: %{kind: :operator}}), do: "operator plane · masked"
  defp plane_note(_), do: "your org in the clear"

  defp render_billing_name(nil), do: "—"
  defp render_billing_name(%{billing_name: %Samen.Masked{} = m}), do: m
  defp render_billing_name(%{billing_name: name}) when is_binary(name), do: name
  defp render_billing_name(_), do: "—"

  defp render_billing_email(nil), do: ""
  defp render_billing_email(%{billing_email: %Samen.Masked{} = m}), do: m
  defp render_billing_email(%{billing_email: email}) when is_binary(email), do: email
  defp render_billing_email(_), do: ""

  defp customer_initials(nil), do: "?"
  defp customer_initials(%{billing_name: %Samen.Masked{}}), do: "··"

  defp customer_initials(%{billing_name: name}) when is_binary(name) do
    name
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join("", &String.slice(&1, 0, 1))
    |> String.upcase()
  end

  defp customer_initials(_), do: "?"

  defp plan_name(nil), do: "unknown"
  defp plan_name(%{name: name}), do: name || "unknown"
  defp plan_name(_), do: "unknown"

  defp plan_label(nil), do: "—"
  defp plan_label(%{label: label}) when is_binary(label), do: label
  defp plan_label(%{name: name}) when is_binary(name), do: String.capitalize(name)
  defp plan_label(_), do: "—"

  defp plan_mrr(nil), do: "—"

  defp plan_mrr(%{name: name}) do
    case name do
      "starter" -> "$99/mo"
      "growth" -> "$299/mo"
      "scale" -> "$799/mo"
      _ -> "—"
    end
  end

  defp plan_mrr(_), do: "—"

  defp plan_variant("starter"), do: "mut"
  defp plan_variant("growth"), do: "info"
  defp plan_variant("scale"), do: "ok"
  defp plan_variant(_), do: "mut"

  defp sub_status_variant(:active), do: "ok"
  defp sub_status_variant(:trialing), do: "info"
  defp sub_status_variant(:past_due), do: "warn"
  defp sub_status_variant(:inactive), do: "mut"
  defp sub_status_variant(:cancelled), do: "bad"
  defp sub_status_variant(:unpaid), do: "bad"
  defp sub_status_variant(_), do: "mut"

  defp dollars(cents) when is_integer(cents),
    do: "$#{:erlang.float_to_binary(cents / 100, decimals: 2)}"

  defp dollars(_), do: "$0.00"

  defp format_date(nil), do: "—"
  defp format_date(%DateTime{} = dt), do: "#{dt.year}-#{pad(dt.month)}-#{pad(dt.day)}"
  defp format_date(_), do: "—"

  defp pad(n), do: String.pad_leading(to_string(n), 2, "0")
end
