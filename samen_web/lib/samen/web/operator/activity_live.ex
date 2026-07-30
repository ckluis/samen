defmodule Samen.Web.Operator.ActivityLive do
  @moduledoc """
  Framework OPERATOR / per-tenant activity feed at `/operator/activity/:org_id`
  (R3/T115; `_orch/ux/dogfood-report.md` R4 — P4's "what changed in org X in
  the last 24h?" job-test FAIL, `_orch/ux/persona-4-operator-daily.md` F7).
  Answers it with a chronological, org-scoped, time-windowed reader over
  `Samen.Web.Operator.ActivityReads.activity/3` — the governance tier
  (`aud_event`: T38's mandatory impersonation-write rows (P7-F1) + the org's
  OTHER governance events — webhook/file/notification/ticket-breach/
  workflow/marketing "system" events + the Approval decision lifecycle, each
  independently org-scoped per the reads module's INV-2 discipline) merged
  with the business-history tier (T119's `versioned` Version-row diffs, when a
  host has adopted them). Reached from the account drill-down's "Activity →"
  link, mirroring `DeliverabilityLive`/`AutomationHealthLive`'s org_id-keyed,
  no-separate-index shape.

  ## Coverage caveat is RENDERED, not just documented (T115 fix round 3)

  Four `aud_event` families carry no org-linkable field and are excluded from
  `ActivityReads`'s queries (see its moduledoc): `operator_suspension`,
  `break_glass`, `grant_lifecycle`/`erasure`, `record_archived`/
  `record_restored`. That exclusion is disclosed ON THE PAGE ITSELF (the
  `#coverage-caveat` block below the token-blind bar) — an operator reading
  this screen must be able to see the feed is NOT a complete org governance
  change-log without reading source or a status doc.

  ## Read-only (done-criterion 4)

  This LiveView defines no `handle_event/3` clause and renders no
  `phx-click`/`phx-submit`/form affordance anywhere — it is a pure reader. The
  only navigation is plain `<a href>` window-selector links (24h / 7d / 30d),
  which work identically with or without the LiveView client wired (ADR-042
  Class B), consistent with the platform's browser-dead-JS posture (dogfood B1).

  ## Masking (INV-1)

  Governance-tier rows are token-blind BY CONSTRUCTION: no attribute value is
  ever written to `aud_event`'s `event_type`/`subject_id`/`actor_id`/
  `correlation_id` (`Samen.Audit.ImpersonationEmit` writes only object-refs/ids,
  never a subject value). The one free-text field, `detail`, is rendered
  VERBATIM — it is PII-reason-scanned at WRITE time (`Samen.PiiReasonScan`,
  `Samen.AuditChain.Writer.write/2`, fail-closed REJECT on a bare PII-shaped
  string) BEFORE it ever reaches this table, so this page never needs to (and
  never does) touch it further. Business-history-tier rows can carry a
  vault-routed diff value; `ActivityReads.mask_changes/2` renders it as its
  token/class marker via `Samen.Type.VaultField.cast_stored/2` — a STATIC cast
  with no grant argument, so this page is structurally incapable of resolving a
  diff to plaintext. It never calls `Samen.Api.PiiResolution`, never unwraps a
  `%Masked{}` — see the reads module moduledoc.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Operator.Live

  alias Samen.Web.Operator.ActivityReads

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    {:ok, load(socket, Map.get(params, "org_id"), window_hours_param(params))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    org_id = Map.get(params, "org_id") || socket.assigns[:org_id]
    {:noreply, load(socket, org_id, window_hours_param(params))}
  end

  defp window_hours_param(params), do: Map.get(params, "window_hours")

  @doc false
  # `opts` carries the sanctioned `:now` clock-injection seam (mirrors
  # `AccountDetailLive.load/3`) plus a `:feed` override — production
  # mount/handle_params pass neither, so the REAL `ActivityReads.activity/3`
  # read decides. `:feed` exists solely for the masking sabotage-twin test
  # (render a manufactured feed item to prove the DOM-scan below is refutable
  # without standing up a live `versioned` DB fixture — see
  # `activity_masking_test.exs`).
  def load(socket, org_id, window_hours, opts \\ []) do
    mount = socket.assigns[:samen_mount]

    feed =
      case Keyword.fetch(opts, :feed) do
        {:ok, override} ->
          override

        :error ->
          if mount && org_id do
            ActivityReads.activity(mount, org_id, Keyword.put(opts, :window_hours, window_hours))
          end
      end

    assign(socket, org_id: org_id, window_hours_param: window_hours, feed: feed)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="operator-activity">
      <.app_shell>
        <:sidebar>
          <.operator_sidebar mount={@samen_mount} active={:activity} />
        </:sidebar>

        <.topbar title="Activity" crumbs={["Operator plane", "Activity", @org_id || "—"]}>
          <:actions>
            <a href="/operator/accounts" id="back-to-accounts" style="font-size:12px;color:#3B4CCA">← Accounts</a>
          </:actions>
        </.topbar>

        <%= cond do %>
          <% is_nil(@org_id) or is_nil(@feed) -> %>
            <div class="wrap">
              <div class="card" id="no-org" style="padding:22px 20px;color:var(--muted)">
                No tenant org resolved.
              </div>
            </div>
          <% true -> %>
            <div class="wrap">
              <.token_blind_bar chip="object-refs + bounded diffs only · vault-routed values never resolved">
                <b>What changed in this org?</b>
                Governance-tier rows (below, marked "impersonation") are token-blind by
                construction — no attribute value is ever written to them. History-tier
                rows can carry a vault-routed diff value; it renders as its token/class
                marker here, exactly as stored — this page never resolves it to plaintext.
              </.token_blind_bar>

              <%!--
                Coverage caveat (T115 fix round 3 — the honesty defect the whole T115
                chain is about): the feed is NOT a complete org governance change-log.
                Four aud_event families carry no org-linkable field (see
                ActivityReads's moduledoc for the per-family reasoning) and are
                structurally excluded from the queries below. That exclusion must be
                visible HERE, on the screen the operator reads — not only in a code
                comment or a status summary nobody looking at this page will ever see.
              --%>
              <div
                id="coverage-caveat"
                class="card"
                style="margin-top:10px;padding:10px 14px;font-size:12px;line-height:1.5;color:var(--muted);border-color:#E5E7EB"
              >
                <b style="color:inherit">Coverage.</b>
                Includes impersonation writes, system events (webhook, file,
                notification, ticket, workflow, marketing), the approval lifecycle, and
                versioned diffs. <b style="color:inherit">Does not include:</b>
                operator suspension, break-glass reveals, grant lifecycle &amp; erasure,
                or record archival/restore — none of these carry an org-linkable field
                on the audit event log today.
              </div>

              <div id="window-picker" style="margin-top:12px;font-size:12px;color:var(--muted)">
                Window:
                <a
                  :for={{label, hours} <- [{"24h", 24}, {"7d", 168}, {"30d", 720}]}
                  href={"/operator/activity/#{@org_id}?window_hours=#{hours}"}
                  id={"window-#{hours}"}
                  style={"margin-left:8px;#{if @feed.window_hours == hours, do: "font-weight:700;color:#3B4CCA", else: "color:#3B4CCA"}"}
                >
                  {label}
                </a>
              </div>

              <div id="activity-feed" style="margin-top:14px">
                <div class="gtitle">
                  <h3>Activity</h3>
                  <span class="n">{length(@feed.items)}</span>
                  <span class="lane">
                    · impersonation + system + approval events + versioned change-log
                    (partial governance coverage — see note above) · last {@feed.window_hours}h
                  </span>
                </div>

                <.empty_state
                  :if={@feed.items == []}
                  class="activity-empty"
                  icon="🕘"
                  title="No changes in this window."
                  body="No governance events or versioned changes for this org in the selected window — try a wider window above."
                />

                <.data_table :if={@feed.items != []}>
                  <:head>
                    <th style="width:12%">Tier</th>
                    <th style="width:14%">Actor</th>
                    <th style="width:16%">Action</th>
                    <th>Resource / subject</th>
                    <th>Diff / detail</th>
                    <th style="width:16%">When</th>
                  </:head>
                  <tr :for={item <- @feed.items} class={"activity-row #{if item.impersonation?, do: "activity-impersonation"}"} id={item.id}>
                    <td class="a-tier">
                      <.pill variant={tier_variant(item.tier)}>{item.tier}</.pill>
                    </td>
                    <td class="a-actor">
                      <%= if item.impersonation? do %>
                        <div class="acting-as-badge" id={"acting-as-#{item.id}"}>
                          <span class="pill pill-warn">acting as tenant</span>
                        </div>
                        <div class="mono" style="font-size:11px;word-break:break-all">operator {item.actor_id || "—"}</div>
                        <div class="mono" style="font-size:11px;color:var(--muted);word-break:break-all">session {item.session_id || "—"}</div>
                        <div class="mono" style="font-size:11px;color:var(--muted);word-break:break-all">tenant {item.tenant_subject_id || "—"}</div>
                      <% else %>
                        <span class="mono" style="font-size:11px">{short_id(item.actor_id)}</span>
                      <% end %>
                    </td>
                    <td class="a-action">{item.action}</td>
                    <td class="a-object mono" style="font-size:11px;max-width:220px;overflow:auto">
                      {item.object_ref || "—"}
                    </td>
                    <td class="a-diff">
                      <%= if item.changes do %>
                        <div :for={{k, v} <- item.changes} class="mono" style="font-size:11px">
                          <b>{k}</b>: {inspect_change(v)}
                        </div>
                      <% end %>
                      <%!--
                        `detail` is a fixed, token-only, PII-reason-scanned-at-write
                        string (`Samen.PiiReasonScan` gates it BEFORE it ever reaches
                        `aud_event` in production — `Samen.AuditChain.Writer.write/2`).
                        This page renders it VERBATIM — exactly what T38's writer
                        stored, never re-touched, never resolved — the same "exactly
                        what the row stores" posture as every other field on this tier.
                      --%>
                      <div :if={item.detail} class="a-detail mono" style="font-size:11px;color:var(--muted);max-width:320px;overflow:auto">
                        {item.detail}
                      </div>
                      <span :if={!item.changes and !item.detail} style="color:var(--muted)">—</span>
                    </td>
                    <td class="a-when" style="color:var(--muted)">{ts(item.occurred_at)}</td>
                  </tr>
                </.data_table>
              </div>
            </div>
        <% end %>
      </.app_shell>
    </div>
    """
  end

  # -- helpers (bounded enums/ids/masked-values only — never a resolved value) -

  defp short_id(nil), do: "—"
  defp short_id(id), do: "#{String.slice(to_string(id), 0, 8)}…"

  defp tier_variant(:governance), do: "info"
  defp tier_variant(:history), do: "mut"
  defp tier_variant(_), do: "mut"

  # `v` is already the masked/class-marker representation from
  # `ActivityReads.mask_changes/2` (the literal `"••••"` string for a
  # vault-routed key, via `Samen.Type.VaultField.cast_stored/2`, or the stored
  # plain value otherwise) — render verbatim, never re-touch it.
  defp inspect_change(v) when is_binary(v), do: v
  defp inspect_change(nil), do: "—"
  defp inspect_change(v), do: inspect(v)

  defp ts(nil), do: "—"
  defp ts(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  defp ts(other), do: to_string(other)
end
