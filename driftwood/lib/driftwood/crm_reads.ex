defmodule Driftwood.CrmReads do
  @moduledoc """
  The CRM read layer for the inherited CRM pages (companies, contacts, pipeline).

  All reads go through Ash so OrgScope + vault masking apply. PII fields on
  `Driftwood.Crm.Person` (full_name / emails / phones) are resolved through
  `Samen.Api.PiiResolution.resolve/4` — the same shared resolver used by
  `Driftwood.Reads.driver_roster/1`:

    * on `plane: :tenant` (the broker's own console) the org reads its OWN
      contacts' name/email/phone in CLEAR — no reveal grant needed (the
      tenant-as-owner rule; §external-surface :707);
    * on `plane: :operator` (impersonation or operator-key) the SAME fields
      render `%Masked{}` (→ ••••) or are absent, by construction of the resolver.

  A scope without a plane resolves to the default masked posture (fail-safe).
  """

  require Ash.Query

  @doc """
  Read all CRM companies for the given scope — non-PII; org-scoped by policy.
  Returns a list of `Driftwood.Crm.Company` structs (may be empty on error).
  """
  def companies(scope) do
    Driftwood.Crm.Company
    |> Ash.Query.ensure_selected([:name, :industry, :size, :custom])
    |> Ash.Query.sort(name: :asc)
    |> Ash.read!(scope: scope)
  rescue
    _ -> []
  end

  @doc """
  Read all CRM people (contacts) for the given scope.

  The PII fields (full_name / emails / phones) are vault-routed; this function
  calls `Samen.Api.PiiResolution.resolve/4` after the Ash read so the plane-
  correct value reaches the LiveView:

    * tenant plane  → plaintext (the org reads its own contacts in the clear)
    * operator plane → %Masked{} (••••) under impersonation; absent on API key

  The resolver handles the `%Masked{}` → `••••` rendering via `Phoenix.HTML.Safe`.
  A resolver failure MUST NOT downgrade to plaintext — the fields stay `%Masked{}`.
  """
  def contacts(scope) do
    Driftwood.Crm.Person
    |> Ash.Query.ensure_selected([:full_name, :emails, :phones, :display_name, :job_title, :company_id])
    |> Ash.Query.sort(display_name: :asc)
    |> Ash.read!(scope: scope)
    |> resolve_person_pii(scope)
  rescue
    _ -> []
  end

  @doc """
  Read all CRM opportunities for the given scope, grouped by pipeline stage name.

  Returns `[%{stage: stage_name, opportunities: [...]}]` sorted by stage order.
  Non-PII: opportunity names, values, statuses, company links.
  """
  def pipeline(scope) do
    opps =
      Driftwood.Crm.Opportunity
      |> Ash.Query.ensure_selected([:name, :value_cents, :status, :pipeline_id, :company_id, :close_date])
      |> Ash.Query.sort(inserted_at: :asc)
      |> Ash.read!(scope: scope)

    stages =
      Driftwood.Crm.Pipeline
      |> Ash.Query.ensure_selected([:name, :label, :stage_order])
      |> Ash.Query.sort(stage_order: :asc)
      |> Ash.read!(scope: scope)

    # Build a map of pipeline_id → stage label for display.
    stage_by_id = Map.new(stages, fn s -> {s.id, s} end)

    # Group opportunities by their pipeline stage (label → list of opps).
    opps_by_stage =
      Enum.group_by(opps, fn opp ->
        case Map.get(stage_by_id, opp.pipeline_id) do
          nil -> %{name: "unknown", label: "Unknown", stage_order: 99}
          stage -> stage
        end
      end)

    # Return a list of {stage, opps} sorted by stage_order.
    stages
    |> Enum.map(fn stage ->
      stage_opps = Map.get(opps_by_stage, stage, [])
      %{stage: stage, opportunities: stage_opps}
    end)
    |> Enum.filter(fn %{opportunities: o} -> length(o) > 0 end)
  rescue
    _ -> []
  end

  @doc """
  Metric counts for the CRM summary (companies, contacts, open opportunities, pipeline value).
  All non-PII counts and sums.
  """
  def metrics(scope) do
    companies_count = count_resource(Driftwood.Crm.Company, scope)
    contacts_count = count_resource(Driftwood.Crm.Person, scope)

    opps = open_opportunities(scope)
    open_opps_count = length(opps)
    pipeline_value_cents = Enum.reduce(opps, 0, &(&1.value_cents + &2))

    %{
      companies: companies_count,
      contacts: contacts_count,
      open_opps: open_opps_count,
      pipeline_value_cents: pipeline_value_cents
    }
  end

  # -- private -----------------------------------------------------------------

  # Resolve PII fields on Person records through the shared tenant-plane resolver.
  # Fail-safe: on any resolver error the fields stay %Masked{} (no plaintext downgrade).
  defp resolve_person_pii(records, scope) do
    Samen.Api.PiiResolution.resolve(
      records,
      Driftwood.Crm.Person,
      actor_of(scope),
      repo: Driftwood.Repo
    )
  rescue
    _ -> records
  end

  defp actor_of(%Samen.Scope{actor: actor}), do: actor
  defp actor_of(actor) when is_map(actor), do: actor
  defp actor_of(_), do: %{}

  defp count_resource(resource, scope) do
    resource
    |> Ash.count!(scope: scope)
  rescue
    _ -> 0
  end

  defp open_opportunities(scope) do
    Driftwood.Crm.Opportunity
    |> Ash.Query.ensure_selected([:value_cents, :status])
    |> Ash.Query.filter(status == :open)
    |> Ash.read!(scope: scope)
  rescue
    _ -> []
  end
end
