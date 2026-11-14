defmodule PawChartWeb.OperatorImpersonationLive do
  @moduledoc """
  The OPERATOR plane, PAWCHART (vet) shape — T157's second-vertical drill-in. An operator opens
  a masked impersonation session over ONE clinic tenant org and sees its REAL patient roster
  (the pet OWNERS) — with `••••` PII, because the impersonation scope carries no reveal grant.

  This is the vet analogue of `DriftwoodWeb.OperatorImpersonationLive` (freight drivers): the
  vertical 20% legitimately stays host-local because the resource SHAPE is vet-specific
  (`PawChart.Clinic.Patient` — owner name/emails/phones + the pets they own), but every
  operator-plane MECHANISM it uses is inherited framework substrate at ≈0 authored LOC:

    * `Samen.Web.Operator.Impersonation.open/4` — the T150/T153/T154 reason-required,
      accountability-ledgered session open (gated by the `:samen_operator_role` from the
      `Samen.Web.Operator.Authz` on_mount this route carries);
    * `Samen.Impersonation.scope/2` — the per-request deny-on-read tenant scope;
    * `Samen.Api.PiiResolution` — the two-key-classes masking rule: on the operator plane the
      owner's vault-routed name/emails/phones stay `%Masked{}` (••••), NEVER plaintext.

  ## Mount contract (H2/M1 — phase-6 SEC dogfood)

  `mount/3` resolves the acting operator from the **AUTHENTICATED PRINCIPAL** via the framework's
  `Samen.Web.Operator.Impersonation.assign_identity/3`, exactly as the framework drill-ins
  (`Samen.Web.Operator.DeliverabilityLive`/`ActivityLive`/`AutomationHealthLive`) do. It does NOT
  read the acting id from a client-supplied `?operator_id` param.

  Before this the module derived the acting identity from `Map.get(params, key) ||
  Map.get(session, key)` — **params beat session** — and never consulted the `:samen_operator_id`
  the `{Samen.Web.Operator.Authz, :require_operator}` on_mount derives from the signed session.
  An authenticated operator could therefore open a session as `?operator_id=<someone else>` and
  have the tenant's audit ledger — the exact "who accessed this org, when, why" accountability
  promise T150 exists to keep — name the WRONG operator, or ride another operator's active
  session's roster (phase-6 dogfood H2, attribution forgery).

  `load/3` then routes the access DECISION through the framework `gate/3` (via `gate_socket/3`)
  instead of calling `Samen.Impersonation.scope/2` directly, so the T146 role, the §16.4a R-B
  account-scope conjunct and the T150 session conjunct all apply at this door (dogfood M1). An
  expired/absent session — or an out-of-scope account — yields the access-denied state with the
  reason-required open form, no data. Extracted so the dogfood test drives the same load path.
  """
  use Phoenix.LiveView

  # H2/M1 — the framework impersonation GATE. The acting operator is the AUTHENTICATED
  # PRINCIPAL and the access is decided by `gate/3`, NOT by a client-supplied param plus a
  # direct `Samen.Impersonation.scope/2` call.
  alias Samen.Web.Operator.Impersonation, as: OperatorGate
  alias Samen.Web.Reads.Guard

  import Samen.UI, only: [error_state: 1, read_error: 1]

  @impl true
  def mount(params, session, socket) do
    # ADOPT the framework identity path (do not fork it): `assign_mount/2` rebuilds the
    # `%Samen.Web.Mount{}` the gate needs to resolve this product's otp_app for the R-B scope
    # conjunct; `assign_identity/3` resolves the acting operator from the AUTHENTICATED
    # PRINCIPAL (`:samen_operator_id`, else `Samen.Web.Auth.authenticated_user_id/1` off the
    # SIGNED session), falling back to a param ONLY when NO principal resolves at all (the
    # disarmed dev dogfood). A deploy with a real session therefore IGNORES a forged
    # `?operator_id=<other>`.
    socket =
      socket
      |> Samen.Web.Live.assign_mount(session)
      |> OperatorGate.assign_identity(session, params)

    # `org_id` is the TARGET tenant — a bounded, non-PII id chosen in the URL and RE-GATED
    # below on every mount, so it legitimately stays a param.
    org_id = fetch(params, session, "org_id")
    {:ok, load(socket, socket.assigns[:samen_operator_id], org_id)}
  end

  @doc false
  def load(socket, operator_id, org_id)
      when not is_binary(operator_id) or not is_binary(org_id) do
    denied(socket, operator_id, org_id)
  end

  def load(socket, operator_id, org_id) do
    # M1 — the access DECISION goes through the framework `gate/3` (via `gate_socket/3`), which
    # composes the §16.4a R-B account-scope conjunct with the T150 session conjunct. The read
    # `%Samen.Scope{}` is then built from the gate's OWN actor (`read_scope/1`) — one decision
    # point, no direct `Samen.Impersonation.scope/2` call that could admit where the gate denies.
    case OperatorGate.gate_socket(socket, operator_id, org_id) do
      {:ok, actor, info} ->
        # The roster reads through its tagged result: a failed read is an error state with a retry, never an
        # empty patient table under a live "masked impersonation" banner.
        {patients, patients_error} = Guard.pane(patient_roster_result(OperatorGate.read_scope(actor)), [])

        assign(socket,
          impersonating: true,
          session_inactive: false,
          gate_unavailable: false,
          samen_operator_id: operator_id,
          operator_id: operator_id,
          org_id: org_id,
          org_name: org_name(org_id),
          open_error: nil,
          patients: patients,
          patients_error: patients_error,
          session_info: info
        )

      # Both fail-closed shapes render access-denied with NO tenant data:
      #   :denied        — never opened / closed / expired mid-flight / operator suspended
      #   :out_of_scope  — the R-B account-scope conjunct denied (inert until a product wires
      #                    a `:fleet_resolution` seam, so no lockout today)
      denial when denial in [:denied, :out_of_scope] ->
        denied(socket, operator_id, org_id)

      # The gate's lookup raised: an outage, not a denial. No data and NO open-session form (a retry
      # during an outage would open another tenant-visible session).
      :unavailable ->
        socket |> denied(operator_id, org_id) |> assign(gate_unavailable: true)
    end
  end

  defp denied(socket, operator_id, org_id) do
    assign(socket,
      impersonating: false,
      session_inactive: true,
      gate_unavailable: false,
      samen_operator_id: operator_id,
      operator_id: operator_id,
      org_id: org_id,
      org_name: org_name(org_id),
      open_error: nil,
      patients: [],
      patients_error: nil,
      session_info: nil
    )
  end

  # The masked patient roster on the impersonation scope. Mirrors `Driftwood.Reads.driver_roster/1`:
  # an Ash read returns vault-routed fields as %Masked{}; `Samen.Api.PiiResolution` then applies the
  # two-key-classes rule keyed on the scope's actor — on the operator plane it KEEPS the owner's
  # name/emails/phones %Masked{} (••••). A count of pets (non-PII) rides along for support context.
  @doc false
  def patient_roster(scope), do: scope |> patient_roster_result() |> Guard.value([])

  @doc false
  @spec patient_roster_result(term()) :: Guard.result([struct()])
  def patient_roster_result(scope) do
    Guard.run(:pawchart_patient_roster, scope, fn ->
      PawChart.Clinic.Patient
      |> Ash.Query.ensure_selected([:full_name, :emails, :phones, :marketing_opt_in])
      |> Ash.Query.sort(inserted_at: :asc)
      |> Ash.read!(scope: scope)
      |> resolve_pii(scope)
    end)
  end

  defp resolve_pii(records, scope) do
    Samen.Api.PiiResolution.resolve(
      records,
      PawChart.Clinic.Patient,
      actor_of(scope),
      repo: PawChart.Repo
    )
  rescue
    # Fail CLOSED (the records stay masked) and reported by name + exception module, never swallowed.
    e ->
      Guard.report(:pawchart_resolve_pii, scope, e)
      records
  end

  defp actor_of(%Samen.Scope{actor: actor}), do: actor
  defp actor_of(actor) when is_map(actor), do: actor
  defp actor_of(_), do: %{}

  defp org_name(org_id) when is_binary(org_id) do
    # A failed directory read is reported by name (Guard.run) and the header shows the id it was given.
    with {:ok, orgs} <- Guard.run(:pawchart_org_name, nil, fn -> PawChart.Directory.orgs() end),
         {_id, name} when is_binary(name) and name != "" <- List.keyfind(orgs, org_id, 0) do
      name
    else
      _ -> org_id
    end
  end

  defp org_name(org_id), do: org_id

  defp fetch(params, session, key), do: Map.get(params, key) || Map.get(session, key)

  defp fmt_name(%Samen.Masked{} = m), do: m
  defp fmt_name(%{"first" => f, "last" => l}), do: "#{f} #{l}"
  defp fmt_name(%{first: f, last: l}), do: "#{f} #{l}"
  defp fmt_name(other), do: other

  # H2/M1 — the OPEN affordance goes through the framework `open_from_socket/3`, which keys the
  # session on the AUTHENTICATED `:samen_operator_id` (never a param) and RE-CHECKS the R-B scope
  # conjunct before minting a row, so a crafted `phx-submit` cannot book an access under another
  # operator's name or acquire scope by opening a session.
  @impl true
  def handle_event("retry_gate", _params, socket),
    do: {:noreply, load(socket, socket.assigns[:samen_operator_id], socket.assigns[:org_id])}

  def handle_event("open_session", %{"reason" => reason}, socket) do
    org_id = socket.assigns[:org_id]

    case Guard.write(:pawchart_open_session, nil, fn -> OperatorGate.open_from_socket(socket, org_id, reason) end) do
      {:ok, _session} ->
        {:noreply, load(socket, socket.assigns[:samen_operator_id], org_id)}

      {:error, reason} ->
        {:noreply, assign(socket, open_error: open_error_copy(reason))}
    end
  end

  defp open_error_copy(:reason_required), do: "A reason for access is required."
  defp open_error_copy(:not_authorized), do: "Your operator role may not open an impersonation session."
  defp open_error_copy(:out_of_scope), do: "This account is not in your operator scope."
  defp open_error_copy({:pii_shaped_reason, _}), do: "The reason must name the ticket, not the person."
  defp open_error_copy(:unavailable), do: "Couldn't open the session right now. Nothing was opened — try again."
  defp open_error_copy(_), do: "The impersonation session could not be opened."

  @impl true
  def render(assigns) do
    ~H"""
    <div id="operator-impersonation">
      <h1>PawChart Ops · masked impersonation</h1>

      <%= if @session_inactive and @gate_unavailable do %>
        <div id="gate-unavailable">
          <.error_state
            title="We couldn't check access right now."
            body="Nothing was opened and nothing is shown. Nothing was lost — try again."
            retry_event="retry_gate"
          />
        </div>
      <% end %>
      <%= if @session_inactive and not @gate_unavailable do %>
        <div id="session-state">
          <div style="color:#B42318;font-weight:600">
            access denied — no active impersonation session (expired or never opened).
          </div>
          <p>
            Start a masked impersonation session over <b>{@org_name}</b>. The reason is required and
            is written to this clinic's audit log (who / when / why).
          </p>
          <div :if={@open_error} id="open-error" style="color:#B42318">{@open_error}</div>
          <form phx-submit="open_session" id="open-session-form">
            <input type="text" name="reason" id="session-reason-input"
              placeholder="Reason (e.g. ticket #7781: billing dispute)" />
            <button type="submit" id="start-session-btn">Start session (masked)</button>
          </form>
        </div>
      <% end %>
      <%= if not @session_inactive do %>
        <div id="banner">
          <b>Masked impersonation.</b>
          Impersonating clinic <b>{@org_name}</b> as operator {@operator_id}. Owner PII is masked (••••).
          <span :if={@session_info} id="session-reason">Reason: {@session_info.reason}</span>
          <span :if={@session_info} id="session-expiry">Session expires: {@session_info.expires_at}</span>
        </div>

        <.read_error :if={@patients_error} id="patients-error" kind={@patients_error} body={Guard.message(@patients_error)} retry="retry_gate" />
        <table :if={is_nil(@patients_error)}>
          <thead>
            <tr><th>Owner</th><th>Emails</th><th>Phones</th><th>Marketing</th></tr>
          </thead>
          <tbody>
            <tr :for={p <- @patients} class="patient-row" id={"patient-#{p.id}"}>
              <td class="p-name masked">{fmt_name(p.full_name)}</td>
              <td class="p-emails masked">{inspect(p.emails)}</td>
              <td class="p-phones masked">{inspect(p.phones)}</td>
              <td class="p-marketing">{p.marketing_opt_in}</td>
            </tr>
          </tbody>
        </table>
      <% end %>
    </div>
    """
  end
end
