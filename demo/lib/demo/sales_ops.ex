defmodule Demo.SalesOps do
  @moduledoc """
  The Demo host's SalesOps domain — mounted from the `samen_core` SalesOps
  scope blueprint (ADR-004; F6+F7, T48), mirroring `Demo.DocsScope`/`Demo.Tags`/
  `Demo.LocationsScope`.

  One `use Samen.Scopes.SalesOps` expands into two host-owned resources
  (`Demo.SalesOps.Vendor` + `Demo.SalesOps.Lead`), a normal `use Samen.Resource`
  in the DEMO's `otp_app`/`repo`, so:

    * their columns are catalogued in the DEMO's `tam_table`/`fld_field` (the
      `AddSalesOpsScope` migration's `catalog_sync/1`);
    * the DEMO's unchanged verifiers scan them;
    * org-scope + RBAC policies are inherited, not re-authored;
    * `Vendor.contact_*`/`Lead.full_name`/`Lead.emails`/`Lead.phones` are 🔒
      vault-routed — masked per plane through the SAME `Samen.Api.PiiResolution`
      seam every other vaulted field uses (INV-1);
    * `Lead.convert` (F7) targets the ALREADY-MOUNTED `Demo.CrmScope`
      (`Person`/`Opportunity`/`Company`) — the real "Contact"/deal Demo's own
      CRM surface reads.

  Demo stays API-only (per house layout) — no web-surface router mount here,
  same boundary as the Docs/Tags/Locations scopes.
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.SalesOps,
    otp_app: :demo,
    repo: Demo.Repo,
    namespace: Demo.SalesOps,
    person_mod: Demo.CrmScope.Person,
    opportunity_mod: Demo.CrmScope.Opportunity,
    company_mod: Demo.CrmScope.Company,
    abbrevs: %{vendor: "dsv", lead: "dsl"}
end
