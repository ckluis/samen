defmodule Driftwood.Automation do
  @moduledoc """
  Driftwood's Automation domain — mounted from the samen_core Automation scope
  blueprint (ADR-039 §3.1; T39/T118), exactly as `Driftwood.Calendar` mounts the
  Calendar scope. The FIRST vertical adoption of `Samen.Scopes.Automation` (no
  host currently dogfoods the E1 engine — T39's engine substrate is confirmed but
  was never wired into a real host router until T118's builder LiveView needed a
  real browser-real proof).

  One `use Samen.Scopes.Automation` expands into four host-owned resources:

    * `Driftwood.Automation.Workflow` — the E1 rule definition (trigger →
      conditions → actions), incl. the §8.4 kill columns. This is the ONLY
      resource `Samen.Web.Automation.BuilderLive` (T118) touches.
    * `Driftwood.Automation.Reminder` — the E4 first-class reminder (T41).
    * `Driftwood.Automation.Escalation` — the E5 generic escalation primitive (T41).
    * `Driftwood.Automation.Run` — the E8 run log (T42), read-only from either
      plane; T118's builder does NOT render it (T42's own operator health view
      owns the run log surface).

  Mounted here via `use Samen.Scopes.Automation` (the full-scope framework-first
  macro call) rather than a partial direct `Blueprint.define_workflow/5` call —
  Driftwood is a real dogfood vertical, not a test fixture economizing on rows
  (the `Samen.WebTest.Automation` test host's partial mount is a DIFFERENT,
  deliberately-scoped precedent — see its own moduledoc).

  ## Engine wiring (host side)

  `config :samen_core, Samen.Automation, workflow_module: Driftwood.Automation.Workflow,
  repo: Driftwood.Repo` (config/config.exs) — the SAME `Samen.Notifications.Engine`
  convention every other host-wired kernel seam uses. `Samen.Web.Automation.Reads`
  never relies on this global config (it always passes explicit
  `workflow_module:`/`repo:` opts derived from the mount — opts win over config),
  so the builder LiveView works even before this line is added; it is wired anyway
  for host-level completeness (a future EventCapture-driven resource_event trigger
  needs it). The `:automation`/`:automation_timers` Oban queues are registered in
  the SAME `config :samen_core, Oban, queues: [...]` list every other queue lives in.

  ## Abbrev allocation (fresh abbrevs — the ADR-039 defaults were already claimed)

  `Samen.Scopes.Automation`'s built-in defaults (`awf`/`arm`/`aes`/`sar`) are
  already owned by `samen_core`'s OWN `SamenCore.Support.AutomationFixture.*` test
  fixture (T39) — a global-net collision, not a host-namespace one, but still
  refused by the allocator. Driftwood took fresh, explicitly-reserved abbrevs
  (`mix samen.abbrev.reserve --host driftwood --owner Driftwood.Automation.Workflow
  --abbrev dwf`, and so on for reminder/escalation/run) — the SAME "d"-prefixed
  fresh-abbrev convention `Driftwood.SalesOps`/`Driftwood.Work` already use.
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Automation,
    otp_app: :driftwood,
    repo: Driftwood.Repo,
    namespace: Driftwood.Automation,
    abbrevs: %{workflow: "dwf", reminder: "drm", escalation: "des", run: "dru"}
end
