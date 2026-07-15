defmodule Demo.IdentityPolicyMatrixTest do
  @moduledoc """
  The Identity org-scope + RBAC policy matrix (T3.1). Exercises the REAL mounted
  Identity resources against the REAL Postgres, through the REAL Ash policy
  authorizer (simple_sat). These are the load-bearing acceptance tests for the
  scope-packaging + policy patterns every other scope copies.

  Now driven by `Samen.RedPath` (WS-D D1.3) — this file IS the canonical
  policy-matrix template the generator emits, collapsed to the macro calls with
  identical semantics to the hand-authored original:

    * cross-org read denied (org-scope FilterCheck) — a property test over many
      org pairs (the `cross-org read denied (policy matrix property test)` red path);
    * cross-org write denied (+ the positive write control);
    * an org-less actor sees zero rows (fail closed);
    * PII masked-by-default on the tenant-plane read (user/invitation);
    * the positive cases (an actor sees + writes its OWN org's rows).
  """
  use Demo.DataCase, async: false
  use Samen.RedPath, repo: Demo.Repo

  alias Demo.Identity.{Org, User, Invitation}

  policy_matrix(
    resource: User,
    org: Org,
    attrs: fn org_id ->
      handle = "u#{System.unique_integer([:positive])}"

      %{
        handle: handle,
        org_id: org_id,
        full_name: %{first: handle, last: "L"},
        emails: ["#{handle}@example.com"]
      }
    end,
    update: {:update, %{status: "changed"}},
    pii: [:full_name, :emails],
    max_runs: 25
  )

  masked_by_default(
    resource: Invitation,
    org: Org,
    role: :admin,
    attrs: fn org_id -> %{org_id: org_id, role: :member, email: ["invitee@example.com"]} end,
    pii: [:email],
    refute_plaintext: ["invitee@example.com"]
  )
end
