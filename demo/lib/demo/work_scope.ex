defmodule Demo.WorkScope do
  @moduledoc """
  The Demo host's Work domain — mounted from the `samen_core` Work scope blueprint
  (ADR-004; F1, ADR-041 §3 — the canonical Work-scope Task, T43).

  One `use Samen.Scopes.Work` expands into two host-owned resources
  (`Demo.WorkScope.{Project,Task}`), each a normal `use Samen.Resource` in the
  DEMO's `otp_app`/`repo`, so:

    * their columns are catalogued in the DEMO's `tam_table`/`fld_field`
      (the `AddWorkScope` migration's `catalog_sync/1`);
    * the DEMO's unchanged verifiers scan them;
    * org-scope + RBAC policies are inherited, not re-authored;
    * `Task` carries the generic `(subject_key, subject_id)` object-ref anchor —
      CRM-agnostic by construction (ADR-041 §4.1). This mount touches NO CRM code.

  This scope carries NO PII — see `Samen.Scopes.Work` moduledoc for the full
  posture table (INV-1: the catalog PII map is empty).
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Work,
    otp_app: :demo,
    repo: Demo.Repo,
    namespace: Demo.WorkScope
end
