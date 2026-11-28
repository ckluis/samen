defmodule Samen.Web.TenantAnalyticsRouteE2ETest do
  @moduledoc """
  P17 (ADR-045 §3, P17-carry-2) — the tenant own-org analytics surface, driven END-TO-END
  through a REAL router + endpoint (`Samen.WebTest.SecurityEndpoint`), not just at the read
  layer.

  ## The coverage gap this closes (P17 verdict residual #2)

  `tenant_analytics_test.exs` proved the SECURITY of `Samen.Web.Tenant.AnalyticsReads` — the
  org-scoped floor, the cross-org read isolation, the role gate — but every one of those
  assertions ran against the read layer (`AnalyticsReads.funnel/3`) or `AnalyticsLive.load/2`
  DIRECTLY. The `samen_tenant_analytics_routes` macro was mounted by NO router any suite
  exercised, so the `{Samen.Web.TenantAuthz, :require_tenant}` on_mount and the
  `Samen.Web.CurrentOrg` org-authority pinning on THIS route were asserted only by
  construction — the `?org=`-forge was never refused end-to-end through a real mount.

  This suite mounts the macro on the driftwood-shaped armed host (`Samen.WebTest.SecurityRouter`)
  and drives `/analytics` through the endpoint. It proves, on an ARMED host:

    * **(a) the route mounts + renders** for a legitimately authenticated tenant member — its
      OWN org's floored funnel comes back 200 (the positive control / anti-tautology anchor).
    * **(b) the `?org=`-forge is refused** — an authenticated member of org A requesting
      `?org=<org B's uuid>` is bound to org A off the AUTHENTICATED scope; org B's cohorts
      NEVER appear. The org is bound from the authenticated scope, the forge is ignored, fail
      closed.
    * **the on_mount gate is load-bearing** — an UNAUTHENTICATED `?org=` dead render is halted
      (302 → /login), never served (mirrors `TenantAuthnCoverageTest` / `TenantAuthzLiveTest`).

  Sabotaging the surface's org resolution to trust `params["org"]` (sabotage 284) flips (b).
  """
  use Samen.WebTest.DataCase, async: false

  import Phoenix.ConnTest

  alias Samen.WebTest.SecurityHost

  @endpoint Samen.WebTest.SecurityEndpoint

  # Org A is the caller's OWN org (authorized). Org B is the foreign target the forge names.
  # Org B's signup count is a DISTINCTIVE sentinel: if the forge ever succeeds it renders as a
  # cell and this string appears in the attacker's DOM.
  @foreign_signup 987_654
  @own_signup 61

  setup do
    prev = Application.get_env(SecurityHost.otp_app(), :auth_required?)
    prev_orgs = Application.get_env(:samen_web, :security_test_authorized_orgs, %{})

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(SecurityHost.otp_app(), :auth_required?)
        v -> Application.put_env(SecurityHost.otp_app(), :auth_required?, v)
      end

      Application.put_env(:samen_web, :security_test_authorized_orgs, prev_orgs)
    end)

    SecurityHost.revoke_all!()

    # a real invitation is delivered through the test sink
    prev_delivery = Application.get_env(:samen_core, :delivery_env)
    Application.put_env(:samen_core, :delivery_env, :test)

    on_exit(fn ->
      case prev_delivery do
        nil -> Application.delete_env(:samen_core, :delivery_env)
        v -> Application.put_env(:samen_core, :delivery_env, v)
      end
    end)

    # Two REAL tenants (each with its owner), and a person who joined org A as a member through a real invitation: the
    # page acts with the role the membership resolves to (`Samen.Web.TenantActor`), so the principal must hold one.
    owner_a = Samen.WebTest.SpineAccounts.register!()
    owner_b = Samen.WebTest.SpineAccounts.register!()
    member_a = Samen.WebTest.SpineAccounts.accept_into!(owner_a, :member)
    org_a = owner_a.org.id
    org_b = owner_b.org.id

    # Org A's OWN funnel — all stages >= config k (=5), so they RELEASE (distinctive counts).
    insert_paf!(org_a, "signup", @own_signup)
    insert_paf!(org_a, "first_run", 55)
    insert_paf!(org_a, "first_record", 50)

    # Org B's funnel — the foreign data the forge must NEVER reach.
    insert_paf!(org_b, "signup", @foreign_signup)
    insert_paf!(org_b, "first_run", 918_273)
    insert_paf!(org_b, "first_record", 555_444)

    %{org_a: org_a, org_b: org_b, member_a: member_a}
  end

  defp insert_paf!(org_id, stage, actor_count) do
    Ecto.Adapters.SQL.query!(
      Samen.WebTest.Repo,
      """
      INSERT INTO paf_product_event_rollup (paf_org_id, paf_kind, paf_stage, paf_actor_count)
      VALUES ($1, 'funnel', $2, $3)
      """,
      [Ecto.UUID.dump!(org_id), stage, actor_count]
    )
  end

  # A conn carrying a REAL authenticated principal in the SIGNED session (never a param — the
  # only thing `Samen.Web.Auth.authenticated_user_id/1` reads).
  defp signed_in_conn(account) do
    Samen.WebTest.RoleHarness.log_in(account).conn
  end

  # ==========================================================================
  # (a) the route mounts + renders for the authenticated tenant (positive control)
  # ==========================================================================

  test "an authenticated member is served its OWN org's floored funnel end-to-end", ctx do
    SecurityHost.arm!()

    html =
      signed_in_conn(ctx.member_a)
      |> get("/analytics?org=#{ctx.org_a}")
      |> html_response(200)

    # The route mounted and rendered the P17 surface.
    assert html =~ "funnel-table"
    assert html =~ "Your organization"
    # Org A's own >= k cohort released its distinctive count.
    assert html =~ ">#{@own_signup}<",
           "the authenticated member must see its OWN org's floored funnel"
  end

  # ==========================================================================
  # (b) the ?org=<other-org> forge is refused — org bound from the authenticated scope
  # ==========================================================================

  test "an authenticated member of org A asking for org B is served nothing of B's: the member gets A's funnel, never B's", ctx do
    SecurityHost.arm!()

    html =
      signed_in_conn(ctx.member_a)
      |> get("/analytics?org=#{ctx.org_b}")
      |> html_response(200)

    # Org B's foreign data is NEVER reached — the org is bound off the authenticated scope, the
    # `?org=` forge is ignored (CurrentOrg constrains the param to the principal's authorized set).
    refute html =~ "#{@foreign_signup}",
           "the ?org= forge leaked another org's cohort through the real analytics mount"
    refute html =~ "918273"
    refute html =~ "555444"
    # the forged org is not bound at all: the page is the org-less empty state, not an access card for org B
    assert html =~ "analytics-empty"
    refute html =~ "actor-denied"

    # POSITIVE CONTROL (anti-tautology): the same person, with the same login, asking for its OWN org is served its funnel.
    own =
      signed_in_conn(ctx.member_a)
      |> get("/analytics?org=#{ctx.org_a}")
      |> html_response(200)

    assert own =~ ">#{@own_signup}<",
           "the member's own org must be served, not an empty page"
  end

  # ==========================================================================
  # the on_mount tenant gate is load-bearing (unauthenticated → halted, never served)
  # ==========================================================================

  test "an UNAUTHENTICATED ?org= dead render is REFUSED (302 → /login), never served", ctx do
    SecurityHost.arm!()

    conn = get(build_conn(), "/analytics?org=#{ctx.org_b}")

    assert conn.status == 302,
           "an armed, unauthenticated tenant analytics dead render must not render"

    assert redirected_to(conn) == "/login"

    body = response(conn, 302)
    refute body =~ "#{@foreign_signup}"
    refute body =~ "funnel-table"
  end
end
