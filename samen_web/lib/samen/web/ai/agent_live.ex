defmodule Samen.Web.AI.AgentLive do
  @moduledoc """
  Surface 6/6 of the tenant-plane AI UI kit — the AGENT RUN surface (ADR-047 §8/A5):
  the run list, the per-run detail (progress, bounded turn log, transcript), the CANCEL
  affordance, and the APPROVE/REJECT decision card for a run parked
  `:awaiting_approval`.

  ## The decision card drives the REAL approvals machinery

  Before A5 an agent write proposal could only be decided through the
  `Samen.Approvals.approve/3` API. This surface renders the card; it does **not** add a
  decision path. `Samen.Web.AI.AgentReads.decide/3` is a thin pass-through to the engine,
  so every guarantee A4 shipped still binds, unchanged and unweakened:

    * requester ≠ approver, at BOTH the policy layer and the `<abbrev>_distinct_party`
      DB CHECK — the AI service principal that requested it can never decide it;
    * the args-digest binding: the approval of proposal X executes exactly X;
    * `verify_approval/4`'s DB-state guard: only a genuinely `:approved` row executes;
    * (A5) the approver is resolved to a REAL member of the run's org with their REAL
      role — a non-member's click refuses and NOTHING executes.

  The acting principal is taken from the TRUSTED mount scope, never from a form field,
  and the approval id is validated against THIS run's own `:proposed` turn row before
  the card renders it — so a crafted `phx-value-approval` for another run's proposal
  cannot be decided here.

  ## What the card shows: token-only provenance

  `Samen.AI.Agent.WriteProposal.provenance/1` — run id, turn index, tool kind, arg key
  NAMES, and the sha256 args digest. It is structurally incapable of carrying an arg
  VALUE (ADR-040 §4.4 / INV-1: the approval row stores no inputs). The values a reviewer
  would want live only inside the run's vault-routed transcript, which is exactly what
  the transcript panel below renders — on the actor's plane.

  ## Masking (the MaskingCase three-proofs, ADR-047 §7.3)

  The transcript is the run's ONE vault-routed field. It is resolved by
  `Samen.Api.PiiResolution` in `AgentReads.get/3` — this module NEVER hand-masks and
  never branches on plane (ADR-042). Tenant plane renders clear; operator-without-grant
  renders `••••` with no `vt_*` token in the DOM. Three proofs ship in
  `samen_web/test/samen/web/agent_masking_test.exs`; sabotage 261 makes them refutable.

  ## Honesty (ADR-014 / ADR-047 §6)

  A terminal run renders its state VERBATIM from the row: `:budget_exhausted` says the
  run stopped at a budget and that this is **not a partial answer** — the last assistant
  line is never promoted to an answer here either. `:expired` says the proposal's
  deadline lapsed and nothing executed. The SIMULATED badge is driven by the turn row's
  persisted `simulated` flag (stamped from `%Completion{}.simulated` at the chokepoint),
  never parsed from text.

  ADR-042 Class B: the list, the detail, the turn log and the transcript all render from
  `mount`/`load` with no socket; cancel/approve/reject are `phx-click` writes.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Live, only: [assign_mount: 2]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, name: 2]
  import Samen.Web.AI.Components

  alias Samen.Web.AI.AgentReads
  alias Samen.Web.Mount

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    mount = socket.assigns[:samen_mount]
    org_id = Samen.Web.CurrentOrg.resolve(mount, params, session)
    {:ok, load(socket, org_id, run_id: params["id"])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, load(socket, socket.assigns[:org_id], run_id: params["id"])}
  end

  @doc "The framework page-load seam (also the test entry point — no socket required)."
  def load(socket, org_id, opts \\ []) do
    mount = socket.assigns[:samen_mount]
    run_id = Keyword.get(opts, :run_id)

    detail =
      case run_id && org_id && AgentReads.get(mount, org_id, run_id) do
        {:ok, detail} -> detail
        _ -> nil
      end

    socket
    |> Phoenix.Component.assign(:org_id, org_id)
    |> Phoenix.Component.assign(:runs, if(org_id, do: AgentReads.list(mount, org_id), else: []))
    |> Phoenix.Component.assign(:run_id, run_id)
    |> Phoenix.Component.assign(:detail, detail)
    |> Phoenix.Component.assign(:outcome, Keyword.get(opts, :outcome, nil))
  end

  @impl true
  def handle_event("cancel", %{"id" => run_id}, socket) do
    outcome =
      case AgentReads.cancel(socket.assigns[:samen_mount], socket.assigns[:org_id], run_id) do
        {:ok, _run} -> {:ok, "Stopping after the current step."}
        {:error, :already_terminal} -> {:info, "That run has already finished."}
        {:error, _} -> {:error, "That run could not be cancelled."}
      end

    {:noreply, load(socket, socket.assigns[:org_id], run_id: socket.assigns[:run_id], outcome: outcome)}
  end

  def handle_event("approve", %{"id" => approval_id}, socket), do: decide(socket, :approve, approval_id)
  def handle_event("reject", %{"id" => approval_id}, socket), do: decide(socket, :reject, approval_id)

  # The WRITE gate, re-consulted on every decision click and never trusted from the last
  # render: the approval id must be THE pending approval of THE run this page is showing,
  # re-read from the server. A crafted phx-value for another run's (or another org's)
  # proposal finds no match and is refused without ever reaching the engine.
  defp decide(socket, action, approval_id) do
    mount = socket.assigns[:samen_mount]
    org_id = socket.assigns[:org_id]
    run_id = socket.assigns[:run_id]

    outcome =
      with {:ok, detail} <- fetch_detail(mount, org_id, run_id),
           %{id: ^approval_id} <- detail.approval,
           actor_id when is_binary(actor_id) <- actor_id(mount, org_id) do
        classify(action, AgentReads.decide(action, approval_id, actor_id))
      else
        _ -> {:error, "That proposal is no longer pending for this run."}
      end

    {:noreply, load(socket, org_id, run_id: run_id, outcome: outcome)}
  end

  defp fetch_detail(_mount, nil, _run_id), do: :error
  defp fetch_detail(_mount, _org_id, nil), do: :error
  defp fetch_detail(mount, org_id, run_id), do: AgentReads.get(mount, org_id, run_id)

  defp actor_id(mount, org_id) do
    case Mount.scope(mount, org_id) do
      %Samen.Scope{actor: %{id: id}} when is_binary(id) -> id
      _ -> nil
    end
  end

  # Every refusal is reported HONESTLY and specifically — an approver who was refused
  # must never see "approved" (ADR-014), and must be told which rule refused them.
  defp classify(:approve, {:ok, _}), do: {:ok, "Approved — the write executed as you, inside the decision."}
  defp classify(:reject, {:ok, _}), do: {:ok, "Rejected — the run stopped and nothing was executed."}
  defp classify(_action, {:error, :self_approval}), do: {:error, "The requester of a proposal can never approve it."}
  defp classify(_action, {:error, :not_authorized}), do: {:error, "You are not a member of this org, so you cannot decide this proposal."}
  defp classify(_action, {:error, :approver_unresolvable}), do: {:error, "Approvals are not wired on this host — nothing was executed."}
  defp classify(_action, {:error, :not_pending}), do: {:error, "That proposal has already been decided."}
  defp classify(_action, {:error, {:tool_failed, kind}}), do: {:error, "The approved write failed (#{kind}) — the decision was rolled back and the proposal is still pending."}
  defp classify(_action, {:error, :proposal_mismatch}), do: {:error, "The proposal no longer matches what was approved — nothing was executed."}
  defp classify(_action, {:error, _}), do: {:error, "That decision could not be completed — nothing was executed."}

  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <.app_shell>
      <:sidebar>
        <.sidebar title={name(@samen_mount, @org_id)} subtitle="AI" logo={Mount.label(@samen_mount, :glyph, "AI")}>
          <.ai_sidebar_nav active={:agents} base={ai_base(@samen_mount)} />
        </.sidebar>
      </:sidebar>

      <.topbar title="AI · Agent runs" crumbs={["AI", "Agent runs"]} />
      <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />
      <.ai_tabs active={:agents} base={ai_base(@samen_mount)} />

      <%= if is_nil(@org_id) do %>
        <.no_org_card mount={@samen_mount} />
      <% else %>
        <div class="pane" id="ai-agents" style="display:flex;flex-direction:column;gap:16px;padding:16px">
          <.outcome_card :if={@outcome} outcome={@outcome} />

          <%= if @detail do %>
            <.run_detail detail={@detail} base={ai_base(@samen_mount)} />
          <% else %>
            <.run_list runs={@runs} base={ai_base(@samen_mount)} />
          <% end %>
        </div>
      <% end %>
    </.app_shell>
    """
  end

  attr :outcome, :any, required: true

  defp outcome_card(assigns) do
    {kind, msg} = assigns.outcome
    assigns = assigns |> assign(:kind, kind) |> assign(:msg, msg)

    ~H"""
    <div class="card" id="agent-outcome" data-state={@kind} style="padding:12px">
      <.pill variant={outcome_variant(@kind)}>{outcome_label(@kind)}</.pill>
      <span id="agent-outcome-msg" style="margin-left:8px;color:var(--muted);font-size:13px">{@msg}</span>
    </div>
    """
  end

  defp outcome_variant(:ok), do: "ok"
  defp outcome_variant(:error), do: "bad"
  defp outcome_variant(_), do: "info"

  defp outcome_label(:ok), do: "Done"
  defp outcome_label(:error), do: "Refused"
  defp outcome_label(_), do: "Noted"

  attr :runs, :list, required: true
  attr :base, :string, required: true

  defp run_list(assigns) do
    ~H"""
    <div class="card" id="agent-run-list" style="padding:16px">
      <h3 style="margin:0 0 8px;font-size:14px">Agent runs</h3>

      <%= if @runs == [] do %>
        <.empty_state
          title="No agent runs yet"
          body="An agent run appears here as soon as one starts. Runs are multi-step, budgeted, and every write is proposed for a human to approve — never executed by the agent."
          icon="◎"
        />
      <% else %>
        <ul style="list-style:none;margin:0;padding:0">
          <li :for={r <- @runs} class="agent-run-row" id={"agent-run-#{r.id}"} style="padding:8px 0;border-bottom:1px solid var(--line,#222)">
            <.pill variant={state_variant(r.state)}><span class="agent-run-state">{r.state}</span></.pill>
            <span class="agent-run-name" style="margin-left:8px">{r.agent}</span>
            <span style="margin-left:8px;color:var(--muted);font-size:12px">
              turn {r.current_turn}/{r.max_turns} · tools {r.tool_calls_used}/{r.max_tool_calls}
            </span>
            <a href={"#{@base}/agents/#{r.id}"} id={"agent-open-#{r.id}"} style="margin-left:8px;font-size:12px">Open →</a>
          </li>
        </ul>
      <% end %>
    </div>
    """
  end

  attr :detail, :map, required: true
  attr :base, :string, required: true

  defp run_detail(assigns) do
    assigns = assign(assigns, :run, assigns.detail.run)

    ~H"""
    <div class="card" id="agent-run-detail" data-state={@run.state} style="padding:16px">
      <div style="display:flex;align-items:center;gap:8px">
        <.pill variant={state_variant(@run.state)}><span id="agent-detail-state">{@run.state}</span></.pill>
        <b>{@run.agent}</b>
        <span style="color:var(--muted);font-size:12px">
          turn {@run.current_turn}/{@run.max_turns} · tool calls {@run.tool_calls_used}/{@run.max_tool_calls}
          · tokens {@run.input_tokens_used}/{@run.output_tokens_used}
        </span>
        <a href={"#{@base}/agents"} id="agent-back" style="margin-left:auto;font-size:12px">← All runs</a>
      </div>

      <.honesty_note run={@run} />

      <div :if={@run.state in [:queued, :running]} style="margin-top:10px">
        <.button variant="secondary" phx-click="cancel" phx-value-id={@run.id} id="agent-cancel">
          Stop after the current step
        </.button>
        <span style="margin-left:8px;color:var(--muted);font-size:12px">
          Cancellation is honoured at the next turn boundary — an in-flight step finishes.
        </span>
      </div>

      <.decision_card :if={@detail.approval} approval={@detail.approval} provenance={@detail.provenance} />

      <div id="agent-transcript" style="margin-top:16px">
        <h4 style="margin:0 0 6px;font-size:13px">Transcript</h4>
        <p style="margin:0 0 8px;color:var(--muted);font-size:12px">
          Vault-routed. An agent run is masked-only toward the model on every plane
          (ADR-047 §4.4) — this panel resolves on YOUR plane.
        </p>
        <pre id="agent-transcript-goal" style="white-space:pre-wrap;margin:0 0 8px">{@detail.goal}</pre>
        <ol style="margin:0;padding-left:18px">
          <li :for={line <- @detail.lines} class="agent-transcript-line" style="font-size:13px">{line}</li>
        </ol>
      </div>

      <div id="agent-turn-log" style="margin-top:16px">
        <h4 style="margin:0 0 6px;font-size:13px">Turns</h4>
        <.data_table :if={@detail.turns != []}>
          <:head>
            <th>#</th>
            <th>Status</th>
            <th>Tool</th>
            <th>Arg keys</th>
            <th>Error</th>
            <th>Tokens</th>
            <th>Provider</th>
          </:head>
          <tr :for={t <- @detail.turns} class="agent-turn-row" id={"agent-turn-#{t.id}"}>
            <td>{t.turn_index}</td>
            <td class="t-status">{t.status}</td>
            <td class="t-tool">{t.tool_kind || "—"}</td>
            <td class="t-argkeys mono">{Enum.join(t.arg_keys, ", ")}</td>
            <td class="t-error" style="color:#B42318">{t.error_kind || ""}</td>
            <td>{t.input_tokens}/{t.output_tokens}</td>
            <td>
              {t.provider || "—"}
              <.pill :if={t.simulated} variant="warn"><span class="agent-sim-badge">SIMULATED — not a real model</span></.pill>
            </td>
          </tr>
        </.data_table>
        <.empty_state :if={@detail.turns == []} title="No turns yet" body="The first turn will appear once the run starts." icon="·" />
      </div>
    </div>
    """
  end

  attr :run, :map, required: true

  # The honest terminal copy, driven by the persisted state — never a promoted last turn.
  defp honesty_note(%{run: %{state: :budget_exhausted}} = assigns) do
    ~H"""
    <div class="card" id="agent-honesty" data-state="budget_exhausted" style="padding:10px;margin-top:10px">
      <.pill variant="warn">Stopped at a budget</.pill>
      <span style="margin-left:8px;font-size:13px">
        Stopped at the turn/token budget — <b>this is not a partial answer</b>. Nothing below is being
        offered as a result ({@run.error_kind}).
      </span>
    </div>
    """
  end

  defp honesty_note(%{run: %{state: :expired}} = assigns) do
    ~H"""
    <div class="card" id="agent-honesty" data-state="expired" style="padding:10px;margin-top:10px">
      <.pill variant="warn">Proposal expired</.pill>
      <span style="margin-left:8px;font-size:13px">
        The write proposal's deadline passed with no decision. The pending approval was withdrawn and
        <b>nothing was executed</b>.
      </span>
    </div>
    """
  end

  defp honesty_note(%{run: %{state: :rejected}} = assigns) do
    ~H"""
    <div class="card" id="agent-honesty" data-state="rejected" style="padding:10px;margin-top:10px">
      <.pill variant="warn">Proposal rejected</.pill>
      <span style="margin-left:8px;font-size:13px">A reviewer refused the proposed write. Nothing was executed.</span>
    </div>
    """
  end

  defp honesty_note(%{run: %{state: :failed}} = assigns) do
    ~H"""
    <div class="card" id="agent-honesty" data-state="failed" style="padding:10px;margin-top:10px">
      <.pill variant="bad">Failed</.pill>
      <span style="margin-left:8px;font-size:13px">
        The run stopped: <span id="agent-error-kind">{@run.error_kind}</span>. No answer is shown (payload-free, EG6).
      </span>
    </div>
    """
  end

  defp honesty_note(%{run: %{state: :cancelled}} = assigns) do
    ~H"""
    <div class="card" id="agent-honesty" data-state="cancelled" style="padding:10px;margin-top:10px">
      <.pill variant="mut">Cancelled</.pill>
      <span style="margin-left:8px;font-size:13px">Stopped at a turn boundary. The in-flight step was allowed to finish.</span>
    </div>
    """
  end

  defp honesty_note(assigns) do
    ~H"""
    <div id="agent-honesty" data-state={@run.state}></div>
    """
  end

  attr :approval, :any, required: true
  attr :provenance, :any, default: nil

  defp decision_card(assigns) do
    ~H"""
    <div class="card" id="agent-decision-card" data-approval={@approval.id} style="padding:14px;margin-top:14px;border-color:#F0B429">
      <div style="display:flex;align-items:center;gap:8px">
        <.pill variant="warn"><span id="agent-decision-badge">Awaiting your decision</span></.pill>
        <span style="color:var(--muted);font-size:12px">
          The agent PROPOSED this write. It has not run, and it cannot run without a decision from a
          person who is not the requester (ADR-043 §6.2).
        </span>
      </div>

      <dl :if={@provenance} id="agent-decision-provenance" style="margin:10px 0 0;font-size:13px">
        <div><dt style="display:inline;color:var(--muted)">tool:</dt> <dd style="display:inline;margin:0" id="prov-tool">{@provenance.tool_kind}</dd></div>
        <div><dt style="display:inline;color:var(--muted)">turn:</dt> <dd style="display:inline;margin:0" id="prov-turn">{@provenance.turn_index}</dd></div>
        <div><dt style="display:inline;color:var(--muted)">arg keys:</dt> <dd style="display:inline;margin:0" id="prov-argkeys" class="mono">{Enum.join(@provenance.arg_keys, ", ")}</dd></div>
        <div><dt style="display:inline;color:var(--muted)">args digest:</dt> <dd style="display:inline;margin:0" id="prov-digest" class="mono">{@provenance.args_digest}</dd></div>
      </dl>

      <p style="margin:8px 0 0;color:var(--muted);font-size:12px">
        Only key NAMES and a digest are recorded on the approval — never argument values (INV-1).
        Approving executes the write <b>as you</b>, once, inside the decision; the digest binds it to
        exactly this proposal. Deadline: <span id="agent-decision-deadline">{@approval.deadline_at}</span>.
      </p>

      <div style="margin-top:10px;display:flex;gap:8px">
        <.button variant="primary" phx-click="approve" phx-value-id={@approval.id} id="agent-approve"
          data-confirm="Approve this write? It will execute once, as you.">
          Approve + execute
        </.button>
        <.button variant="secondary" phx-click="reject" phx-value-id={@approval.id} id="agent-reject">
          Reject
        </.button>
      </div>
    </div>
    """
  end

  defp state_variant(:succeeded), do: "ok"
  defp state_variant(:running), do: "info"
  defp state_variant(:queued), do: "info"
  defp state_variant(:awaiting_approval), do: "warn"
  defp state_variant(:budget_exhausted), do: "warn"
  defp state_variant(:expired), do: "warn"
  defp state_variant(:rejected), do: "warn"
  defp state_variant(:failed), do: "bad"
  defp state_variant(_), do: "mut"
end
