defmodule Samen.Web.Operator.AgentHealthLive do
  @moduledoc """
  Framework OPERATOR / Agent oversight at `/operator/agents/:org_id` (ADR-047 §8/A5) —
  the per-definition health aggregates, the bounded run + turn log, and the **durable
  per-{org, definition} kill switch**, inherited by every vertical at 0 LOC via
  `samen_operator_routes/2`. The `Samen.Web.Operator.AutomationHealthLive` mirror, one
  plane over.

  ## The transcript is NOT rendered here — mask-by-OMISSION (ADR-047 §7.3)

  This is the load-bearing property of this surface, and it is enforced BELOW the
  template: `Samen.AI.Agent.Health` projects runs through an explicit token-only field
  list that does not contain `:transcript`, so the operator plane never holds the
  vault-routed value at all — not even as a `%Samen.Masked{}` to style. Everything
  rendered here is ids, enums, counts, durations, bounded error kinds and arg key NAMES
  (ADR-047 §6), so there is no `%Masked{}` branch and no reveal path on this page.

  The tenant's own `Samen.Web.AI.AgentLive` is where a transcript renders, on the tenant
  plane, through `Samen.Api.PiiResolution`. An operator who genuinely needs to read one
  crosses over by impersonation, where the ordinary two-plane rule (and any reveal grant)
  applies — never by a second projection here. Sabotage 261 puts the transcript into this
  projection and the named omission test flips.

  ## The kill switch is a CROSS-ORG operator action, now NARROWED

  A2/A3's rate trip threw the HOST-level switch, so one tenant crossing its own threshold
  stopped agent runs for every tenant. A5 makes the trip a durable row per
  `{org, definition}` (`Samen.AI.Agent.Kill`) and this surface is where a human throws
  and clears it. `Samen.AI.Agent.Health` gates every read/write on the operator role
  (`may_view?/1` / `may_manage?/1`) in application code before `authorize?: false`, the
  `Samen.OperatorPlane` idiom — a tenant-scoped Ash policy cannot express "any org, gated
  by operator role instead".

  Per-tenant drill-in accountability is the SAME floor `AutomationHealthLive` carries:
  the scope conjunct (§16.4a) plus a REAL, reason-required impersonation session (T150 on
  read, T154 on write), re-consulted on the write path rather than trusted from the last
  render.

  ## "Not wired" is not "nothing to show" (A6 — the A5 verifier's R-A5-4)

  This page is inherited at 0 LOC by every host mounting `samen_operator_routes/2`,
  including hosts that never wired the agent-plane repo seams (`pawchart`). Until A6 those
  reads rescued to `[]` and the page rendered the positive claim *"No agent runs for this
  org"* from a surface structurally incapable of reading one — the fail-honest contract
  (ADR-014/024/026) inverted on a display. `Samen.AI.Agent.Health.availability/0` now
  answers the question once and this page renders an explicit **agent plane not wired**
  state instead of an empty success. The same distinction applies one level down: an
  UNREADABLE kill row renders `kill state unreadable`, never `active`, because the breaker
  is meanwhile refusing every run of that definition fail-CLOSED. Sabotages 265/266.

  ADR-042 Class B: every read renders from `mount`/`load` with JS off; kill/re-arm are
  `phx-click` writes.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Operator.Live

  alias Samen.AI.Agent.Health
  alias Samen.OperatorPlane.Actor
  alias Samen.Web.Mount
  alias Samen.Web.Operator
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
    {:noreply, load(socket, Map.get(params, "org_id") || socket.assigns[:target_org_id])}
  end

  @doc false
  def load(socket, target_org_id, opts \\ []) do
    mount = socket.assigns[:samen_mount]
    operator_org_id = mount && Operator.org_id(mount)
    operator = mount && operator_actor(mount)

    base =
      [
        no_org: is_nil(operator_org_id),
        impersonation: :none,
        target_org_id: target_org_id,
        operator: operator,
        agent_plane: Health.availability(),
        summary: [],
        runs: [],
        turns: [],
        selected_run: Keyword.get(opts, :selected_run),
        action_error: Keyword.get(opts, :action_error),
        session_info: nil,
        open_error: nil
      ]

    cond do
      is_nil(operator_org_id) or is_nil(target_org_id) ->
        assign(socket, base)

      true ->
        case Impersonation.gate_socket(socket, socket.assigns[:samen_operator_id], target_org_id) do
          {:ok, _actor, info} ->
            assign(
              socket,
              base
              |> Keyword.merge(
                impersonation: :active,
                summary: fetch(Health.summary(operator, target_org_id)),
                runs: fetch(Health.runs(operator, target_org_id, limit: 50)),
                turns: fetch_turns(operator, target_org_id, Keyword.get(opts, :selected_run)),
                session_info: info
              )
            )

          :out_of_scope ->
            assign(socket, Keyword.put(base, :impersonation, :out_of_scope))

          :denied ->
            assign(socket, Keyword.put(base, :impersonation, :denied))
        end
    end
  end

  @impl true
  def handle_event("open_session", %{"reason" => reason}, socket) do
    target_org_id = socket.assigns[:target_org_id]

    case Impersonation.open_from_socket(socket, target_org_id, reason) do
      {:ok, _session} -> {:noreply, load(socket, target_org_id)}
      {:error, reason} -> {:noreply, assign(socket, open_error: open_error_copy(reason))}
    end
  end

  def handle_event("select_run", %{"id" => run_id}, socket),
    do: {:noreply, load(socket, socket.assigns[:target_org_id], selected_run: run_id)}

  def handle_event("kill", %{"agent" => agent}, socket), do: switch(socket, :kill, agent)
  def handle_event("rearm", %{"agent" => agent}, socket), do: switch(socket, :rearm, agent)

  # The kill/re-arm WRITE re-consults the impersonation + scope gate HERE rather than
  # trusting the last render (the T154 rule): the handler is reachable via a crafted
  # `phx-click` on a denied/out-of-scope state, and scope subtracts on writes as on reads.
  defp switch(socket, action, agent) do
    target_org_id = socket.assigns[:target_org_id]

    case Impersonation.gate_socket(socket, socket.assigns[:samen_operator_id], target_org_id) do
      denied when denied in [:denied, :out_of_scope] ->
        {:noreply, load(socket, target_org_id)}

      {:ok, _actor, _info} ->
        operator = socket.assigns[:operator]

        result =
          if action == :kill,
            do: Health.kill(operator, target_org_id, agent),
            else: Health.rearm(operator, target_org_id, agent)

        case result do
          :ok ->
            {:noreply, load(socket, target_org_id, selected_run: socket.assigns[:selected_run])}

          {:error, reason} ->
            {:noreply, assign(socket, action_error: error_copy(reason))}
        end
    end
  end

  defp fetch({:ok, rows}), do: rows
  defp fetch(_), do: []

  defp fetch_turns(_operator, _org_id, nil), do: []

  defp fetch_turns(operator, org_id, run_id), do: fetch(Health.turns(operator, org_id, run_id))

  defp open_error_copy(:reason_required), do: "A reason for access is required."
  defp open_error_copy(:not_authorized), do: "Your operator role may not open an impersonation session."
  defp open_error_copy({:pii_shaped_reason, _}), do: "The reason must name the ticket, not the person."
  defp open_error_copy(_), do: "The impersonation session could not be opened."

  defp error_copy(:not_authorized), do: "You do not have permission to manage agents for this org."
  defp error_copy(_other), do: "That action could not be completed."

  defp operator_actor(%Mount{} = mount) do
    scope = Operator.scope(mount)
    role = scope.actor[:role]
    id = scope.actor[:id] || "operator"

    op_role =
      case role do
        r when r in [:owner, :admin] -> :operator_admin
        :member -> :operator_support
        _ -> :operator_readonly
      end

    Actor.new(to_string(id), op_role)
  end

  defp operator_actor(_), do: nil

  defp ts(nil), do: "—"
  defp ts(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  defp ts(other), do: to_string(other)

  defp counts_str(map) when map == %{}, do: "—"

  defp counts_str(map) when is_map(map),
    do: map |> Enum.sort_by(fn {k, _v} -> to_string(k) end) |> Enum.map_join(" · ", fn {k, v} -> "#{k}: #{v}" end)

  defp counts_str(_), do: "—"

  @impl true
  def render(assigns) do
    ~H"""
    <div id="operator-agent-health">
      <.app_shell>
        <:sidebar>
          <.operator_sidebar mount={@samen_mount} active={:agents} />
        </:sidebar>

        <.topbar title="Agent health" crumbs={["Operator plane", "Agents"]}>
          <:actions>
            <a :if={@target_org_id} href="/operator/accounts" id="back-to-accounts-from-agents" style="font-size:12px;color:#3B4CCA">
              ← Accounts
            </a>
          </:actions>
        </.topbar>

        <div class="wrap">
          <%= cond do %>
            <% @no_org -> %>
              <div class="card" id="no-org" style="padding:22px 20px;color:var(--muted)">No operator org resolved.</div>
            <% is_nil(@target_org_id) -> %>
              <div class="card" id="no-target-org" style="padding:22px 20px;color:var(--muted)">
                Open an account (Operator plane → Accounts) and follow "Agent health →" to inspect a
                tenant's agent runs.
              </div>
            <% @impersonation == :out_of_scope -> %>
              <div class="card" id="out-of-scope" style="padding:22px 20px">
                <div style="color:var(--red);font-weight:600" id="not-in-scope">This account is not in your scope.</div>
                <p style="color:var(--muted);margin:10px 0 0;font-size:13px">
                  Your operator assignment does not cover this tenant, so its agent health is not
                  available to you and no impersonation session can be opened for it.
                </p>
              </div>
            <% @impersonation == :denied -> %>
              <div class="card" id="impersonation-required" style="padding:22px 20px">
                <div style="color:var(--red);font-weight:600" id="no-session">
                  Access denied — no active impersonation session for this tenant.
                </div>
                <p style="color:var(--muted);margin:10px 0 14px;font-size:13px">
                  Inspecting (and stopping) one tenant's agents is a per-tenant drill-in: it requires a
                  short-TTL, reason-required impersonation session, recorded in the tenant's audit ledger.
                </p>
                <div :if={@open_error} id="open-error" style="color:#B42318;font-size:12px;margin-bottom:8px">{@open_error}</div>
                <form phx-submit="open_session" id="open-session-form" style="display:flex;gap:8px;align-items:flex-start">
                  <input type="text" name="reason" id="session-reason-input"
                    placeholder="Reason (e.g. ticket #1234: runaway agent)"
                    style="flex:1;padding:8px 10px;border:1px solid #D0D5DD;border-radius:8px;font-size:13px" />
                  <button type="submit" id="start-session-btn" style="padding:8px 14px;border-radius:8px;background:#3B4CCA;color:#fff;font-size:13px">
                    Start session
                  </button>
                </form>
              </div>
            <% @agent_plane == :unavailable -> %>
              <div class="card" id="agent-plane-unavailable" data-agent-plane="unavailable" style="padding:22px 20px">
                <div style="color:var(--red);font-weight:600" id="agent-plane-not-wired">
                  Agent plane not wired on this host — no agent data can be read.
                </div>
                <p style="color:var(--muted);margin:10px 0 0;font-size:13px">
                  This page is inherited by every host that mounts the operator workspace, but this
                  one has not configured the agent-plane repo seams
                  (<span class="mono">:samen_ai_agent_run_repo</span> /
                  <span class="mono">:samen_ai_agent_turn_repo</span> /
                  <span class="mono">:samen_ai_agent_kill_repo</span>), so agent runs, turns and kill
                  state are <b>unreadable here</b> — not absent. This is deliberately <b>not</b> an
                  empty state: a surface that cannot read must never claim it read nothing
                  (ADR-014/024/026 fail-honest; ADR-047 §6).
                </p>
              </div>
            <% true -> %>
              <div :if={@session_info} id="session-accountability" class="card" style="padding:10px 14px;margin-bottom:12px;font-size:12px;color:var(--muted)">
                <b style="color:inherit">Impersonation session.</b>
                operator <span class="mono">{@session_info.operator_id}</span>
                · reason: <span id="session-reason">{@session_info.reason}</span>
                · expires <span id="session-expiry">{@session_info.expires_at}</span>
              </div>

              <.token_blind_bar chip="run + turn log are bounded ids/enums only · no transcript, no vault token">
                <b>Token-blind observability — and no transcript.</b>
                The operator plane sees ids, enums, counts, durations, bounded error kinds and tool-arg
                key NAMES. A run's transcript is vault-routed tenant data and is <b>not projected to this
                plane at all</b> (ADR-047 §7.3, mask-by-omission) — never rendered here, masked or otherwise.
              </.token_blind_bar>

              <div :if={@action_error} id="action-error" class="card" style="padding:12px 16px;margin-top:12px;color:#B42318;border-color:#F4B4AC">
                {@action_error}
              </div>

              <div id="agent-definition-health" style="margin-top:14px">
                <div class="gtitle">
                  <h3>Agent definitions</h3>
                  <span class="n">{length(@summary)}</span>
                </div>

                <.empty_state
                  :if={@summary == []}
                  class="agent-empty"
                  icon="◎"
                  title="No agent runs for this org."
                  body="Nothing to observe yet — a run will show up here as soon as one starts."
                />

                <.data_table :if={@summary != []}>
                  <:head>
                    <th>Agent</th>
                    <th>Kill switch</th>
                    <th>Runs</th>
                    <th>By state</th>
                    <th>Error kinds</th>
                    <th>Awaiting approval</th>
                    <th>Tool calls</th>
                    <th>Tokens</th>
                    <th>Last run</th>
                    <th></th>
                  </:head>
                  <tr :for={a <- @summary} class="agent-row" id={"agent-#{a.agent}"}>
                    <td class="a-name">{a.agent}</td>
                    <td class="a-killed" data-kill-state={a.kill_state}>
                      <span :if={a.kill_state == :killed} class="pill pill-killed" id={"killed-badge-#{a.agent}"}>killed ({a.kill_reason})</span>
                      <span :if={a.kill_state == :active}>active</span>
                      <span :if={a.kill_state == :unknown} class="pill pill-killed" id={"kill-unknown-#{a.agent}"}>
                        kill state unreadable — runs are being refused fail-closed
                      </span>
                    </td>
                    <td class="a-total">{a.total_runs}</td>
                    <td class="a-by-state">{counts_str(a.run_counts)}</td>
                    <td class="a-by-error">{counts_str(a.error_kind_counts)}</td>
                    <td class="a-awaiting">{a.awaiting_approval}</td>
                    <td class="a-tools">{a.tool_calls}</td>
                    <td class="a-tokens">{a.tokens}</td>
                    <td class="a-last" style="color:var(--muted)">{ts(a.last_run_at)}</td>
                    <td class="a-actions">
                      <button :if={a.kill_state == :active} class="btn-kill" id={"kill-#{a.agent}"} phx-click="kill" phx-value-agent={a.agent}
                        data-confirm="Stop this agent for this tenant? Running runs stop at their next turn boundary.">
                        Kill
                      </button>
                      <button :if={a.kill_state == :killed} class="btn-rearm" id={"rearm-#{a.agent}"} phx-click="rearm" phx-value-agent={a.agent}>
                        Re-arm
                      </button>
                    </td>
                  </tr>
                </.data_table>
              </div>

              <div id="agent-run-log" style="margin-top:22px">
                <div class="gtitle">
                  <h3>Recent runs</h3>
                  <span class="n">{length(@runs)}</span>
                </div>

                <.empty_state :if={@runs == []} class="agent-run-empty" icon="✓" title="No runs recorded."
                  body="Queued, running, parked, and terminal runs appear here as agents dispatch." />

                <.data_table :if={@runs != []}>
                  <:head>
                    <th>State</th>
                    <th>Agent</th>
                    <th>Run id</th>
                    <th>Turn</th>
                    <th>Error</th>
                    <th>Tool calls</th>
                    <th>Tokens</th>
                    <th>Started</th>
                    <th></th>
                  </:head>
                  <tr :for={r <- @runs} class="agent-run-row" id={"run-#{r.id}"}>
                    <td class="r-state"><span class={"pill pill-#{r.state}"}>{r.state}</span></td>
                    <td class="r-agent">{r.agent}</td>
                    <td class="r-id mono" style="max-width:220px;overflow:auto">{r.id}</td>
                    <td class="r-turn">{r.current_turn}/{r.max_turns}</td>
                    <td class="r-error" style="color:#B42318">{r.error_kind}</td>
                    <td class="r-tools">{r.tool_calls_used}</td>
                    <td class="r-tokens">{r.input_tokens_used}/{r.output_tokens_used}</td>
                    <td class="r-started" style="color:var(--muted)">{ts(r.started_at)}</td>
                    <td><button class="btn-turns" id={"turns-#{r.id}"} phx-click="select_run" phx-value-id={r.id}>Turns</button></td>
                  </tr>
                </.data_table>
              </div>

              <div :if={@selected_run} id="agent-turn-log" style="margin-top:22px">
                <div class="gtitle">
                  <h3>Turn log</h3>
                  <span class="n">{length(@turns)}</span>
                </div>

                <.data_table :if={@turns != []}>
                  <:head>
                    <th>#</th>
                    <th>Status</th>
                    <th>Tool</th>
                    <th>Arg keys</th>
                    <th>Error</th>
                    <th>Tokens</th>
                    <th>Duration (ms)</th>
                    <th>Provider</th>
                  </:head>
                  <tr :for={t <- @turns} class="turn-row" id={"turn-#{t.id}"}>
                    <td>{t.turn_index}</td>
                    <td class="t-status">{t.status}</td>
                    <td class="t-tool">{t.tool_kind || "—"}</td>
                    <td class="t-argkeys mono">{Enum.join(t.arg_keys, ", ")}</td>
                    <td class="t-error" style="color:#B42318">{t.error_kind}</td>
                    <td>{t.input_tokens}/{t.output_tokens}</td>
                    <td>{t.duration_ms}</td>
                    <td>
                      {t.provider || "—"}
                      <span :if={t.simulated} class="pill pill-sim">SIMULATED</span>
                    </td>
                  </tr>
                </.data_table>

                <.empty_state :if={@turns == []} class="turn-empty" icon="·" title="No turns for that run." body="" />
              </div>
          <% end %>
        </div>
      </.app_shell>
    </div>
    """
  end
end
