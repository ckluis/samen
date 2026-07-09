defmodule SamenCore.Support.SuppressionFixture do
  @moduledoc """
  Kernel red-path fixture for ADR-014 §4 (RP-D3): the Marketing scope mounted under
  a NON-`msp` abbrev set (`sxc/sxg/sxs/sxt/sxn/sxe/sxp`).

  The point of this fixture is to prove the suppression check in `Send.:create_checked`
  is **portable across mount abbrevs**. The old kernel hardcoded `SELECT ... FROM
  msp_suppression` — so under any other abbrev it queried a non-existent table and
  SILENTLY bypassed suppression (a compliance leak). This fixture mounts under `sx*`,
  so the check MUST resolve `sxp_suppression` (via the `OrgScope`-inheriting Ash read on
  this mount's own `Suppression` resource) — not `msp_suppression`.

  Not registered in the global `:ash_domains` (test config is `[]`), so it never enters
  the CI verifier/catalog sweep. The migration (`suppression_fixture` in test_repo) creates
  the physical `sx*` tables + catalogs the resources in-tx, mirroring how demo/driftwood/
  samen_web mount Marketing.
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Marketing,
    otp_app: :samen_core,
    repo: SamenCore.TestRepo,
    namespace: SamenCore.Support.SuppressionFixture,
    abbrevs: %{
      campaign: "sxc",
      segment: "sxg",
      subscriber: "sxs",
      template: "sxt",
      send: "sxn",
      email_event: "sxe",
      suppression: "sxp"
    }
end
