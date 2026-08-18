require Samen.Scopes.Automation.Blueprint

Samen.Scopes.Automation.Blueprint.define_escalation(
  Samen.WebTest.Automation.Escalation,
  :samen_web,
  Samen.WebTest.Automation,
  Samen.WebTest.Repo,
  "wes"
)

# T42 (ADR-039 §8) additions — `Workflow` + `Run`, needed by
# `automation_health_live_test.exs` (the operator health view + kill-switch +
# masking proofs). Same top-level-placement rationale as `define_escalation/5`
# above (the alias-doubling quirk). Fresh `wwa`/`war` abbrevs, allocator-reserved
# for the samen_web test host.
Samen.Scopes.Automation.Blueprint.define_workflow(
  Samen.WebTest.Automation.Workflow,
  :samen_web,
  Samen.WebTest.Automation,
  Samen.WebTest.Repo,
  "wwa"
)

Samen.Scopes.Automation.Blueprint.define_run(
  Samen.WebTest.Automation.Run,
  :samen_web,
  Samen.WebTest.Automation,
  Samen.WebTest.Repo,
  "war"
)

defmodule Samen.WebTest.Automation do
  @moduledoc """
  The samen_web test-support AUTOMATION domain (T41/T42; ADR-039 §7/§8) — mounts
  `Escalation` directly via
  `Samen.Scopes.Automation.Blueprint.define_escalation/5` (the
  `Samen.Approvals.Blueprint.define_approval/5` precedent: "invoked directly by the
  host instead of via an intermediate scope macro" — samen_web needs the E5
  escalation primitive for the `notifications_sources_test.exs` SLA-breach source
  proof), plus `Workflow`/`Run` (T42 — the operator health view + kill-switch
  test target, `automation_health_live_test.exs`). This is a DIRECT mount of
  the three resources T42 needs, NOT the full `use Samen.Scopes.Automation`
  macro (which would also pull in `Reminder`, unused here) — substrate-first
  stays samen_core-only per T39's INV-5 posture; this fixture exists only to
  exercise the samen_web LiveView layer against real rows.

  Each `define_*` is called at the TOP of this file, OUTSIDE this domain's own
  `defmodule` block — nesting the call inside `defmodule Samen.WebTest.Automation
  do ... end` triggers an Elixir alias-resolution doubling quirk when the target
  module name shares the enclosing module as a prefix. `Samen.Scopes.Automation`'s
  own `__using__` macro avoids this by computing the target via `Module.concat/2`
  from an explicit `namespace:` OPTION (resolved through `Macro.expand/2`, not a
  literal alias token) — the same technique isn't available to a bare macro call
  like this one, so top-level placement is the working alternative.

  Fresh `wes`/`wwa`/`war` abbrevs, appended to `samen_core/priv/abbrev_registry.json`
  (append-only rows for the samen_web test host, allocator-reserved).
  """
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(Samen.WebTest.Automation.Escalation)
    resource(Samen.WebTest.Automation.Workflow)
    resource(Samen.WebTest.Automation.Run)
  end
end
