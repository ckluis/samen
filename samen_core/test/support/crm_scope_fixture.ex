defmodule SamenCore.Support.CrmScopeFixture do
  @moduledoc """
  Kernel test-fixture domain mounting the REAL **CRM** scope blueprint
  (`Samen.Scopes.Crm`, T3.2) inside `samen_core`'s own test suite — the
  Lead-conversion TARGET for the SalesOps scope fixture (F6+F7, T48):
  `Lead.convert` creates a `SamenCore.Support.CrmScopeFixture.Person` (Contact)
  + `SamenCore.Support.CrmScopeFixture.Opportunity`, exactly like a real host.

  Fresh abbrevs (`scc`/`scp`/`csp`/`sco`/`sca`, reserved via `mix
  samen.abbrev.reserve --host samen_core --propose`) — samen_core's own CRM
  mount is distinct from the T1.9 `SamenCore.Support.Crm` dogfood fixture and
  from every host's own CRM mount (`cmp`/`per`/… demo; `fcm`/`fpr`/… driftwood;
  `vca`/`vcb`/… pawchart).
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Crm,
    otp_app: :samen_core,
    repo: SamenCore.TestRepo,
    namespace: SamenCore.Support.CrmScopeFixture,
    abbrevs: %{
      company: "scc",
      person: "scp",
      pipeline: "csp",
      opportunity: "sco",
      attachment: "sca"
    }
end
