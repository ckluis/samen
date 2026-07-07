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

  ## Mount contract

  `mount/3` reads `operator_id` and `org_id` from the session/params (a real app sets
  these from the operator's authenticated session + the org they chose to impersonate).
  It builds the impersonation scope PER MOUNT (deny-on-read: an expired session yields
  `{:error, :session_inactive}`, and the view renders a "session expired/inactive"
  state instead of any data).
  """
  use Phoenix.LiveView

  alias Samen.Impersonation

  @impl true
  def mount(params, session, socket) do
    operator_id = fetch(params, session, "operator_id")
    org_id = fetch(params, session, "org_id")

    {:ok, load(socket, operator_id, org_id)}
  end

  # Extracted so tests can drive the exact same load path.
  @doc false
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

      {:error, :session_inactive} ->
        assign(socket,
          impersonating: false,
          session_inactive: true,
          operator_id: operator_id,
          org_id: org_id,
          contacts: [],
          session_info: nil
        )
    end
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

  defp fetch(params, session, key) do
    Map.get(params, key) || Map.get(session, key)
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
