defmodule Demo.CrmScope do
  @moduledoc """
  The Demo host's CRM domain — mounted from the `samen_core` CRM scope
  blueprint (ADR-004; T3.2).

  One `use Samen.Scopes.Crm` expands into six host-owned resources
  (`Demo.CrmScope.{Company,Person,Pipeline,Opportunity,Activity,Attachment}`),
  each a normal `use Samen.Resource` in the DEMO's `otp_app`/`repo`, so:

    * their columns are catalogued in the DEMO's `tam_table`/`fld_field`
      (the `AddCrmScope` migration's `catalog_sync/1`);
    * the DEMO's unchanged verifiers scan them;
    * `Person` PII (full_name/emails/phones via `Samen.Fragments.CorePerson`)
      routes into the DEMO's one Postgres vault;
    * org-scope + RBAC policies are inherited, not re-authored.

  The existing `Demo.Crm` dogfood domain (T1.9) is separate and stays as-is;
  `Demo.CrmScope` proves the T3.2 scope-packaging seam alongside it.

  ## Smoke usage (T3.2 acceptance: "thin smoke usage per scope proves host-mounting works")

  The `Demo.CrmScope.Smoke` module (below) exercises one round-trip per resource
  — a company, a person (with vaulted PII), a pipeline stage, an opportunity,
  an activity, and an attachment — confirming the host-mount and the vault routing
  work end-to-end. The `demo/test/crm_scope_*_test.exs` suite runs this against
  a real Postgres DB.
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Crm,
    otp_app: :demo,
    repo: Demo.Repo,
    namespace: Demo.CrmScope
end
