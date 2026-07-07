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
  # T3.11 — `json_api: true` on the Identity mount injects the opt-in `json_api`
  # allowlist blocks on Org/User/Membership (default not-exposed). The domain-level
  # AshJsonApi.Domain extension is intentionally OMITTED here: adding it to a domain
  # that DEFINES resources inline (the blueprint expansion) would leak the domain's
  # `json_api/1` macro into those nested resource modules and collide with the
  # resource-level `json_api/1` (a conflicting-import compile error). The public
  # router reads resource-level routes directly (AshJsonApi.Resource.Info.routes/1),
  # so resource-level `json_api` blocks are sufficient to publish these routes.
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Identity,
    otp_app: :demo,
    repo: Demo.Repo,
    namespace: Demo.Identity,
    json_api: true

  # T3.11 — the AshJsonApi controller router first calls `domain.json_api_match_route/2`
  # and, on `:error`, falls through to each resource's own `json_api_match_route/2`
  # (the resource-level routes we declare). The full `AshJsonApi.Domain` extension
  # would generate this fallback — but importing it here would leak the domain-level
  # `json_api/1` macro into the blueprint's NESTED resource `defmodule`s and collide
  # with `AshJsonApi.Resource.json_api/1` (a conflicting-import compile error). So we
  # define ONLY the fallback the controller needs, by hand. The resource routes
  # (Org/User/Membership) are then served via the controller's per-resource fallback.
  def json_api_match_route(_method, _path_info), do: :error
end
