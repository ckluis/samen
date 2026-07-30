defmodule Samen.Web.Operator.DeliverabilityLive do
  @moduledoc """
  Framework OPERATOR / per-tenant deliverability drill-down at
  `/operator/deliverability/:org_id` (R2, T114; `_orch/ux/dogfood-report.md` R3 —
  P4's job-test FAIL, "why didn't this tenant get their email?"). Surfaces the
  T28/T30 delivery substrate an operator already has, for ONE tenant org:

    * **Suppression list** (`dlv_suppression`) — every subscriber currently
      suppressed + reason (`bounce | complaint | manual`) + source + since. A
      suppressed recipient is refused BEFORE the provider ever sees the send
      (`Samen.Delivery.Chokepoint`) — this is usually the FIRST place to look.
    * **Delivery timeline** (`dlv_email_event`) — every webhook-confirmed
      delivery event (`delivered | bounce | complaint | open | click`), most
      recent first, cross-referenced against the suppression set so a row can
      flag itself "suppressed" without a second read.

  Cross-linked from `AccountDetailLive`'s topbar ("Deliverability →") and from
  `WebhookDlqLive`'s org column (now surfaced, R5) for `domain == "delivery"`
  rows. Inherited at 0 vertical LOC via `samen_operator_routes/2`, mirroring
  `AutomationHealthLive`'s org_id-keyed, no-separate-index shape (no
  `/operator/deliverability` index page exists — same precedent).

  ## What this DOES NOT show (fail-honest, never fabricated)

  There is no persisted "send attempt" log: T28's lifecycle/auth sends are
  intentionally STATELESS per family (`Samen.Delivery.Chokepoint`'s moduledoc:
  "each family owns its own persistence shape... or nothing for the
  intentionally-stateless lifecycle/auth paths"). This page surfaces exactly
  what IS persisted — never claims a "sent" row it cannot prove.

  ## Masking (INV-1)

  `subscriber_id` is an opaque token on both tables — no PII column exists on
  either. "Who" resolves through `Samen.Api.PiiResolution.resolve/4`
  (`Samen.Web.Operator.DeliverabilityReads.resolve_recipient/5`) on the
  operator-viewing-tenant-PII actor: masked (`••••`) by default, PLAINTEXT only
  under a live `Samen.Reveal` grant on that specific subscriber. This LiveView
  never calls the vault, never unwraps a `%Masked{}`, has no plaintext branch —
  it renders whatever the resolver returns, exactly like every other operator
  PII surface (`render_name/1` / `render_email/1`, `Samen.Web.Operator.Live`).
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Operator.Live

  alias Samen.Web.Operator.DeliverabilityReads

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    {:ok, load(socket, Map.get(params, "org_id"))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, load(socket, Map.get(params, "org_id") || socket.assigns[:org_id])}
  end

  @doc false
  # `opts` carries the sanctioned `:actor`/`:grant`/`:repo` test-injection seam
  # (mirrors `AccountDetailLive.load/3`'s `:now` clock-injection opt) — production
  # mount/handle_params pass none, so the REAL configured actor/grant checker decide.
  def load(socket, org_id, opts \\ []) do
    mount = socket.assigns[:samen_mount]

    detail =
      if mount && org_id do
        actor = Keyword.get(opts, :actor, DeliverabilityReads.operator_actor())
        DeliverabilityReads.deliverability(mount, actor, org_id, opts)
      end

    assign(socket, org_id: org_id, detail: detail)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="operator-deliverability">
      <.app_shell>
        <:sidebar>
          <.operator_sidebar mount={@samen_mount} active={:deliverability} />
        </:sidebar>

        <.topbar title="Deliverability" crumbs={["Operator plane", "Deliverability", @org_id || "—"]}>
          <:actions>
            <a href="/operator/accounts" id="back-to-accounts" style="font-size:12px;color:#3B4CCA">← Accounts</a>
          </:actions>
        </.topbar>

        <%= cond do %>
          <% is_nil(@org_id) or is_nil(@detail) -> %>
            <div class="wrap">
              <div class="card" id="no-org" style="padding:22px 20px;color:var(--muted)">
                No tenant org resolved.
              </div>
            </div>
          <% true -> %>
            <div class="wrap">
              <.token_blind_bar chip="subscriber ids only · recipient resolves per plane">
                <b>Why didn't this tenant get their email?</b>
                Check suppression first — a suppressed recipient is refused BEFORE the
                provider ever sees the send. Then check the event history below for a
                bounce or complaint. There is no "sent" log here: lifecycle/auth sends
                are stateless by design — never fabricated on this page.
              </.token_blind_bar>

              <div id="suppression-list" style="margin-top:14px">
                <div class="gtitle">
                  <h3>Suppression list</h3>
                  <span class="n">{length(@detail.suppressions)}</span>
                  <span class="lane">· dlv_suppression · refused BEFORE the provider ever sees the send</span>
                </div>

                <.empty_state
                  :if={@detail.suppressions == []}
                  class="suppressions-empty"
                  icon="✓"
                  title="No suppressions."
                  body="Nobody in this tenant is currently suppressed — a delivery failure here is not a suppression."
                />

                <.data_table :if={@detail.suppressions != []}>
                  <:head>
                    <th>Recipient</th>
                    <th style="width:14%">Reason</th>
                    <th style="width:16%">Source</th>
                    <th style="width:20%">Since</th>
                  </:head>
                  <tr :for={s <- @detail.suppressions} class="suppression-row" id={"suppression-#{s.id}"}>
                    <td class="s-recipient">
                      <%= if s.__recipient__ do %>
                        <div>{render_email(s.__recipient__.email)}</div>
                        <div style="font-size:11px;color:var(--muted)">{render_name(s.__recipient__.name)}</div>
                      <% else %>
                        <span class="mono" style="color:var(--muted)">subscriber {short_id(s.subscriber_id)}</span>
                      <% end %>
                    </td>
                    <td class="s-reason"><.pill variant={reason_variant(s.reason)}>{s.reason}</.pill></td>
                    <td class="s-source" style="color:var(--muted)">{s.source_provider || "—"}</td>
                    <td class="s-since" style="color:var(--muted)">{ts(s.inserted_at)}</td>
                  </tr>
                </.data_table>
              </div>

              <div id="delivery-timeline" style="margin-top:18px">
                <div class="gtitle">
                  <h3>Delivery timeline</h3>
                  <span class="n">{length(@detail.events)}</span>
                  <span class="lane">· dlv_email_event · delivered / bounce / complaint / open / click</span>
                </div>

                <.empty_state
                  :if={@detail.events == []}
                  class="events-empty"
                  icon="✉"
                  title="No delivery events."
                  body="No webhook-confirmed delivery events for this tenant yet — real sends generate these via the provider's bounce/complaint webhooks."
                />

                <.data_table :if={@detail.events != []}>
                  <:head>
                    <th style="width:14%">Kind</th>
                    <th>Recipient</th>
                    <th style="width:12%">Provider</th>
                    <th style="width:12%">Suppressed?</th>
                    <th style="width:20%">Occurred</th>
                  </:head>
                  <tr :for={e <- @detail.events} class="event-row" id={"event-#{e.id}"}>
                    <td class="e-kind"><.pill variant={kind_variant(e.kind)}>{e.kind}</.pill></td>
                    <td class="e-recipient">
                      <%= if e.__recipient__ do %>
                        <div>{render_email(e.__recipient__.email)}</div>
                        <div style="font-size:11px;color:var(--muted)">{render_name(e.__recipient__.name)}</div>
                      <% else %>
                        <span class="mono" style="color:var(--muted)">subscriber {short_id(e.subscriber_id)}</span>
                      <% end %>
                    </td>
                    <td class="e-provider" style="color:var(--muted)">{e.provider}</td>
                    <td class="e-suppressed">
                      <span :if={MapSet.member?(@detail.suppressed_subscriber_ids, e.subscriber_id)} class="pill pill-bad">
                        suppressed
                      </span>
                      <span :if={!MapSet.member?(@detail.suppressed_subscriber_ids, e.subscriber_id)} style="color:var(--muted)">
                        —
                      </span>
                    </td>
                    <td class="e-occurred" style="color:var(--muted)">{ts(e.occurred_at)}</td>
                  </tr>
                </.data_table>
              </div>
            </div>
        <% end %>
      </.app_shell>
    </div>
    """
  end

  # -- helpers (bounded enums/ids only, or PII already resolved per plane) -----

  defp short_id(nil), do: "—"
  defp short_id(id), do: "#{String.slice(to_string(id), 0, 8)}…"

  defp reason_variant("bounce"), do: "warn"
  defp reason_variant("complaint"), do: "bad"
  defp reason_variant("manual"), do: "info"
  defp reason_variant(_), do: "mut"

  defp kind_variant("delivered"), do: "ok"
  defp kind_variant("bounce"), do: "warn"
  defp kind_variant("complaint"), do: "bad"
  defp kind_variant("open"), do: "info"
  defp kind_variant("click"), do: "info"
  defp kind_variant(_), do: "mut"

  defp ts(nil), do: "—"
  defp ts(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  defp ts(other), do: to_string(other)
end
