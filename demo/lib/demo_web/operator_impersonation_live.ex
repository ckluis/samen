defmodule DemoWeb.OperatorImpersonationLive do
  @moduledoc """
  The T4.1 minimal LiveView slice: an operator opens an impersonation session over ONE
  tenant org and sees that tenant's REAL data shape (its actual `Demo.Crm.Contact` rows)
  — with `••••` PII, because the impersonation scope carries no reveal grant.

  ## What this proves (T4.1 clause (e))

  > a minimal LiveView slice proving the impersonating operator sees the tenant's real
  > data shape with •••• PII.

  Unlike the T1.9 `ContactLive` (synthetic masked values), this view loads the tenant's
  ACTUAL rows through the impersonation scope (`Samen.Impersonation.scope/2`), which:

    * narrows the read to the TARGET org's rows (the tenant's own org-scope policy
      applies unchanged — the operator sees the real data SHAPE, not a stub);
    * carries NO reveal grant, so every vaulted field is a `%Masked{}` that renders
      `••••` in the HEEx by construction (no CSV/API/log path leaks by omission).

  It also renders the tenant-visible accountability line (who/why/expiry) so the same
  page demonstrates the impersonation is bounded and recorded.

  ## No `mount/3` — this slice is a RENDER PROOF, never a routed surface (H2, phase-6 SEC fix round)

  This module used to carry a `mount/3` that derived the acting operator from
  `Map.get(params, "operator_id") || Map.get(session, "operator_id")` — **params beating the
  session** — which is the exact pattern the phase-6 dogfood flagged as H2 (audit-ledger
  attribution forgery / session riding) in the two vertical consoles. Nothing in demo could
  reach it: demo is API-only (`DemoWeb.Router` is a bare `Plug.Router` forwarding `/api/v1`),
  there is no `Phoenix.Endpoint`, no live socket and no `live/2` route, so `mount/3` was
  structurally unreachable — but leaving an unremediated copy of a fixed security defect
  in-tree is how the next host inherits it (T157 inherited exactly this pattern rather than
  the fixed one). The `mount/3` is therefore GONE rather than fixed: demo depends on
  `samen_core` only, so it cannot reach the framework gate that makes a mount safe
  (`Samen.Web.Operator.Impersonation.assign_identity/3` + `gate_socket/3` + `read_scope/1`),
  and adding `samen_web` to this host's dep graph to support a route that does not exist would
  be disproportionate.

  **Any host that wants a REAL routed impersonation console must use the framework path** —
  see `Samen.Web.Operator.DeliverabilityLive`, `DriftwoodWeb.OperatorImpersonationLive` or
  `PawChartWeb.OperatorImpersonationLive`: the acting operator comes from the AUTHENTICATED
  principal and the access decision goes through `gate/3` (T146 role + ADR-044 §16.4a R-B
  account scope + T150 session), never a client param and never a direct
  `Samen.Impersonation.scope/2` call.

  What remains here is the T4.1 clause (e) proof itself: `load/3` (driven by the test with an
  explicit, caller-supplied operator id — no client-controlled input anywhere) plus `render/1`.
  `load/3` now fails CLOSED on a nil operator/org instead of raising.
  """
  use Phoenix.LiveView

  alias Samen.Impersonation

  # Extracted so tests can drive the exact same load path. `operator_id` is supplied BY THE
  # CALLER (never parsed out of params/session here) — see the moduledoc.
  @doc false
  def load(socket, operator_id, org_id)

  # Fail CLOSED rather than raising a FunctionClauseError out of the kernel on a nil id.
  def load(socket, operator_id, org_id) when not is_binary(operator_id) or not is_binary(org_id),
    do: denied(socket, operator_id, org_id)

  def load(socket, operator_id, org_id) do
    case Impersonation.scope(operator_id, org_id) do
      {:ok, scope} ->
        contacts = read_contacts(scope)

        assign(socket,
          impersonating: true,
          session_inactive: false,
          operator_id: operator_id,
          org_id: org_id,
          contacts: contacts,
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
      contacts: [],
      session_info: nil
    )
  end

  defp read_contacts(scope) do
    require Ash.Query

    Demo.Crm.Contact
    |> Ash.Query.filter(org_id == ^scope.actor.org_id)
    # Vault-routed attributes are sensitive and not selected by default — a real UI
    # asks for them explicitly. They load as `%Masked{}` (••••) since the
    # impersonation scope carries no reveal grant.
    |> Ash.Query.ensure_selected([:full_name, :emails, :dob])
    |> Ash.read!(scope: scope)
  rescue
    _ -> []
  end

  # The tenant-visible accountability entry for THIS operator over THIS org.
  defp session_info(org_id, operator_id) do
    org_id
    |> Impersonation.list_for_org()
    |> Enum.find(fn e -> e.operator_id == operator_id and e.active? end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="operator-impersonation">
      <h1>Operator Console — Impersonation</h1>

      <%= if @session_inactive do %>
        <p id="session-state">No active impersonation session — access denied (session expired or never opened).</p>
      <% else %>
        <div id="accountability">
          <p id="banner">
            Impersonating org {@org_id} as operator {@operator_id}. PII is masked (••••).
          </p>
          <%= if @session_info do %>
            <p id="session-reason">Reason: {@session_info.reason}</p>
            <p id="session-expiry">Expires: {@session_info.expires_at}</p>
          <% end %>
        </div>

        <h2>Tenant contacts (real data shape, PII masked)</h2>
        <table id="contacts">
          <thead>
            <tr>
              <th>Display name</th>
              <th>Full name</th>
              <th>Email(s)</th>
              <th>DOB</th>
            </tr>
          </thead>
          <tbody>
            <%= for c <- @contacts do %>
              <tr class="contact-row" id={"contact-#{c.id}"}>
                <td class="display-name">{c.display_name}</td>
                <td class="full-name">{c.full_name}</td>
                <td class="emails">{c.emails}</td>
                <td class="dob">{c.dob}</td>
              </tr>
            <% end %>
          </tbody>
        </table>
      <% end %>
    </div>
    """
  end
end
