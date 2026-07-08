defmodule Samen.Web.CRM.Reads do
  @moduledoc """
  The framework CRM read layer for the inherited CRM pages (companies, contacts, pipeline).

  Promoted from the driftwood-local `Driftwood.CrmReads` (ADR-009 §3.3): the SAME functions,
  but every hardcoded host module becomes `Samen.Web.Mount.resource(mount, Name)` and every
  `repo: Driftwood.Repo` becomes `repo: mount.repo`. So the same code reads Driftwood's CRM
  inside Driftwood, PawChart's CRM inside PawChart — no LiveView or reads function names a
  host module.

  All reads go through Ash so OrgScope + vault masking apply. PII fields on the CRM `Person`
  (full_name / emails / phones) are resolved through `Samen.Api.PiiResolution.resolve/4`:

    * on `plane: :tenant` (the org's own console) the org reads its OWN contacts'
      name/email/phone in CLEAR — no reveal grant needed (tenant-as-owner rule);
    * on `plane: :operator` (impersonation) the SAME fields render `%Masked{}` (→ ••••)
      by construction of the resolver.

  ## MASKING INVARIANT

  This module NEVER calls `Samen.Vault.reveal/3`, NEVER pattern-matches a vault token out
  of a `%Masked{}`, and NEVER introduces a "show plaintext" code path. Plaintext only
  reaches the LiveView if the PiiResolution resolver already resolved it through the shared
  chokepoint. A resolver failure keeps `%Masked{}` (no plaintext downgrade).
  """

  require Ash.Query

  alias Samen.Web.Mount

  @doc "Read all CRM companies for `scope` — non-PII; org-scoped by policy."
  def companies(mount, scope) do
    Mount.resource(mount, Company)
    |> Ash.Query.ensure_selected([:name, :industry, :size, :custom])
    |> Ash.Query.sort(name: :asc)
    |> Ash.read!(scope: scope)
  rescue
    _ -> []
  end

  @doc """
  Read all CRM people (contacts) for `scope`, with PII (full_name/emails/phones)
  plane-resolved through `Samen.Api.PiiResolution` (tenant clear / operator ••••).
  """
  def contacts(mount, scope) do
    Mount.resource(mount, Person)
    |> Ash.Query.ensure_selected([:full_name, :emails, :phones, :display_name, :job_title, :company_id])
    |> Ash.Query.sort(display_name: :asc)
    |> Ash.read!(scope: scope)
    |> resolve_pii(mount, Person, scope)
  rescue
    _ -> []
  end

  @doc "Read CRM opportunities grouped by pipeline stage for `scope`. Non-PII."
  def pipeline(mount, scope) do
    opps =
      Mount.resource(mount, Opportunity)
      |> Ash.Query.ensure_selected([:name, :value_cents, :status, :pipeline_id, :company_id, :close_date])
      |> Ash.Query.sort(inserted_at: :asc)
      |> Ash.read!(scope: scope)

    stages =
      Mount.resource(mount, Pipeline)
      |> Ash.Query.ensure_selected([:name, :label, :stage_order])
      |> Ash.Query.sort(stage_order: :asc)
      |> Ash.read!(scope: scope)

    stage_by_id = Map.new(stages, fn s -> {s.id, s} end)

    opps_by_stage =
      Enum.group_by(opps, fn opp ->
        case Map.get(stage_by_id, opp.pipeline_id) do
          nil -> %{name: "unknown", label: "Unknown", stage_order: 99}
          stage -> stage
        end
      end)

    stages
    |> Enum.map(fn stage ->
      stage_opps = Map.get(opps_by_stage, stage, [])
      %{stage: stage, opportunities: stage_opps}
    end)
    |> Enum.filter(fn %{opportunities: o} -> length(o) > 0 end)
  rescue
    _ -> []
  end

  @doc "Non-PII count/sum metrics for the CRM summary cards."
  def metrics(mount, scope) do
    companies_count = count_resource(Mount.resource(mount, Company), scope)
    contacts_count = count_resource(Mount.resource(mount, Person), scope)

    opps = open_opportunities(mount, scope)
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

  # Resolve PII fields through the shared chokepoint; resource + repo from the mount.
  # Fail-safe: on any resolver error the fields stay %Masked{} (no plaintext downgrade).
  defp resolve_pii(records, mount, name, scope) do
    Samen.Api.PiiResolution.resolve(
      records,
      Mount.resource(mount, name),
      actor_of(scope),
      repo: mount.repo
    )
  rescue
    _ -> records
  end

  defp actor_of(%Samen.Scope{actor: actor}), do: actor
  defp actor_of(actor) when is_map(actor), do: actor
  defp actor_of(_), do: %{}

  defp count_resource(resource, scope) do
    Ash.count!(resource, scope: scope)
  rescue
    _ -> 0
  end

  defp open_opportunities(mount, scope) do
    Mount.resource(mount, Opportunity)
    |> Ash.Query.ensure_selected([:value_cents, :status])
    |> Ash.Query.filter(status == :open)
    |> Ash.read!(scope: scope)
  rescue
    _ -> []
  end
end
