defmodule Samen.Web.Tenant.AnalyticsLive do
  @moduledoc """
  P17 (ADR-045 §3) — the framework TENANT own-org analytics surface: a floored, org-scoped
  activation view a tenant sees over its OWN org, inherited by any vertical at ≈0 LOC by
  mounting this LiveView under a tenant `live_session` (the `{Samen.Web.TenantAuthz,
  :require_tenant}` on_mount + `Samen.Web.CurrentOrg` org resolution — the same seam the
  flags/billing/crm tenant surfaces mount through).

  It reads ONLY through `Samen.Web.Tenant.AnalyticsReads`, so every property proven there
  holds here: org-scoped from the AUTHENTICATED scope (never `?org=`), the shipped
  k-anonymity floor REUSED (a below-floor stage renders `⊘`, never a raw count), role-gated
  (a masked `:member` gets insight-without-PII; an org-less caller gets the empty state).
  Token-blind by construction — every rendered value is a bounded stage label or a count /
  `⊘`; no vault field, no `Samen.Vault`/`PiiResolution` call, no `%Masked{}` branch.
  """
  use Phoenix.LiveView

  alias Samen.Aggregate.Suppressed
  alias Samen.Web.{CurrentOrg, Mount}
  alias Samen.Web.Tenant.AnalyticsReads

  @impl true
  def mount(params, session, socket) do
    socket = Samen.Web.Live.assign_mount(socket, session)
    org_id = CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)
    {:ok, load(assign(socket, org_id: org_id), org_id)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    org_id = CurrentOrg.reresolve(socket, params)
    {:noreply, load(assign(socket, org_id: org_id), org_id)}
  end

  @doc false
  def load(socket, nil) do
    assign(socket, funnel: [], suppressed_count: 0, org_id: nil)
  end

  def load(socket, org_id) do
    mount = socket.assigns[:samen_mount]
    scope = Mount.scope(mount, org_id)
    funnel = AnalyticsReads.funnel(mount, scope)

    assign(socket,
      funnel: funnel,
      suppressed_count: AnalyticsReads.suppressed_count(funnel),
      org_id: org_id
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="tenant-analytics">
      <h2>Your organization · activation</h2>
      <p class="lane">
        Aggregate over your OWN org only. A stage reached by fewer than the k-anonymity
        floor is suppressed (<span class="mono">⊘</span>) so no single person can be
        re-identified — the framework never un-suppresses, and never exposes an individual.
      </p>

      <p :if={@funnel == []} id="analytics-empty" class="empty">
        No own-org activation data yet, or analytics is not available for your role.
      </p>

      <table :if={@funnel != []} id="funnel-table">
        <thead>
          <tr>
            <th>Stage</th>
            <th>People reached</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @funnel} id={"stage-#{row.stage}"} class="funnel-row">
            <td class="f-stage">{stage_label(row.stage)}</td>
            <td class="f-count">{cell(row.actor_count)}</td>
          </tr>
        </tbody>
      </table>

      <p :if={@suppressed_count > 0} id="supp-note" class="supp">
        {@suppressed_count} stage(s) below the k-anonymity floor — suppressed to prevent re-identification.
      </p>
    </div>
    """
  end

  defp stage_label("signup"), do: "Signed up"
  defp stage_label("first_run"), do: "First run completed"
  defp stage_label("first_record"), do: "First record created"
  defp stage_label(other), do: to_string(other)

  # Token-blind cell: a %Suppressed{} renders ⊘, NEVER the withheld value.
  defp cell(%Suppressed{}), do: "⊘"
  defp cell(n) when is_integer(n), do: Integer.to_string(n)
  defp cell(other), do: to_string(other)
end
