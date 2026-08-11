defmodule Samen.Web.CRM.SequencesLive do
  @moduledoc """
  Framework CRM / **Sequences** page (`/crm/sequences`) — the tenant-plane surface over
  the EXISTING Outreach scope (spec §I2 CRM sequences actually send, T75). It SURFACES
  the already-shipped `Samen.Scopes.Outreach` mechanism (`Sequence`/`Enrollment`/`StepSend`
  + `Samen.Sequences` + the blueprint `:enroll` action); it re-implements no send, enroll,
  or due-scan logic. Thin wiring over `Samen.Web.CRM.SequencesReads`.

  ## What it shows

    * the org's **sequences** (name / status / step count), org-scoped;
    * the org's **enrollments** (which contact, which sequence, which step, and the
      enrollment's honest status), org-scoped;
    * per-enrollment **step-send status** — the honest `StepSend.status` verbatim.

  ## Enroll flow

  A tenant-plane member enrolls a contact into a sequence through the EXISTING blueprint
  `:enroll` action (`Samen.Web.CRM.SequencesReads.enroll/4`); the affordance is offered on
  the tenant plane only (`Samen.Web.CRM.Live.writable?/1` — an operator does not author into
  a tenant's data; the kernel enforces regardless via OrgScope on the write).

  ## Honest send state (the whole point — never a fabricated "delivered")

  The ESP send is a keyless seam here: a step that comes due with no adapter wired is
  recorded `StepSend.status == :blocked` and the enrollment NEVER advances past it
  (`Samen.Sequences.resolve_outcome/3`, Invariant D1). This surface renders that status
  HONESTLY — a `:queued | :blocked | :failed | :suppressed | :skipped` step is NEVER
  labelled "Delivered"/"Sent"; ONLY a genuine `:delivered` (a configured provider truly
  returned `{:ok, _}`) reads as delivered. When no provider is wired for the org
  (`SequencesReads.sends_configured?/1` is false) the page says so up front — the SAME
  fail-honest posture as the Mailbox settings "not configured" state — rather than implying
  a queued step is on its way out the door.

  ## No PII on this surface

  NONE of the three Outreach resources carry a vaulted (🔒) attribute — there is no `pii_`
  column on the scope. `Enrollment.person_id` is an OPAQUE uuid (never identity data), so
  this surface renders it as a short non-secret chip (the SAME posture the CRM dashboard's
  activity leaderboard renders `Task.owner_id`) and NEVER calls
  `Samen.Api.PiiResolution`/`Samen.Vault.reveal/3` — there is no vault field on this path.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.CRM.Live, only: [assign_mount: 2, crm_sidebar: 1, writable?: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.CRM.SequencesReads, as: Reads
  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount

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
    |> ensure_notice()
    |> assign(
      no_org: CurrentOrg.no_org?(socket.assigns[:samen_mount], nil),
      org_id: nil,
      scope_mounted: false,
      sends_configured: false,
      sequences: [],
      enrollments: [],
      step_sends: %{}
    )
  end

  def load(socket, org_id) do
    mount = socket.assigns.samen_mount
    scope = Mount.scope(mount, org_id)

    socket
    |> ensure_return_to()
    |> ensure_notice()
    |> assign(
      no_org: false,
      org_id: org_id,
      scope_mounted: Reads.scope_mounted?(mount),
      # The fail-honest predicate — read from the delivery seam, never assumed.
      sends_configured: Reads.sends_configured?(org_id),
      sequences: Reads.sequences(mount, scope),
      enrollments: Reads.enrollments(mount, scope),
      step_sends: Reads.step_sends_by_enrollment(mount, scope)
    )
  end

  defp ensure_return_to(socket) do
    if Map.has_key?(socket.assigns, :return_to), do: socket, else: assign(socket, return_to: nil)
  end

  defp ensure_notice(socket) do
    if Map.has_key?(socket.assigns, :enroll_notice), do: socket, else: assign(socket, enroll_notice: nil)
  end

  @impl true
  def handle_event("enroll", %{"sequence_id" => sequence_id, "person_id" => person_id}, socket) do
    mount = socket.assigns.samen_mount
    org_id = socket.assigns.org_id
    scope = Mount.scope(mount, org_id)

    socket =
      case Reads.enroll(mount, scope, sequence_id, normalize_person_id(person_id)) do
        {:ok, _enrollment} ->
          socket
          |> assign(enroll_notice: {:ok, "Contact enrolled — the sequence advances on its own schedule."})
          |> load(org_id)

        {:error, _reason} ->
          assign(socket,
            enroll_notice:
              {:error,
               "Enrollment refused — the sequence must belong to this org and the contact id must be a valid uuid."}
          )
      end

    {:noreply, socket}
  end

  # An empty person id → mint one (a tenant enrolling an ad-hoc contact ref). person_id is
  # an OPAQUE uuid with no FK, so any uuid is a legitimate reference (the blueprint posture).
  defp normalize_person_id(id) when is_binary(id) do
    case String.trim(id) do
      "" -> Ash.UUID.generate()
      trimmed -> trimmed
    end
  end

  defp normalize_person_id(_), do: Ash.UUID.generate()

  @impl true
  def render(assigns) do
    ~H"""
    <div id="crm-sequences">
      <.app_shell>
        <:sidebar>
          <.crm_sidebar mount={@samen_mount} org_id={@org_id} active={:crm_sequences} return_to={@return_to} />
        </:sidebar>

        <.topbar title="Sequences" crumbs={[CurrentOrg.name(@samen_mount, @org_id), "CRM", "Sequences"]} />
        <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

        <%= if @no_org do %>
          <.no_org_card mount={@samen_mount} />
        <% else %>
          <span id="org-banner" style="display:none">CRM org: {@org_id}</span>

          <%= if not @scope_mounted do %>
            <div class="wrap">
              <.empty_state
                class="sequences-not-mounted"
                icon="✦"
                title="Sequences are not enabled for this workspace."
                body="This host has not mounted the Outreach scope. Mount Samen.Scopes.Outreach to enroll contacts into multi-step sequences."
              />
            </div>
          <% else %>
            <div class="wrap" style="display:flex;flex-direction:column;gap:18px;padding:16px 20px">
              <%!-- The fail-honest send banner. sends_configured? is read from the delivery
                   seam — never assumed. When no sender is wired, a due step is recorded
                   :blocked (honest), NEVER faked delivered. --%>
              <div
                :if={not @sends_configured}
                id="sequences-sends-not-configured"
                data-state="not_configured"
                class="card"
                style="padding:12px 16px;display:flex;align-items:center;gap:10px"
              >
                <.pill variant="bad"><span id="sequences-send-badge">No sender configured</span></.pill>
                <span style="color:var(--muted);font-size:12px;line-height:1.5">
                  No email provider is wired for this workspace, so a step that comes due is recorded
                  <b>blocked</b> — never delivered. This is honest: enrollments still track state, but nothing sends
                  until a provider is configured. Sends route through the same delivery chokepoint the rest of the
                  platform uses.
                </span>
              </div>
              <div
                :if={@sends_configured}
                id="sequences-sends-configured"
                data-state="configured"
                style="font-size:12px;color:var(--muted)"
              >
                A delivery provider is wired — due steps send through the shared chokepoint. A step that cannot
                send (suppressed / provider error) is still recorded honestly, never faked delivered.
              </div>

              <%!-- Enroll flow — tenant plane only (writable?). Uses the EXISTING :enroll action. --%>
              <div :if={writable?(@samen_mount)} id="sequences-enroll">
                <%= if @sequences == [] do %>
                  <p style="font-size:13px;color:var(--muted)">
                    No sequences exist yet — create a sequence before enrolling contacts.
                  </p>
                <% else %>
                  <form phx-submit="enroll" style="display:flex;gap:8px;align-items:flex-end;flex-wrap:wrap">
                    <label style="display:flex;flex-direction:column;gap:4px;font-size:12px;font-weight:600">
                      Sequence
                      <select name="sequence_id" id="enroll-sequence" required style="min-width:200px">
                        <option :for={s <- @sequences} value={s.id}>{s.name}</option>
                      </select>
                    </label>
                    <label style="display:flex;flex-direction:column;gap:4px;font-size:12px;font-weight:600">
                      Contact id (uuid)
                      <input
                        type="text"
                        name="person_id"
                        id="enroll-person-id"
                        placeholder="contact uuid"
                        aria-label="Contact id"
                        style="min-width:260px"
                      />
                    </label>
                    <.button variant="primary" type="submit">Enroll contact</.button>
                  </form>
                  <div
                    :if={@enroll_notice}
                    id="sequences-enroll-notice"
                    role="status"
                    style="margin-top:8px;font-size:12px;line-height:1.5"
                    class={notice_class(@enroll_notice)}
                  >
                    {notice_text(@enroll_notice)}
                  </div>
                <% end %>
              </div>

              <%!-- Sequences list --%>
              <section id="sequences-list">
                <h3 style="margin:0 0 8px;font-size:13px;font-weight:600">Sequences</h3>
                <%= if @sequences == [] do %>
                  <.empty_state class="sequences-empty" icon="✦" title="No sequences yet." />
                <% else %>
                  <.data_table>
                    <:head>
                      <th style="width:50%">Sequence</th>
                      <th style="width:25%">Status</th>
                      <th style="width:25%">Steps</th>
                    </:head>
                    <tr :for={s <- @sequences} class="sequence-row" id={"sequence-#{s.id}"}>
                      <td style="font-weight:500;color:var(--ink)">{s.name}</td>
                      <td><.pill variant={sequence_status_variant(s.status)}>{s.status}</.pill></td>
                      <td style="font-size:12px;color:var(--muted)">{step_count(s.steps)}</td>
                    </tr>
                  </.data_table>
                <% end %>
              </section>

              <%!-- Enrollments list + per-enrollment step-send status --%>
              <section id="enrollments-list">
                <h3 style="margin:0 0 8px;font-size:13px;font-weight:600">Enrollments</h3>
                <%= if @enrollments == [] do %>
                  <.empty_state class="enrollments-empty" icon="✦" title="No enrollments yet." />
                <% else %>
                  <.data_table>
                    <:head>
                      <th style="width:22%">Contact</th>
                      <th style="width:23%">Sequence</th>
                      <th style="width:15%">Step</th>
                      <th style="width:20%">Enrollment</th>
                      <th style="width:20%">Send status</th>
                    </:head>
                    <tr :for={e <- @enrollments} class="enrollment-row" id={"enrollment-#{e.id}"}>
                      <td class="enrollment-contact" style="font-size:12px;color:var(--muted)">{person_chip(e.person_id)}</td>
                      <td style="font-size:12px;color:var(--muted)">{sequence_name(@sequences, e.sequence_id)}</td>
                      <td style="font-size:12px;color:var(--muted)">{e.current_step}</td>
                      <td>
                        <.pill variant={enrollment_status_variant(e.status)}>{enrollment_status_label(e)}</.pill>
                      </td>
                      <td class="enrollment-send-status">
                        <%= for send <- current_and_past_sends(@step_sends, e) do %>
                          <.pill variant={step_status_variant(send.status)}>
                            <span class="step-send-label">{step_status_label(send.status)}</span>
                          </.pill>
                        <% end %>
                        <span
                          :if={current_and_past_sends(@step_sends, e) == []}
                          class="step-send-label"
                          style="font-size:12px;color:var(--muted)"
                        >
                          {no_send_label(e)}
                        </span>
                      </td>
                    </tr>
                  </.data_table>
                <% end %>
              </section>

              <div id="sequences-honesty-note" style="font-size:11px;color:var(--muted);line-height:1.5">
                Send status is the real per-step outcome — a step is shown "Delivered" only when a configured
                provider genuinely accepted it. A keyless/blocked/failed step is never faked as sent.
              </div>
            </div>
          <% end %>
        <% end %>
      </.app_shell>
    </div>
    """
  end

  # -- pure presentation helpers (tested + sabotage-targeted) ------------------

  defp step_count(steps) when is_list(steps), do: "#{length(steps)} step(s)"
  defp step_count(_), do: "0 step(s)"

  defp sequence_status_variant(:active), do: "ok"
  defp sequence_status_variant(:draft), do: "mut"
  defp sequence_status_variant(:archived), do: "mut"
  defp sequence_status_variant(_), do: "mut"

  # An enrollment's honest lifecycle status. :blocked is a VISIBLE state (a step that
  # could not send because no adapter is wired) — never blurred into a healthy :active.
  @doc false
  def enrollment_status_label(%{status: :paused, paused_reason: reason}) when not is_nil(reason),
    do: "Paused (#{reason})"

  def enrollment_status_label(%{status: :paused}), do: "Paused"
  def enrollment_status_label(%{status: :active}), do: "Active"
  def enrollment_status_label(%{status: :completed}), do: "Completed"
  def enrollment_status_label(%{status: :stopped}), do: "Stopped"
  def enrollment_status_label(%{status: :blocked}), do: "Blocked"
  def enrollment_status_label(%{status: other}), do: to_string(other)

  defp enrollment_status_variant(:active), do: "ok"
  defp enrollment_status_variant(:completed), do: "ok"
  defp enrollment_status_variant(:paused), do: "warn"
  defp enrollment_status_variant(:blocked), do: "bad"
  defp enrollment_status_variant(:stopped), do: "bad"
  defp enrollment_status_variant(_), do: "mut"

  # THE honesty chokepoint. ONLY a genuine :delivered — a configured provider truly
  # returned {:ok, _} (Invariant D1) — reads as "Delivered". Every other outcome renders
  # its honest, non-delivered status. A keyless send is :blocked here, NEVER faked sent.
  # Pinned by the honesty test + sabotage patch 168 (flipping :blocked → "Delivered" flips it).
  @doc false
  def step_status_label(:delivered), do: "Delivered"
  def step_status_label(:queued), do: "Queued"
  def step_status_label(:blocked), do: "Blocked — no sender configured"
  def step_status_label(:suppressed), do: "Suppressed"
  def step_status_label(:failed), do: "Failed"
  def step_status_label(:skipped), do: "Skipped"
  def step_status_label(other), do: to_string(other)

  defp step_status_variant(:delivered), do: "ok"
  defp step_status_variant(:queued), do: "mut"
  defp step_status_variant(:blocked), do: "bad"
  defp step_status_variant(:suppressed), do: "warn"
  defp step_status_variant(:failed), do: "bad"
  defp step_status_variant(:skipped), do: "mut"
  defp step_status_variant(_), do: "mut"

  # The step sends for this enrollment, oldest step first (bounded by the read).
  defp current_and_past_sends(step_sends, enrollment) do
    step_sends
    |> Map.get(enrollment.id, [])
    |> Enum.sort_by(& &1.step_index)
  end

  # No StepSend row yet — an enrollment that has not yet come due. Honest "pending",
  # never "sent".
  defp no_send_label(%{status: :completed}), do: "Completed (no step pending)"
  defp no_send_label(_), do: "Pending — not yet due"

  # person_id is an OPAQUE uuid (no PII). Render a short, stable, non-secret chip — the
  # SAME posture the CRM dashboard leaderboard renders Task.owner_id. NEVER a vault read.
  defp person_chip(person_id) when is_binary(person_id), do: "Contact " <> String.slice(person_id, 0, 8)
  defp person_chip(other), do: to_string(other)

  defp sequence_name(sequences, sequence_id) do
    case Enum.find(sequences, &(&1.id == sequence_id)) do
      nil -> "—"
      seq -> seq.name
    end
  end

  defp notice_class({:ok, _}), do: "enroll-notice-ok"
  defp notice_class({:error, _}), do: "enroll-notice-error"
  defp notice_text({_kind, text}), do: text
end
