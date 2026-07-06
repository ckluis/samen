defmodule Demo.Identity do
  @moduledoc """
  The Demo host's Identity domain — mounted from the `samen_core` Identity scope
  blueprint (ADR-004; T3.1 acceptance: "the demo able to mount Identity end-to-end").

  One `use Samen.Scopes.Identity` expands into six host-owned resources
  (`Demo.Identity.{Org,User,Membership,Role,ApiKey,Invitation}`), each a normal
  `use Samen.Resource` in the DEMO's `otp_app`/`repo`, so:

    * their columns are catalogued in the DEMO's `tam_table`/`fld_field`
      (the copied `AddIdentityScope` migration's `catalog_sync/1`);
    * the DEMO's unchanged verifiers (`catalog_parity`, `prefixes`, `pii_reads`,
      `pii_classify`, `no_plaintext_pii`) scan them;
    * the user/invitation PII routes into the DEMO's one Postgres vault;
    * the org-scope + RBAC policies are inherited, not re-authored.

  Audit rides the existing T2.2 `aud_event` tier (`Samen.Scopes.Identity.Audit`),
  never a new table.

  The demo's contact-manager CRM (`Demo.Crm`) is a separate PII-vault dogfood and
  stays as-is; Identity is mounted alongside it to prove the scope-packaging seam.
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Identity,
    otp_app: :demo,
    repo: Demo.Repo,
    namespace: Demo.Identity
end
