defmodule Samen.Web.Billing.DunningLive do
  @moduledoc """
  Framework Billing / DUNNING page (F7 / G8) — the operator-relevant "who is behind on
  payment" view of the billing cockpit, host-agnostic (ADR-009). Surfaces every account
  currently in dunning (past-due invoices and/or a `:past_due` / `:unpaid` subscription),
  each with its dunning state: past-due invoice count, amount overdue, oldest days overdue,
  and subscription status.

  Read-ONLY. This is a lens over `Samen.Web.Billing.Dunning.rows/3` — a pure fold over the
  BOUNDED `Reads.invoices/2` + `Reads.subscriptions/2` (A3 read-bounding). It exposes no
  write affordance: dunning is a state you observe, not one you author here.

  ## MASKING (🔒 vault PII)

  The customer's `billing_name` / `billing_email` are vault-routed PII:

    * TENANT plane — CLEAR (the org reads its own customers);
    * OPERATOR plane — `%Masked{}` → •••• via `Phoenix.HTML.Safe`.

  The row's `:__customer__` is whatever `Samen.Api.PiiResolution` resolved on the actor's
  plane inside `Reads`. This LiveView NEVER calls the vault, NEVER unwraps a `%Masked{}`,
  and has no "show plaintext" branch — it renders whatever the resolver returned. This is
  the masking-watch-list surface's fourth-scope proof; see `dunning_masking_test.exs`.

  The header metrics (accounts in dunning, total overdue, oldest days) are non-PII bounded
  counts / cent amounts, folded from the same rows.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Billing.Live, only: [assign_mount: 2, billing_sidebar: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount

  alias Samen.Web.Billing.Dunning

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
    |> assign(
      no_org: CurrentOrg.no_org?(socket.assigns[:samen_mount], nil),
      org_id: nil,
      metrics: empty_metrics(),
      rows: []
    )
  end

  def load(socket, org_id) do
    mount = socket.assigns.samen_mount
    scope = Mount.scope(mount, org_id)
    # ONE clock reading threaded to both the rows and the header (they cannot desync).
    now = DateTime.utc_now()

    socket
    |> ensure_return_to()
    |> assign(
      no_org: false,
      org_id: org_id,
      metrics: Dunning.metrics(mount, scope, now),
      rows: Dunning.rows(mount, scope, now)
    )
  end

  defp ensure_return_to(socket) do
    if Map.has_key?(socket.assigns, :return_to), do: socket, else: assign(socket, return_to: nil)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="billing-dunning">
      <.app_shell>
        <:sidebar>
          <.billing_sidebar mount={@samen_mount} org_id={@org_id} active={:billing_dunning} return_to={@return_to} />
        </:sidebar>

        <.topbar title="Dunning" crumbs={crumbs(@samen_mount, @org_id, "Dunning")} />

        <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

        <%= if @no_org do %>
          <.no_org_card mount={@samen_mount} />
        <% else %>
          <span id="org-banner" style="display:none">Billing dunning org: {@org_id}</span>

          <div class="metrics">
            <.metric label="Accounts in dunning" value={@metrics.accounts} sub="behind on payment">
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M12 8v4M12 16h.01" /><circle cx="12" cy="12" r="9" />
                </svg>
              </:icon>
            </.metric>
            <.metric label="Total overdue" value={dollars(@metrics.overdue_cents)} sub="past-due amount">
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M12 2v20M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6" />
                </svg>
              </:icon>
            </.metric>
            <.metric label="Past-due invoices" value={@metrics.invoices}>
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M6 2h9l5 5v15H6z" /><path d="M9 12h7M9 16h7" />
                </svg>
              </:icon>
            </.metric>
            <.metric label="Oldest overdue" value={"#{@metrics.max_days_overdue}d"} sub="days past due">
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <circle cx="12" cy="12" r="9" /><path d="M12 7v5l3 2" />
                </svg>
              </:icon>
            </.metric>
          </div>

          <div class="wrap">
            <div id="dunning">
              <div class="gtitle">
                <h3>Accounts behind on payment</h3>
                <span class="n">{length(@rows)}</span>
                <span class="lane">· billing_name via PiiResolution · {plane_note(@samen_mount)}</span>
              </div>

              <.empty_state
                :if={@rows == []}
                class="dunning-empty"
                icon="✓"
                title="Nobody is behind on payment."
                body="Accounts with past-due invoices or a past-due / unpaid subscription appear here."
              />

              <.data_table :if={@rows != []}>
                <:head>
                  <th style="width:28%">Customer</th>
                  <th style="width:16%">Overdue</th>
                  <th style="width:14%">Invoices</th>
                  <th style="width:16%">Oldest</th>
                  <th style="width:26%">Subscription</th>
                </:head>
                <tr :for={row <- @rows} class="dunning-row" id={"dunning-#{row.customer_id}"}>
                  <td class="d-customer" style="font-weight:500;color:#3a3b45">
                    {render_billing_name(row.__customer__)}
                    <div class="d-email" style="font-size:11px;color:var(--muted)">
                      {render_billing_email(row.__customer__)}
                    </div>
                  </td>
                  <td class="d-amount" style="font-weight:500;color:#3a3b45">
                    {dollars(row.amount_cents)}
                  </td>
                  <td class="d-count" style="color:var(--muted)">
                    {row.past_due_count}
                  </td>
                  <td class="d-days">
                    <.pill variant={days_variant(row.max_days_overdue)}>{row.max_days_overdue}d past due</.pill>
                  </td>
                  <td class="d-sub">
                    <.pill variant={sub_status_variant(row.sub_status)}>{sub_status_label(row.sub_status)}</.pill>
                  </td>
                </tr>
              </.data_table>
            </div>
          </div>
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

  defp empty_metrics, do: %{accounts: 0, overdue_cents: 0, invoices: 0, max_days_overdue: 0}

  defp days_variant(days) when is_integer(days) and days >= 60, do: "bad"
  defp days_variant(days) when is_integer(days) and days >= 30, do: "warn"
  defp days_variant(_), do: "info"

  defp sub_status_label(nil), do: "no subscription"
  defp sub_status_label(status), do: to_string(status)

  defp sub_status_variant(:past_due), do: "warn"
  defp sub_status_variant(:unpaid), do: "bad"
  defp sub_status_variant(:active), do: "ok"
  defp sub_status_variant(:trialing), do: "info"
  defp sub_status_variant(:cancelled), do: "bad"
  defp sub_status_variant(_), do: "mut"

  defp dollars(cents) when is_integer(cents),
    do: "$#{:erlang.float_to_binary(cents / 100, decimals: 2)}"

  defp dollars(_), do: "$0.00"
end
