defmodule PawChart.Directory do
  @moduledoc """
  The PawChart tenant DIRECTORY (ADR-013 §4.2 / §7) — the `{tenant_org_id, name}` list the
  framework workspace switcher + the default-org / name resolution read on a plain tenant/shared
  mount (CRM/Billing/Support/…), which cannot see the operator namespace itself.

  Each row is an operator-side ACCOUNT `Identity.Org` (Bridge-B): its `slug` carries the
  tenant_org_id back-reference, its `name` is the clinic's display name. This is the SAME book of
  business `Samen.Web.Operator.Reads.accounts/3` assembles, projected to the minimal non-PII
  directory shape the switcher needs. Wired onto the mounts via the
  `org_directory: {PawChart.Directory, :orgs, []}` label in `PawChartWeb.Router`.

  Non-PII: `Org` carries only name/slug/plan (no vault fields), so this is a trusted framework
  read of the operator org's own grouping rows. Fail-safe: any error → `[]` (the switcher hides).
  """
  require Ash.Query

  @operator_org_id "0f000000-0000-4000-8000-0000000000c1"

  @doc """
  The tenant directory: `[{tenant_org_id, name}, …]` over the operator org's account Orgs.
  Consumed by `Samen.Web.CurrentOrg.list_orgs/1` (the switcher + first-listable default + name).
  """
  @spec orgs() :: [{String.t(), String.t()}]
  def orgs do
    PawChart.Operator.Org
    |> Ash.Query.filter(org_id == ^@operator_org_id and id != ^@operator_org_id)
    |> Ash.Query.sort(name: :asc)
    |> Ash.read!(authorize?: false)
    |> Enum.flat_map(fn org ->
      case org.slug do
        slug when is_binary(slug) and slug != "" -> [{slug, org.name}]
        _ -> []
      end
    end)
  rescue
    _ -> []
  end
end
