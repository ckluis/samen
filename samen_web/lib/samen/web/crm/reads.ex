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
    |> Ash.Query.ensure_selected([:full_name, :emails, :phones, :display_name, :job_title, :company_id, :custom])
    |> Ash.Query.sort(display_name: :asc)
    |> Ash.read!(scope: scope)
    |> resolve_pii(mount, Person, scope)
  rescue
    _ -> []
  end

  @doc """
  Read ONE keyset page of CRM contacts for `scope` — the A2 `ListLive` reads contract
  (`(mount, scope, %ListState{}) -> %Page{}`, ADR-016 §3). Built on
  `Samen.Web.Reads.page!/3`, so the read is BOUNDED BY CONSTRUCTION
  (`limit(page_size + 1)`, hostile page sizes clamped) and keyset-stable under
  concurrent inserts. PII (full_name/emails/phones) is plane-resolved through
  `Samen.Api.PiiResolution` AFTER paging — tenant clear / operator `%Masked{}` (••••).

  Sort/filter fields are bounded, NON-VAULTED attributes (`display_name`/`job_title`);
  the vaulted columns are never sorted or filtered (see `Samen.Web.Reads` masking notes).
  On any read error the page is EMPTY, never unbounded and never a plaintext downgrade.
  """
  def contacts_page(mount, scope, state) do
    page =
      Mount.resource(mount, Person)
      |> Ash.Query.ensure_selected([
        :full_name,
        :emails,
        :phones,
        :display_name,
        :job_title,
        :company_id,
        :custom
      ])
      |> Samen.Web.Reads.page!(state, scope: scope, filter_fields: [:display_name, :job_title])

    %{page | items: resolve_pii(page.items, mount, Person, scope)}
  rescue
    _ -> %Samen.Web.Page{items: [], page_size: Samen.Web.Reads.bounded_page_size(state.page_size)}
  end

  @doc """
  Read a single CRM person (contact) by id for `scope`, with PII plane-resolved
  (tenant clear / operator ••••). `{:ok, person}` or `:error`. **This is the new
  PII surface** (ADR-011 §5 — the masking-test target).
  """
  def get_contact(mount, scope, id) do
    result =
      Mount.resource(mount, Person)
      |> Ash.Query.ensure_selected([
        :full_name,
        :emails,
        :phones,
        :display_name,
        :job_title,
        :company_id,
        :custom
      ])
      |> Ash.Query.filter(id == ^id)
      |> Ash.read!(scope: scope)
      |> resolve_pii(mount, Person, scope)

    case result do
      [person | _] -> {:ok, person}
      [] -> :error
    end
  rescue
    _ -> :error
  end

  @doc "Read a single CRM company by id for `scope`. Non-PII. `{:ok, company}` or `:error`."
  def get_company(mount, scope, id) do
    result =
      Mount.resource(mount, Company)
      |> Ash.Query.ensure_selected([:name, :domain, :industry, :size, :website, :notes, :custom])
      |> Ash.Query.filter(id == ^id)
      |> Ash.read!(scope: scope)

    case result do
      [company | _] -> {:ok, company}
      [] -> :error
    end
  rescue
    _ -> :error
  end

  @doc "Read this company's contacts (people) for `scope`, PII plane-resolved. Optional (ADR-011 §4.2)."
  def contacts_for_company(mount, scope, company_id) do
    Mount.resource(mount, Person)
    |> Ash.Query.ensure_selected([:full_name, :emails, :phones, :display_name, :job_title, :company_id])
    |> Ash.Query.filter(company_id == ^company_id)
    |> Ash.Query.sort(display_name: :asc)
    |> Ash.read!(scope: scope)
    |> resolve_pii(mount, Person, scope)
  rescue
    _ -> []
  end

  @doc "Read a person's activity stream, newest-first. Non-PII (opaque FKs + bounded fields)."
  def activities_for_person(mount, scope, person_id) do
    Mount.resource(mount, Activity)
    |> Ash.Query.ensure_selected([:type, :subject, :body, :status, :due_at, :completed_at, :custom, :person_id, :company_id])
    |> Ash.Query.filter(person_id == ^person_id)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read!(scope: scope)
  rescue
    _ -> []
  end

  @doc "Read a company's activity stream, newest-first. Non-PII."
  def activities_for_company(mount, scope, company_id) do
    Mount.resource(mount, Activity)
    |> Ash.Query.ensure_selected([:type, :subject, :body, :status, :due_at, :completed_at, :custom, :person_id, :company_id])
    |> Ash.Query.filter(company_id == ^company_id)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read!(scope: scope)
  rescue
    _ -> []
  end

  @doc """
  Read a company's opportunities with its pipeline stage joined. Non-PII (ADR-011 §5).
  Each row gets a `:__stage__` (the `Pipeline` row) for a stage pill.
  """
  def opportunities_for_company(mount, scope, company_id) do
    opps =
      Mount.resource(mount, Opportunity)
      |> Ash.Query.ensure_selected([:name, :value_cents, :status, :pipeline_id, :company_id, :close_date])
      |> Ash.Query.filter(company_id == ^company_id)
      |> Ash.Query.sort(inserted_at: :asc)
      |> Ash.read!(scope: scope)

    stage_by_id =
      Mount.resource(mount, Pipeline)
      |> Ash.Query.ensure_selected([:name, :label, :stage_order])
      |> Ash.read!(scope: scope)
      |> Map.new(fn s -> {s.id, s} end)

    Enum.map(opps, fn opp -> Map.put(opp, :__stage__, Map.get(stage_by_id, opp.pipeline_id)) end)
  rescue
    _ -> []
  end

  @doc """
  Create an activity from the log-activity composer (ADR-011 §6.3). `attrs` carries
  `type`, `subject`, `body`, one of `person_id`/`company_id`, `status`,
  `completed_at`, and `org_id`. The write goes through Ash so OrgScope + the
  `RoleAtLeast(:member)` gate + `SameOrgFk` (a cross-org FK is refused by the kernel)
  all apply — this module adds NO policy of its own. `{:ok, activity}` or
  `{:error, reason}`.
  """
  def create_activity(mount, scope, attrs) do
    Mount.resource(mount, Activity)
    |> Ash.Changeset.for_create(:create, attrs, scope: scope)
    |> Ash.create()
  end

  @doc """
  Read the CRM contacts that are LEADS — `person.custom["lifecycle_stage"]` in the given
  bounded set (ADR-011 §8 prospecting lens). PII (name/email/phone) is plane-resolved
  (tenant clear / operator ••••), same as `contacts/2`. `stages` is a list of stage strings
  (default the early-funnel `["lead", "mql", "sql"]`). Filtered in Elixir over the resolved
  rows because `lifecycle_stage` lives in the Tier-1 `custom` jsonb bag (no Tier-0 column).
  """
  def leads(mount, scope, stages \\ ~w(lead mql sql)) do
    stage_set = MapSet.new(stages)

    contacts(mount, scope)
    |> Enum.filter(fn p ->
      case p.custom do
        %{"lifecycle_stage" => stage} when is_binary(stage) -> MapSet.member?(stage_set, stage)
        _ -> false
      end
    end)
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
