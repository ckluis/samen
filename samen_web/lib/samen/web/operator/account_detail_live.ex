defmodule Samen.Web.Operator.AccountDetailLive do
  @moduledoc """
  Framework OPERATOR / Account drill-down at `/operator/accounts/:id` (WS-B / B4,
  design §2.2; ADR-019) — the surface CSMs live in, inherited by every vertical at
  0 LOC via `samen_operator_routes/2`:

    * **The health score + factor breakdown** — the `Samen.Web.Operator.HealthScore`
      composite, rendered WITH its per-dimension value/weight/contribution/explanation
      (explainable by construction, AC-G17-3 — no second computation, no mystery
      number). The billing dimension carries the dunning evidence that fixes the
      gate-flagged health/dunning incoherence (AC-G17-2).
    * **The MRR movement timeline** — the account's `mov` ledger rows (B1) on the
      WS-A `timeline/1` kit component. Token-blind columns only.
    * **Linked evidence** — the account's desk tickets (requester through
      `PiiResolution` per plane) and its invoices (the billing factor's inputs,
      past-due rows flagged).

  ## Masking / PII posture (AC-G17-5)

  Health is NOT a new PII surface (ADR-019 §3): every score input and every
  breakdown string is a bounded count/enum/amount/day-count. The ONLY PII on this
  page is the evidence joins the accounts CRM already renders (tenant-admin /
  requester name) — resolved by `Samen.Api.PiiResolution` per plane: CLEAR on the
  operator org's own tenant plane (the SaaS owns population 1), `••••` on any
  hand-crafted `plane: :operator` mount (fail-MASKED, never fail-clear). This
  LiveView never calls the vault, never unwraps a `%Masked{}`, and has no plaintext
  branch. Bounded reads only, through `Reads.account_detail/5`.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Operator.Live

  alias Samen.Web.Operator
  alias Samen.Web.Operator.HealthScore
  alias Samen.Web.Operator.Reads

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    {:ok, load(socket, Map.get(params, "id"))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, load(socket, Map.get(params, "id") || socket.assigns[:account_id])}
  end

  @doc false
  # `opts` carries the sanctioned `:now` clock-injection through to `Reads.account_detail/5`
  # (defaults to `DateTime.utc_now/0`). Production mount/handle_params pass no `:now`; the
  # B4-P2-1 regression test pins it to make the not-yet-due boundary deterministic.
  def load(socket, account_id, opts \\ []) do
    mount = socket.assigns[:samen_mount]
    operator_org_id = mount && Operator.org_id(mount)

    detail =
      if operator_org_id && account_id do
        Reads.account_detail(mount, Operator.scope(mount), operator_org_id, account_id, opts)
      end

    assign(socket, account_id: account_id, no_org: is_nil(operator_org_id), detail: detail)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="operator-account-detail">
      <.app_shell>
        <:sidebar>
          <.operator_sidebar mount={@samen_mount} active={:accounts} />
        </:sidebar>

        <.topbar
          title={(@detail && @detail.account.name) || "Account"}
          crumbs={["Operator plane", "Accounts", (@detail && @detail.account.name) || "—"]}
        >
          <:actions>
            <a
              :if={@account_id}
              href={"/operator/deliverability/#{@account_id}"}
              id="account-deliverability-link"
              style="font-size:12px;color:#3B4CCA;margin-right:14px"
            >
              Deliverability →
            </a>
            <a
              :if={@account_id}
              href={"/operator/automation/#{@account_id}"}
              id="account-automation-health-link"
              style="font-size:12px;color:#3B4CCA;margin-right:14px"
            >
              Automation health →
            </a>
            <a
              :if={@account_id}
              href={"/operator/activity/#{@account_id}"}
              id="account-activity-link"
              style="font-size:12px;color:#3B4CCA;margin-right:14px"
            >
              Activity →
            </a>
            <a href="/operator/accounts" id="back-to-accounts" style="font-size:12px;color:#3B4CCA">← Accounts</a>
          </:actions>
        </.topbar>

        <%= cond do %>
          <% @no_org -> %>
            <div class="wrap">
              <div class="card" id="no-org" style="padding:22px 20px;color:var(--muted)">
                No operator org resolved.
              </div>
            </div>
          <% is_nil(@detail) -> %>
            <div class="wrap">
              <div class="card" id="account-missing" style="padding:22px 20px;color:var(--muted)">
                Account not found in this book of business.
              </div>
            </div>
          <% true -> %>
            <div class="metrics">
              <.metric label="Health score" value={"#{@detail.account.__health__.score} / 100"} sub={band_label(@detail.account.__health__.band)}>
                <:icon>
                  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                    <path d="M22 12h-4l-3 9L9 3l-3 9H2" />
                  </svg>
                </:icon>
              </.metric>
              <.metric label="MRR" value={dollars(@detail.account.__mrr_cents__)} sub="subscription to the SaaS">
                <:icon>
                  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                    <path d="M12 2v20M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6" />
                  </svg>
                </:icon>
              </.metric>
              <.metric label="Seats" value={@detail.account.__seats__} sub="active memberships">
                <:icon>
                  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                    <circle cx="9" cy="8" r="4" /><path d="M2 21v-2a6 6 0 0 1 12 0v2" /><path d="M16 4a4 4 0 0 1 0 8" />
                  </svg>
                </:icon>
              </.metric>
              <.metric label="Open tickets" value={@detail.account.__open_tickets__} sub={"#{@detail.account.__breaching_tickets__} breaching SLA"}>
                <:icon>
                  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                    <path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z" />
                  </svg>
                </:icon>
              </.metric>
            </div>

            <div class="wrap">
              <div id="health-breakdown">
                <div class="gtitle">
                  <h3>Why this score</h3>
                  <.pill variant={band_variant(@detail.account.__health__.band)}>
                    {band_label(@detail.account.__health__.band)}
                  </.pill>
                  <span class="lane">· four weighted dimensions · contributions sum to the composite · dunning caps billing (ADR-019)</span>
                </div>
                <.data_table>
                  <:head>
                    <th style="width:12%">Dimension</th>
                    <th style="width:8%">Weight</th>
                    <th style="width:10%">Input</th>
                    <th style="width:12%">Contribution</th>
                    <th style="width:10%">Rating</th>
                    <th>Why</th>
                  </:head>
                  <tr :for={f <- @detail.account.__health__.factors} class="factor-row" id={"factor-#{f.name}"}>
                    <td class="f-name" style="font-weight:500;color:#3a3b45">{factor_label(f.name)}</td>
                    <td class="f-weight" style="color:var(--muted)">{f.weight}</td>
                    <td class="f-value">{factor_value(f.value)}</td>
                    <td class="f-contribution" style="font-weight:500">{f.contribution} pts</td>
                    <td class="f-band">
                      <.pill variant={band_variant(HealthScore.factor_band(f))}>{band_label(HealthScore.factor_band(f))}</.pill>
                    </td>
                    <td class="f-explanation" style="font-size:12px;color:var(--muted)">{f.explanation}</td>
                  </tr>
                </.data_table>
              </div>

              <div id="mov-timeline" style="margin-top:18px">
                <div class="gtitle">
                  <h3>MRR movement timeline</h3>
                  <span class="n">{length(@detail.movements)}</span>
                  <span class="lane">· the mov ledger (B1) · token-blind ids / enums / cents</span>
                </div>
                <.timeline entries={movement_entries(@detail.movements)} empty="No subscription movements on the ledger yet." />
              </div>

              <div id="account-tickets" style="margin-top:18px">
                <div class="gtitle">
                  <h3>Desk tickets</h3>
                  <span class="n">{length(@detail.tickets)}</span>
                  <span class="lane">· the support factor's evidence · requester resolves per plane</span>
                </div>
                <.empty_state
                  :if={@detail.tickets == []}
                  class="tickets-empty"
                  icon="◫"
                  title="No desk tickets."
                  body="Tickets this account files with the SaaS land here and feed the support dimension."
                />
                <.data_table :if={@detail.tickets != []}>
                  <:head>
                    <th style="width:40%">Subject</th>
                    <th style="width:12%">Status</th>
                    <th style="width:12%">Priority</th>
                    <th style="width:12%">SLA</th>
                    <th>Requester</th>
                  </:head>
                  <tr :for={t <- @detail.tickets} class="ticket-row" id={"account-ticket-#{t.id}"}>
                    <td class="t-subject" style="font-weight:500;color:#3a3b45">{t.subject}</td>
                    <td class="t-status"><.pill variant={ticket_status_variant(t.status)}>{t.status}</.pill></td>
                    <td class="t-priority" style="color:var(--muted)">{t.priority}</td>
                    <td class="t-sla">{if t.breached, do: "breached", else: "ok"}</td>
                    <td class="t-requester">{t.__requester__ && render_name(t.__requester__.full_name)}</td>
                  </tr>
                </.data_table>
              </div>

              <div id="account-invoices" style="margin-top:18px">
                <div class="gtitle">
                  <h3>Billing events</h3>
                  <span class="n">{length(@detail.invoices)}</span>
                  <span class="lane">· the billing factor's evidence · past-due rows are the dunning input</span>
                </div>
                <.empty_state
                  :if={@detail.invoices == []}
                  class="invoices-empty"
                  icon="▤"
                  title="No invoices."
                  body="Invoices the SaaS issues this account land here and feed the billing dimension."
                />
                <.data_table :if={@detail.invoices != []}>
                  <:head>
                    <th style="width:16%">Status</th>
                    <th style="width:18%">Amount due</th>
                    <th style="width:22%">Due</th>
                    <th style="width:22%">Paid</th>
                    <th>Dunning</th>
                  </:head>
                  <tr :for={inv <- @detail.invoices} class="invoice-row" id={"account-invoice-#{inv.id}"}>
                    <td class="i-status"><.pill variant={invoice_status_variant(inv)}>{inv.status}</.pill></td>
                    <td class="i-amount" style="font-weight:500">{dollars(inv.amount_due_cents || 0)}</td>
                    <td class="i-due" style="color:var(--muted)">{dt(inv.due_date)}</td>
                    <td class="i-paid" style="color:var(--muted)">{dt(inv.paid_at)}</td>
                    <td class="i-dunning">
                      <span :if={inv.__past_due__} class="dunning-flag" style="color:#B42318;font-weight:500">past due</span>
                      <span :if={!inv.__past_due__} style="color:var(--muted)">—</span>
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

  # -- helpers (bounded enums / cents / dates only — no PII enters these) ---------

  defp movement_entries(movements) do
    Enum.map(movements, fn m ->
      %{
        id: m.id,
        type: m.kind,
        subject: "#{m.kind} #{signed_dollars(m.mrr_delta_cents)}",
        status: nil,
        at: m.occurred_at,
        who: nil,
        body: "MRR #{dollars(m.mrr_before_cents || 0)} → #{dollars(m.mrr_after_cents || 0)}"
      }
    end)
  end

  defp signed_dollars(cents) when is_integer(cents) and cents < 0, do: "−#{dollars(-cents)}"
  defp signed_dollars(cents) when is_integer(cents), do: "+#{dollars(cents)}"
  defp signed_dollars(_), do: dollars(0)

  defp factor_label(:billing), do: "Billing"
  defp factor_label(:activity), do: "Activity"
  defp factor_label(:support), do: "Support"
  defp factor_label(:adoption), do: "Adoption"
  defp factor_label(other), do: to_string(other)

  defp factor_value(:unknown), do: "no signal"
  defp factor_value(v) when is_float(v), do: "#{round(v * 100)}%"
  defp factor_value(other), do: to_string(other)

  defp band_variant(:healthy), do: "ok"
  defp band_variant(:watch), do: "info"
  defp band_variant(:at_risk), do: "warn"
  defp band_variant(:critical), do: "bad"
  defp band_variant(_), do: "mut"

  defp band_label(:healthy), do: "healthy"
  defp band_label(:watch), do: "watch"
  defp band_label(:at_risk), do: "at risk"
  defp band_label(:critical), do: "critical"
  defp band_label(_), do: "no signal"

  defp ticket_status_variant(:open), do: "warn"
  defp ticket_status_variant(:pending), do: "info"
  defp ticket_status_variant(:solved), do: "ok"
  defp ticket_status_variant(:closed), do: "mut"
  defp ticket_status_variant(_), do: "mut"

  # `__past_due__` is the Reads-computed determination (ONE `utc_now` per assembly,
  # B9 carry B4-P2-1) — this LiveView renders it verbatim and never reads a clock,
  # so the dunning flag can never desync from the score's dunning evidence.
  defp invoice_status_variant(inv) do
    cond do
      inv.__past_due__ -> "bad"
      inv.status == :paid -> "ok"
      true -> "mut"
    end
  end

  defp dt(%DateTime{} = d), do: Calendar.strftime(d, "%Y-%m-%d")
  defp dt(_), do: "—"
end
