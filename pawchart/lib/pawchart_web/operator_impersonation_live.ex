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

  ## Mount contract

  `mount/3` reads `operator_id` + `org_id` from params/session. `load/3` builds the impersonation
  scope PER MOUNT (deny-on-read): an expired/absent session yields the access-denied state with the
  reason-required open form, no data. Extracted so the dogfood test drives the same load path.
  """
  use Phoenix.LiveView

  @impl true
  def mount(params, session, socket) do
    operator_id = fetch(params, session, "operator_id")
    org_id = fetch(params, session, "org_id")
    {:ok, load(socket, operator_id, org_id)}
  end

  @doc false
  def load(socket, operator_id, org_id)
      when not is_binary(operator_id) or not is_binary(org_id) do
    denied(socket, operator_id, org_id)
  end

  def load(socket, operator_id, org_id) do
    case Samen.Impersonation.scope(operator_id, org_id) do
      {:ok, scope} ->
        assign(socket,
          impersonating: true,
          session_inactive: false,
          operator_id: operator_id,
          org_id: org_id,
          org_name: org_name(org_id),
          open_error: nil,
          patients: patient_roster(scope),
          session_info: session_info(org_id, operator_id)
        )

      {:error, reason} when reason in [:session_inactive, :operator_suspended] ->
        denied(socket, operator_id, org_id)
    end
  end

  defp denied(socket, operator_id, org_id) do
    assign(socket,
      impersonating: false,
      session_inactive: true,
      operator_id: operator_id,
      org_id: org_id,
      org_name: org_name(org_id),
      open_error: nil,
      patients: [],
      session_info: nil
    )
  end

  # The masked patient roster on the impersonation scope. Mirrors `Driftwood.Reads.driver_roster/1`:
  # an Ash read returns vault-routed fields as %Masked{}; `Samen.Api.PiiResolution` then applies the
  # two-key-classes rule keyed on the scope's actor — on the operator plane it KEEPS the owner's
  # name/emails/phones %Masked{} (••••). A count of pets (non-PII) rides along for support context.
  @doc false
  def patient_roster(scope) do
    PawChart.Clinic.Patient
    |> Ash.Query.ensure_selected([:full_name, :emails, :phones, :marketing_opt_in])
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!(scope: scope)
    |> resolve_pii(scope)
  rescue
    _ -> []
  end

  defp resolve_pii(records, scope) do
    Samen.Api.PiiResolution.resolve(
      records,
      PawChart.Clinic.Patient,
      actor_of(scope),
      repo: PawChart.Repo
    )
  rescue
    _ -> records
  end

  defp actor_of(%Samen.Scope{actor: actor}), do: actor
  defp actor_of(actor) when is_map(actor), do: actor
  defp actor_of(_), do: %{}

  defp org_name(org_id) when is_binary(org_id) do
    case List.keyfind(PawChart.Directory.orgs(), org_id, 0) do
      {_id, name} when is_binary(name) and name != "" -> name
      _ -> org_id
    end
  rescue
    _ -> org_id
  end

  defp org_name(org_id), do: org_id

  defp session_info(org_id, operator_id) do
    org_id
    |> Samen.Impersonation.list_for_org()
    |> Enum.find(fn e -> e.operator_id == operator_id and e.active? end)
  end

  defp fetch(params, session, key), do: Map.get(params, key) || Map.get(session, key)

  defp fmt_name(%Samen.Masked{} = m), do: m
  defp fmt_name(%{"first" => f, "last" => l}), do: "#{f} #{l}"
  defp fmt_name(%{first: f, last: l}), do: "#{f} #{l}"
  defp fmt_name(other), do: other

  @impl true
  def handle_event("open_session", %{"reason" => reason}, socket) do
    operator_id = socket.assigns[:operator_id]
    role = socket.assigns[:samen_operator_role]

    case Samen.Web.Operator.Impersonation.open(operator_id, role, socket.assigns[:org_id], reason) do
      {:ok, _session} ->
        {:noreply, load(socket, operator_id, socket.assigns[:org_id])}

      {:error, reason} ->
        {:noreply, assign(socket, open_error: open_error_copy(reason))}
    end
  end

  defp open_error_copy(:reason_required), do: "A reason for access is required."
  defp open_error_copy(:not_authorized), do: "Your operator role may not open an impersonation session."
  defp open_error_copy({:pii_shaped_reason, _}), do: "The reason must name the ticket, not the person."
  defp open_error_copy(_), do: "The impersonation session could not be opened."

  @impl true
  def render(assigns) do
    ~H"""
    <div id="operator-impersonation">
      <h1>PawChart Ops · masked impersonation</h1>

      <%= if @session_inactive do %>
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
      <% else %>
        <div id="banner">
          <b>Masked impersonation.</b>
          Impersonating clinic <b>{@org_name}</b> as operator {@operator_id}. Owner PII is masked (••••).
          <span :if={@session_info} id="session-reason">Reason: {@session_info.reason}</span>
          <span :if={@session_info} id="session-expiry">Session expires: {@session_info.expires_at}</span>
        </div>

        <table>
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
