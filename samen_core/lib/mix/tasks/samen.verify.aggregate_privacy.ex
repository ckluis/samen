defmodule Mix.Tasks.Samen.Verify.AggregatePrivacy do
  @shortdoc "Verify every aggregate-plane resource declares a fail-closed cohort spec (T4.5 floors)."

  @moduledoc """
  `mix samen.verify.aggregate_privacy` — the whole-app CI backstop that keeps the
  aggregate-privacy FLOORS (k-anonymity + l-diversity) enforceable (T4.5 clauses
  (a)+(b); doc §control ∴ block + "Token-blind isn't inference-blind" honest edge).

  ## What it checks (the ENFORCED floor)

  For every aggregate-plane resource (one declared with `use Samen.Aggregate.Resource`)
  in every configured domain, it FAILS the build if the resource does not declare a
  **fail-closed cohort spec** (`aggregate_cohort_spec/0` returning a
  `%Samen.Aggregate.CohortSpec{}`). The cohort spec is what
  `Samen.Aggregate.read_all/2` needs to enforce the floors: it names the cohort-size
  column (k-anonymity), the optional distinct-sensitive column (l-diversity), and the
  releasable-value columns to suppress.

  Without this check, an aggregate resource with no cohort spec would return
  `{:error, :no_cohort_spec}` at READ time (fail-closed at runtime) — but a host could
  ship such a resource and only discover the gap in production. This verifier turns
  "every aggregate cell is floor-protected" into a **gated invariant**: a new
  cross-tenant projection that forgot its cohort spec does not pass CI. It also asserts
  the spec's `cohort_count_column` and `value_columns` are non-empty (a k-anon floor
  needs a cohort size and something to suppress).

  ## What this DOES NOT check — posture under construction (stated exactly)

  The doc is explicit: the FLOOR (k-anon + l-div) is enforced today; the **cross-query
  budget / DP layer is posture under construction, not a solved proof**. This verifier
  gates the FLOOR only. It deliberately does NOT assert anything about the query-budget
  ledger's coverage, cross-query suppression, differential-privacy noise, or
  t-closeness — those are the T6.6 research track (`Samen.Aggregate.QueryBudget` is a
  WARN-not-enforce SCAFFOLD). A green result here means the enforced floor is wired,
  NOT that the cross-query defence is solved. See the T4.5 report.

  ## Usage

      mix samen.verify.aggregate_privacy
      mix samen.verify.aggregate_privacy --domain MyApp.Aggregate

  ## Exit code

  Exits 0 on success, 1 on any violation (fail-closed via `Samen.Verifier`).
  """
  use Mix.Task

  alias Samen.Aggregate.CohortSpec

  @task_name "samen.verify.aggregate_privacy"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _rest, _} = OptionParser.parse(args, strict: [domain: :keep])

    Samen.Verifier.halt_if_violations(@task_name, violations(opts))
  end

  @doc """
  The fleet of cohort-spec violations across the configured domains. Separated from
  `run/1` so tests can call it without halting.
  """
  def violations(opts \\ []) do
    aggregate_resources(opts)
    |> Enum.flat_map(&resource_violations/1)
  end

  @doc """
  Cohort-spec violations for an EXPLICIT list of resources (bypasses domain discovery).
  Used by the red-path test to check specific fixtures without registering them in a
  configured domain.
  """
  def violations_for(resources) when is_list(resources) do
    resources
    |> Enum.filter(&Samen.Aggregate.Info.aggregate_plane?/1)
    |> Enum.flat_map(&resource_violations/1)
  end

  defp resource_violations(resource) do
    cohort_violations(resource) ++ org_scoped_violations(resource)
  end

  # The ORG-SCOPED arm (P17 / ADR-045 §3). Every EXTRA check applies ONLY to a resource
  # that opts into the org-scoped aggregate plane (`org_scoped_aggregate?/0` → true). It
  # must carry a real `org_id` PARTITION — a non-null `org_id` attribute — or an org-scoped
  # read (`Samen.Aggregate.read_all_for_org/3`) is not actually partitioned by org and a
  # cohort could span orgs. A nullable `org_id` is exactly the CROSS-tenant shape (the
  # org-less `Aggregate.Actor` plane, where `org_id` is NULL by design) — the wrong shape
  # for the tenant's own-org path. The fail-closed cohort spec (below) and the C7
  # `NoPiiColumns` compile-time refusal already apply to EVERY aggregate resource; this arm
  # adds the org-partition invariant that makes "the tenant reads only their own org" a
  # gated property, not a convention. Keeps the non-vacuity discipline (a claim of
  # org-scope with no real partition FAILS, per the A2/X9 lesson).
  defp org_scoped_violations(resource) do
    if Samen.Aggregate.Info.org_scoped?(resource) do
      case Ash.Resource.Info.attribute(resource, :org_id) do
        nil ->
          [
            "org-scoped aggregate resource #{inspect(resource)} (org_scoped_aggregate?/0 == " <>
              "true) declares no `org_id` attribute — an org-scoped projection MUST carry a " <>
              "non-null org_id PARTITION so Samen.Policy.OrgScope narrows the read to the " <>
              "caller's own org. Without it, read_all_for_org/3 is not partitioned by org."
          ]

        %{allow_nil?: true} ->
          [
            "org-scoped aggregate resource #{inspect(resource)} (org_scoped_aggregate?/0 == " <>
              "true) has a NULLABLE `org_id` — that is the CROSS-tenant (org-less) shape, not " <>
              "an org partition. An org-scoped projection MUST declare org_id allow_nil?: " <>
              "false so every row belongs to exactly one org and OrgScope can narrow it. A " <>
              "nullable org_id lets a NULL-org (cross-tenant) row enter a tenant's own-org read."
          ]

        %{allow_nil?: false} ->
          []
      end
    else
      []
    end
  end

  defp cohort_violations(resource) do
    case CohortSpec.spec_for(resource) do
      nil ->
        [
          "aggregate-plane resource #{inspect(resource)} declares no fail-closed cohort " <>
            "spec (aggregate_cohort_spec/0 returning a %Samen.Aggregate.CohortSpec{}). The " <>
            "k-anonymity / l-diversity floors (T4.5) cannot be enforced without one — every " <>
            "aggregate read of this resource fails closed (:no_cohort_spec). Declare a cohort " <>
            "spec naming the cohort-size column, the value columns to suppress, and (where a " <>
            "sensitive attribute rides the cohort) the distinct-sensitive column."
        ]

      %CohortSpec{cohort_count_column: nil} ->
        ["aggregate-plane resource #{inspect(resource)}'s cohort spec has no cohort_count_column (k-anon needs a cohort size)."]

      %CohortSpec{value_columns: []} ->
        ["aggregate-plane resource #{inspect(resource)}'s cohort spec has empty value_columns (nothing to suppress when a floor fires)."]

      %CohortSpec{} ->
        []
    end
  end

  @doc "The aggregate-plane resources across the configured domains."
  def aggregate_resources(opts \\ []) do
    domains(opts)
    |> Enum.flat_map(&Ash.Domain.Info.resources/1)
    |> Enum.uniq()
    |> Enum.filter(&Samen.Aggregate.Info.aggregate_plane?/1)
  end

  defp domains(opts) do
    case Keyword.get_values(opts, :domain) do
      [] ->
        otp_app = Mix.Project.config()[:app]
        Application.get_env(otp_app, :ash_domains, [])

      names ->
        Enum.map(names, &Module.concat([&1]))
    end
  end
end
