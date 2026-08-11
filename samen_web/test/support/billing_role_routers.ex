defmodule Samen.WebTest.BillingRole do
  @moduledoc """
  Test-support routers for `Samen.Web.IdentityNamespaceCoverageTest` (Residual A of the
  pre-PR remediation — the framework-wide `:identity_namespace` enumerating guard).

  Mirrors `Samen.WebTest.TenantAuthn` (the Batch-1 tenant-authn coverage routers): REAL
  compiled `Phoenix.Router`s mounting the role-gated tenant Billing surface
  (`samen_module_routes(:billing, ...)`) so the CLASS PROPERTY — a role-gated billing mount
  either WIRES `:identity_namespace` (→ the caller's real per-org role resolves) OR resolves
  FAIL-CLOSED by construction (no admin, billing permanently non-functional but SAFE) — can be
  proven by ENUMERATING `Phoenix.Router.routes/1` off a compiled router rather than a
  hand-maintained list. A future vertical that forgets the label is caught here, at test time.

  Two shapes, matching the two real-vertical postures:

    * `WiredBillingRouter` — driftwood/pawchart-shaped: the billing mount WIRES
      `identity_namespace: Samen.WebTest.Operator` (an Identity scope that materializes
      `User`/`Membership`), so `Samen.Web.Billing.SettingsLive` resolves the caller's REAL
      per-org membership role — an admin can subscribe/manage-payment.
    * `UnwiredBillingRouter` — the pre-Batch-5a pawchart hole: the SAME billing mount with NO
      `:identity_namespace`. Its own `Samen.WebTest.Billing` namespace materializes no
      `Membership`, so the role resolves FAIL-CLOSED — billing is silently non-functional for
      everyone (safe-because-denied), never fail-OPEN.

  Both mount the REAL `Samen.WebTest.Billing` namespace on `Samen.WebTest.Repo`, so the enumerated
  mount drives `SettingsLive.load/2` against real seeded `Membership` rows (the DataCase repo),
  exactly as the shipped billing tests do.
  """

  defmodule WiredBillingRouter do
    @moduledoc "driftwood/pawchart-shaped: the billing mount WIRES `:identity_namespace`."
    use Phoenix.Router
    import Phoenix.LiveView.Router
    import Samen.Web.Router

    pipeline :browser do
      plug(:accepts, ["html"])
    end

    scope "/" do
      pipe_through(:browser)

      samen_module_routes(:billing, Samen.WebTest.Billing,
        repo: Samen.WebTest.Repo,
        labels: %{identity_namespace: Samen.WebTest.Operator}
      )
    end
  end

  defmodule UnwiredBillingRouter do
    @moduledoc "the pre-Batch-5a hole: the SAME billing mount with NO `:identity_namespace`."
    use Phoenix.Router
    import Phoenix.LiveView.Router
    import Samen.Web.Router

    pipeline :browser do
      plug(:accepts, ["html"])
    end

    scope "/" do
      pipe_through(:browser)

      samen_module_routes(:billing, Samen.WebTest.Billing, repo: Samen.WebTest.Repo, labels: %{})
    end
  end
end
