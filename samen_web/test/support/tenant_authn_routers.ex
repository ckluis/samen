defmodule Samen.WebTest.TenantAuthn do
  @moduledoc """
  Test-support routers for `Samen.Web.TenantAuthnCoverageTest` (PP-1 / PP-3, Batch 1).

  Mirrors `Samen.WebTest.FleetCockpitRouter` (the operator-route enumerating authz proof,
  ADR-044 §6.3): REAL compiled `Phoenix.Router`s mounting the PII-bearing TENANT mount macros
  (`samen_module_routes` for crm/billing/support + `samen_notifications_routes` /
  `samen_files_routes` / `samen_search_routes`) so the SECURITY PROPERTY — an unauthenticated
  `?org=` request to any tenant mount resolves NO org — can be proven by ENUMERATING
  `Phoenix.Router.routes/1` off a compiled router rather than by a hand-maintained list.

  Two shapes, matching the two real verticals:

    * `UnlabeledTenantRouter` — pawchart-shaped: cosmetic labels ONLY, NO `:authn`/
      `:authorized_orgs` seam. Under an ARMED host this is the fail-open hole PP-1 exploited;
      after the `CurrentOrg.resolve/3` fix it FAILS CLOSED (`nil`, no PII) — safe-because-denied.
    * `LabeledTenantRouter` — driftwood-shaped: the full `:authn` + `:authorized_orgs` seam. The
      POSITIVE CONTROL: armed → the authorized path; a real authenticated member still resolves
      its own org, an unauthenticated `?org=` still denies.

  Both carry an explicit `:otp_app` label pointing at a FICTIONAL host app
  (`:samen_web_tenant_authn_test_host`) so the test can arm/disarm `auth_required?` in isolation,
  never poisoning `:samen_web` for other suites. The namespace/repo modules are inert literals —
  the routers are ENUMERATED for route metadata + the serialized mount, never dispatched, so no
  DB/domain is needed (the `:otp_app` label short-circuits `Operator.otp_app/1`'s repo lookup).
  """

  @otp_app :samen_web_tenant_authn_test_host

  @doc "The fictional host otp_app the coverage test arms/disarms."
  def otp_app, do: @otp_app

  @doc "The `:authorized_orgs` seam for the labeled (driftwood-shaped) positive control."
  def authorized_org_ids(user_id),
    do: Application.get_env(:samen_web, :tenant_authn_authorized_orgs, %{})[user_id] || []

  defmodule UnlabeledTenantRouter do
    @moduledoc "pawchart-shaped host: PII-bearing tenant mounts with NO `:authn` seam."
    use Phoenix.Router
    import Phoenix.LiveView.Router
    import Samen.Web.Router

    # Inlined literal (the parent module's otp_app/0 is not yet callable mid-compile).
    @labels %{
      otp_app: :samen_web_tenant_authn_test_host,
      title: "Unlabeled Clinic"
    }

    pipeline :browser do
      plug(:accepts, ["html"])
    end

    scope "/" do
      pipe_through(:browser)

      samen_module_routes(:crm, Samen.WebTest.AuthnProbe.Crm, repo: Samen.WebTest.AuthnProbe.Repo, labels: @labels)
      samen_module_routes(:billing, Samen.WebTest.AuthnProbe.Billing, repo: Samen.WebTest.AuthnProbe.Repo, labels: @labels)
      samen_module_routes(:support, Samen.WebTest.AuthnProbe.Support, repo: Samen.WebTest.AuthnProbe.Repo, labels: @labels)

      samen_notifications_routes(:notifications, Samen.WebTest.AuthnProbe.Primitives,
        repo: Samen.WebTest.AuthnProbe.Repo,
        labels: @labels
      )

      samen_files_routes(:files, Samen.WebTest.AuthnProbe.Primitives, repo: Samen.WebTest.AuthnProbe.Repo, labels: @labels)
      samen_search_routes(:search, Samen.WebTest.AuthnProbe.Primitives, repo: Samen.WebTest.AuthnProbe.Repo, labels: @labels)
    end
  end

  defmodule LabeledTenantRouter do
    @moduledoc "driftwood-shaped host: the SAME tenant mounts WITH the `:authn` + `:authorized_orgs` seam."
    use Phoenix.Router
    import Phoenix.LiveView.Router
    import Samen.Web.Router

    # Inlined literal otp_app (the parent module's otp_app/0 is not yet callable mid-compile).
    @labels %{
      otp_app: :samen_web_tenant_authn_test_host,
      title: "Labeled Freight",
      authn: {:app_env, :samen_web_tenant_authn_test_host, :auth_required?},
      authorized_orgs: {Samen.WebTest.TenantAuthn, :authorized_org_ids, []}
    }

    pipeline :browser do
      plug(:accepts, ["html"])
    end

    scope "/" do
      pipe_through(:browser)

      samen_module_routes(:crm, Samen.WebTest.AuthnProbe.Crm, repo: Samen.WebTest.AuthnProbe.Repo, labels: @labels)
      samen_module_routes(:billing, Samen.WebTest.AuthnProbe.Billing, repo: Samen.WebTest.AuthnProbe.Repo, labels: @labels)
      samen_module_routes(:support, Samen.WebTest.AuthnProbe.Support, repo: Samen.WebTest.AuthnProbe.Repo, labels: @labels)

      samen_notifications_routes(:notifications, Samen.WebTest.AuthnProbe.Primitives,
        repo: Samen.WebTest.AuthnProbe.Repo,
        labels: @labels
      )

      samen_files_routes(:files, Samen.WebTest.AuthnProbe.Primitives, repo: Samen.WebTest.AuthnProbe.Repo, labels: @labels)
      samen_search_routes(:search, Samen.WebTest.AuthnProbe.Primitives, repo: Samen.WebTest.AuthnProbe.Repo, labels: @labels)
    end
  end
end
