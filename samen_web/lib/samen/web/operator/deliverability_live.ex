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
  alias Samen.Web.Operator.Impersonation

  @impl true
  def mount(params, session, socket) do
    socket =
      socket
      |> assign_mount(session)
      |> Impersonation.assign_identity(session, params)

    {:ok, load(socket, Map.get(params, "org_id"))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, load(socket, Map.get(params, "org_id") || socket.assigns[:org_id])}
  end

  # T150 — the open-session-with-reason affordance the denied state renders. Opens a REAL
  # `Samen.Impersonation` session (reason required, same-tx audit + auto-expire, tenant-visible
  # ledger) for the acting operator over this target org, then re-renders masked.
  @impl true
  def handle_event("open_session", %{"reason" => reason}, socket) do
    org_id = socket.assigns[:org_id]

    case Impersonation.open_from_socket(socket, org_id, reason) do
      {:ok, _session} ->
        {:noreply, load(socket, org_id)}

      {:error, reason} ->
        {:noreply, assign(socket, open_error: open_error_copy(reason))}
    end
  end

  defp open_error_copy(:reason_required), do: "A reason for access is required."
  defp open_error_copy(:not_authorized), do: "Your operator role may not open an impersonation session."
  defp open_error_copy({:pii_shaped_reason, _}), do: "The reason must name the ticket, not the person (no email/SSN/phone)."
  defp open_error_copy(_), do: "The impersonation session could not be opened."

  @doc false
  # `opts` carries the sanctioned `:actor`/`:grant`/`:repo` test-injection seam
  # (mirrors `AccountDetailLive.load/3`'s `:now` clock-injection opt) — production
  # mount/handle_params pass none.
  #
  # T150 — the deny-on-read GATE: production reads a SPECIFIC tenant's masked delivery
  # state ONLY through a real `Samen.Impersonation` session. With no active session the page
  # DENIES (no detail, no PII) and renders the open-session affordance; with one, the actor is
  # the REAL impersonation-scope actor (`plane: :operator` + the REAL session id) so PII masks
  # `••••` by default. A caller injecting `:actor` (the masking gate tests) supplies the
  # already-resolved actor and bypasses the session gate — it is exercising `PiiResolution`,
  # not this gate.
  def load(socket, org_id, opts \\ []) do
    mount = socket.assigns[:samen_mount]

    cond do
      is_nil(mount) or is_nil(org_id) ->
        assign(socket, org_id: org_id, detail: nil, impersonation: :none, session_info: nil, open_error: nil)

      Keyword.has_key?(opts, :actor) ->
        detail = DeliverabilityReads.deliverability(mount, Keyword.fetch!(opts, :actor), org_id, opts)
        assign(socket, org_id: org_id, detail: detail, impersonation: :active, session_info: nil, open_error: nil)

      true ->
        case Impersonation.gate_socket(socket, socket.assigns[:samen_operator_id], org_id) do
          {:ok, actor, info} ->
            detail = DeliverabilityReads.deliverability(mount, actor, org_id, opts)
            assign(socket, org_id: org_id, detail: detail, impersonation: :active, session_info: info, open_error: nil)

          :out_of_scope ->
            assign(socket, org_id: org_id, detail: nil, impersonation: :out_of_scope, session_info: nil, open_error: nil)

          :denied ->
            assign(socket, org_id: org_id, detail: nil, impersonation: :denied, session_info: nil, open_error: nil)
        end
    end
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
          <% @impersonation == :out_of_scope -> %>
            <div class="wrap">
              <div class="card" id="out-of-scope" style="padding:22px 20px">
                <div style="color:var(--red);font-weight:600" id="not-in-scope">
                  This account is not in your scope.
                </div>
                <p style="color:var(--muted);margin:10px 0 0;font-size:13px">
                  Your operator assignment does not cover this tenant, so its deliverability is not
                  available to you and no impersonation session can be opened for it. Ask an
                  operator-admin to assign this account if you need access.
                </p>
              </div>
            </div>
          <% @impersonation == :denied -> %>
            <div class="wrap">
              <div class="card" id="impersonation-required" style="padding:22px 20px">
                <div style="color:var(--red);font-weight:600" id="no-session">
                  Access denied — no active impersonation session for this tenant.
                </div>
                <p style="color:var(--muted);margin:10px 0 14px;font-size:13px">
                  Viewing a specific tenant's deliverability is a per-tenant drill-in: it requires a
                  short-TTL, reason-required <b>impersonation session</b>, recorded in the tenant's
                  audit ledger (who / when / why). Start one below.
                </p>
                <div :if={@open_error} id="open-error" style="color:#B42318;font-size:12px;margin-bottom:8px">
                  {@open_error}
                </div>
                <form phx-submit="open_session" id="open-session-form" style="display:flex;gap:8px;align-items:flex-start">
                  <input
                    type="text"
                    name="reason"
                    id="session-reason-input"
                    placeholder="Reason (e.g. ticket #1234: bounce investigation)"
                    style="flex:1;padding:8px 10px;border:1px solid #D0D5DD;border-radius:8px;font-size:13px"
                  />
                  <button type="submit" id="start-session-btn" style="padding:8px 14px;border-radius:8px;background:#3B4CCA;color:#fff;font-size:13px">
                    Start session (masked)
                  </button>
                </form>
              </div>
            </div>
          <% is_nil(@org_id) or is_nil(@detail) -> %>
            <div class="wrap">
              <div class="card" id="no-org" style="padding:22px 20px;color:var(--muted)">
                No tenant org resolved.
              </div>
            </div>
          <% true -> %>
            <div class="wrap">
              <div :if={@session_info} id="session-accountability" class="card" style="padding:10px 14px;margin-bottom:12px;font-size:12px;color:var(--muted)">
                <b style="color:inherit">Masked impersonation session.</b>
                operator <span class="mono">{@session_info.operator_id}</span>
                · reason: <span id="session-reason">{@session_info.reason}</span>
                · expires <span id="session-expiry">{@session_info.expires_at}</span>
                — recorded in this tenant's audit ledger.
              </div>
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
