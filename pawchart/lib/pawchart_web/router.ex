defmodule PawChartWeb.Router do
  @moduledoc """
  The PawChart host router (ADR-009 reuse proof).

  The inherited-80% product UI (CRM / Billing / Support) is MOUNTED from `samen_web`
  in THREE lines — `samen_module_routes/3` per scope. PawChart supplies the three host
  facts (namespace + repo) and the framework derives all LiveView routes:

      samen_module_routes(:crm,     PawChart.Crm,     repo: PawChart.Repo)
      samen_module_routes(:billing, PawChart.Billing, repo: PawChart.Repo)
      samen_module_routes(:support, PawChart.Support, repo: PawChart.Repo)

  REUSE MEASUREMENT (the thesis proof):
    * 3 lines mount CRM (3 pages: companies, contacts, pipeline)
    * 3 lines mount Billing (3 pages: overview, invoices, plans)
    * 3 lines mount Support (2 pages: tickets, ticket detail)
    = 3 lines → 8 inherited pages, 0 PawChart LiveView modules authored.

  The vertical 20% (clinical console for the clinic's own patients/pets) would be a
  PawChart-local LiveView — a follow-on scope outside this task. This router is already
  a complete working product UI for the three universal scopes.

  Labels customize the workspace title / glyph for the PawChart brand (the clinic
  sidebar shows "Happy Paws" not the framework default "Workspace").
  """
  use Phoenix.Router
  import Phoenix.LiveView.Router
  import Samen.Web.Router

  # T157 — the current-org data-on-the-mount labels the operator mount + directory read.
  # `operator_authority` is the REAL roster seam (T146/T157): `PawChart.Auth.operator_role/2`
  # resolves the configured `:operator_roster` (a production-shaped resolver), NOT the framework
  # dev fallback. `org_directory` feeds the workspace switcher over the operator org's accounts.
  @operator_authority {PawChart.Auth, :operator_role, [:pawchart]}

  # PP-2 (Batch 5a PAWCHART-SPINE) — the current-org data-on-the-mount labels EVERY PII-bearing
  # tenant/shared mount carries, so pawchart is a properly-authenticated tenant host (mirroring
  # driftwood's `@current_org_labels`). A module attribute (compile-time literal usable inside the
  # `samen_module_routes` macro expansion); every value is session-safe (uuids + MFAs of atoms).
  #
  #   :default_org_id  — the dev default (Happy Paws Clinic), so a page with no ?org renders a
  #     populated org (resolution step 3), never a dead-end.
  #   :org_directory   — the `{mod,fun,args}` the framework switcher + name resolution read
  #     (`PawChart.Directory.orgs/0` → `[{tenant_org_id, name}]` over the operator accounts).
  #   :authn           — `{:app_env, :pawchart, :auth_required?}`: OFF in dev/test (the query-param
  #     convenience identity stays), ON in prod (the actor is derived ONLY from an authenticated
  #     session). This is the label the Batch-1 fail-closed `CurrentOrg.resolve/3` consults; its
  #     PRESENCE is what the tenant-authn coverage guard requires of a real product.
  #   :authorized_orgs — the membership seam `Samen.Web.CurrentOrg` calls to constrain the tenant
  #     actor to the authenticated user's OWN orgs (`PawChart.Auth.authorized_org_ids/1` over REAL
  #     `PawChart.Operator` Membership rows).
  #   :identity_namespace — (PP-5 / Batch 2 TENANT-ROLE) the Identity scope the tenant-plane Billing
  #     surface reads the caller's REAL per-org Membership role from (the `PawChart.Operator.{User,
  #     Membership}` spine — the SAME namespace `samen_settings_routes` mounts). Billing lives in its
  #     own scope namespace (`PawChart.Billing`), which materializes no Membership, so the admin-gated
  #     checkout/portal writes derive the acting role through this sibling seam.
  #   :operator_workspace / :seed_command — the shared cross-plane chrome (switcher return link,
  #     no-org card) derives pawchart's OWN boundary names, not the framework-neutral default.
  #   :host_nav_extra — (PP-4 / Batch 5b CLINIC-SURFACE) the "host supplies DATA, framework
  #     renders it" nav seam (`Samen.UI.host_nav_extra/1`, same pattern as driftwood's freight
  #     "Operations" group): `PawChartWeb.ClinicLive.clinic_nav_data/1` returns the "Clinic" nav
  #     group, so the vet vertical's namesake surface (`/clinic`) is reachable from EVERY framework
  #     module sidebar (CRM/Billing/Support/…), not only its own page. Called as
  #     `apply(mod, fun, args ++ [org_id])`, so `clinic_nav_data/1` is arity 1.
  @current_org_labels %{
    default_org_id: PawChart.Seeds.clinic_org_id(),
    org_directory: {PawChart.Directory, :orgs, []},
    authn: {:app_env, :pawchart, :auth_required?},
    authorized_orgs: {PawChart.Auth, :authorized_org_ids, []},
    identity_namespace: PawChart.Operator,
    host_nav_extra: {PawChartWeb.ClinicLive, :clinic_nav_data, []},
    operator_workspace: "PawChart Ops",
    seed_command: "mix pawchart.seed"
  }

  # PP-7 / PP-4 (Batch 5b CLINIC-SURFACE) — where a fresh pawchart tenant lands after
  # onboarding/login when the login carries no `return_to` (the ordinary cold-login case): the
  # clinic's OWN domain workspace. Batch 5a landed on the inherited CRM dashboard as a placeholder
  # ("a follow-up repoints this at it"); Batch 5b authors the Clinic tenant surface
  # (`PawChartWeb.ClinicLive`, `/clinic`), so a clinic user now lands on their actual patients/pets
  # workspace — the vertical's namesake domain — not the generic CRM page.
  @tenant_landing "/clinic"

  # PP-4 (Batch 5b CLINIC-SURFACE) — the session-safe TENANT-plane mount for the host-local
  # `PawChartWeb.ClinicLive` (`/clinic`). Carries `@current_org_labels` (authn/authorized_orgs/
  # default_org_id/org_directory/host_nav_extra) UNDER the clinic branding, so the Clinic surface is
  # authn-gated + org-scoped BY CONSTRUCTION exactly as the framework CRM mount is — a clinic reaches
  # only its OWN patients/pets. `:crm` kind + `PawChart.Crm` namespace so the inherited sidebar
  # (`module_nav` + the `host_nav_extra` "Clinic" group + the workspace switcher) renders correctly;
  # the Clinic reads target `PawChart.Clinic.{Patient,Pet}` directly (host-local), not the mount's
  # namespace. Its OWN named live_session prevents a foreign socket from `live_redirect`-ing in.
  @clinic_mount Samen.Web.Mount.to_session(
                  Samen.Web.Mount.new(
                    :crm,
                    PawChart.Crm,
                    PawChart.Repo,
                    plane: Samen.Web.Plane.tenant(),
                    labels:
                      Map.merge(@current_org_labels, %{
                        title: "Happy Paws Clinic",
                        glyph: "V",
                        crm_logo_style: "background:linear-gradient(150deg,#0A6E9E,#1A8DC5)",
                        crumb_root: "PawChart",
                        user_name: "Clinic Staff",
                        user_role: "veterinarian"
                      })
                  )
                )

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:put_root_layout, html: {PawChartWeb.Layouts, :root})
    plug(:protect_from_forgery)
    # PP-1/PP-2 (Batch 5a) — the prod auth gate. NO-OP in dev/test (`:auth_required?` false: the
    # query-param convenience identity stays); in prod it redirects unauthenticated requests to
    # /login (auth + health routes exempted). Defense-in-depth over the CurrentOrg actor gate, and
    # the reason the operator plane's AuthGate `/login` redirect target is now a LIVE route.
    plug(PawChartWeb.Auth)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  # T146 / T157 — the OPERATOR control-plane authz pipeline. `Samen.Web.AuthGate` (armed by
  # `:auth_required?`) verifies the authenticated principal HOLDS operator authority via the
  # `:operator_authority` resolver (`config :pawchart, :operator_authority`), redirecting any
  # non-operator to /login BEFORE any operator surface renders. The conn-level twin of the
  # `Samen.Web.Operator.Authz` on_mount the operator macro carries.
  pipeline :require_authenticated_operator do
    plug(Samen.Web.AuthGate, otp_app: :pawchart)
  end

  scope "/", PawChartWeb do
    pipe_through(:browser)

    get("/", PageController, :index)
    get("/healthz", PageController, :healthz)
    get("/readyz", PageController, :readyz)
  end

  # ADR-009 — the inherited-80% product UI, MOUNTED from samen_web.
  # BARE `scope "/"` (no `PawChartWeb` alias): the mounted LiveViews are the framework's
  # own `Samen.Web.*` modules. Aliasing under `PawChartWeb` would wrongly resolve them.
  #
  # Labels brand the sidebar for the vet vertical (clinic-appropriate copy).
  scope "/" do
    pipe_through(:browser)

    # PP-2 (Batch 5a PAWCHART-SPINE) — pawchart is a REAL authenticated tenant host (operator
    # ruling), so it ADOPTS the framework IDENTITY SPINE exactly as driftwood does: three macro
    # calls over pawchart's SOLE Identity mount (`PawChart.Operator` — already materialized for the
    # operator plane, so NO new resources/migrations). This gives pawchart /login, /signup, verify,
    # reset, sessions, invite, 2FA/step-up, onboarding, AND tenant Settings — closing PP-2 (pawchart
    # had NONE of these; the operator AuthGate's /login redirect target was a dead route).

    # ADR-013 §4.3 — the framework SESSION-write endpoint (`GET /session/org/:org_id`), the target
    # of the workspace switcher + the operator "Open account →". Sets the session current org so
    # tenant/shared navigation is sticky without a hand-typed UUID.
    samen_session_routes()

    # ADR-035 §5 — the pre-actor auth surfaces (signup → verify → reset → login → 2fa → invite),
    # mounted over PawChart's sole Identity mount in ONE line (the generated golden-app pattern).
    # `tenant_landing:` gives `Samen.Web.Auth.SessionController.finish_login/5` a real fallback for
    # a login with no `return_to`, so a clinic user logging in cold lands on their workspace.
    samen_auth_routes(namespace: PawChart.Operator, repo: PawChart.Repo, labels: %{tenant_landing: @tenant_landing})

    # ADR-035 §5 A8 — the FIRST-RUN onboarding wizard (`GET /onboarding`): org-naming, plan-selection
    # (honest "no plans configured" empty state), and the T05 teammate-invite step. Same Identity
    # mount as the auth spine. The "You're all set" card's "Go to your workspace →" CTA reads the
    # SAME `tenant_landing:` label so onboarding does not dead-end.
    samen_onboarding_routes(PawChart.Operator, repo: PawChart.Repo, labels: %{tenant_landing: @tenant_landing})

    # WS-F5 F5.1 — the framework `GET /metrics` Prometheus scrape endpoint over
    # `Samen.Metrics.definitions/0`, mounted in ONE line (leverage proof). OFF by
    # default: self-gates to 404 until an operator sets metrics_egress? + adds a
    # reporter dep. Reporter name matches Samen.Observability's default.
    samen_metrics_route(name: :pawchart_prometheus)

    # ADR-044 §3.2/§9.2 (T82 fix round — the ADR §9.3 row (a) two-vertical proof:
    # "driftwood AND pawchart each mount samen_fleet_routes(), build a report from
    # their own substrate, and GET /fleet/health returns a schema-valid,
    # correctly-signed FleetReport for each"). Mode A/B reporting-side routes,
    # zero-config by default (:embedded honesty floor, J5). §9.3's own note that
    # pawchart lacks the operator plane (T157) does NOT block this: this macro
    # is a plain controller pipeline with no operator-plane dependency (§9.3),
    # so pawchart can report without mounting the operator plane at all. See
    # `pawchart/test/fleet_wire_test.exs`.
    samen_fleet_routes(otp_app: :pawchart)

    # 1. CRM — clinic contacts, referring vets, labs, vendors.
    #    PP-2 (Batch 5a) — `@current_org_labels` (authn/authorized_orgs/identity_namespace/
    #    default_org_id/org_directory/…) is merged UNDER the cosmetic branding labels (branding
    #    wins on any name collision), so this PII-bearing tenant mount is a properly-gated real
    #    product surface: armed → the authenticated-authorized path; dev/test → the ?org= convenience.
    samen_module_routes(:crm, PawChart.Crm,
      repo: PawChart.Repo,
      labels:
        Map.merge(@current_org_labels, %{
          title: "Happy Paws Clinic",
          glyph: "V",
          crm_logo_style: "background:linear-gradient(150deg,#0A6E9E,#1A8DC5)",
          crumb_root: "PawChart",
          user_name: "Clinic Staff",
          user_role: "veterinarian"
        })
    )

    # 2. Billing — clinic subscription billing (mounts AS-IS, no reshape). The `:identity_namespace`
    #    label (in `@current_org_labels`) lets the tenant-plane Billing surface resolve the caller's
    #    REAL per-org Membership role, so a clinic ADMIN can subscribe/manage-payment and a MEMBER
    #    cannot (PP-5 / Batch 2 role gate, now ACTIVE on pawchart).
    samen_module_routes(:billing, PawChart.Billing,
      repo: PawChart.Repo,
      labels:
        Map.merge(@current_org_labels, %{
          title: "Happy Paws Clinic",
          glyph: "V",
          crumb_root: "PawChart"
        })
    )

    # 3. Support — clinics file tickets with the platform (the operator plane).
    samen_module_routes(:support, PawChart.Support,
      repo: PawChart.Repo,
      labels:
        Map.merge(@current_org_labels, %{
          title: "Happy Paws Clinic",
          glyph: "V",
          crumb_root: "PawChart"
        })
    )

    # 3b. Work (F1 / ADR-041 §3, T43) — internal follow-up/reminder tasks (task
    #     inbox/detail + project list). Zero CRM contact.
    samen_module_routes(:work, PawChart.Work,
      repo: PawChart.Repo,
      labels:
        Map.merge(@current_org_labels, %{
          title: "Happy Paws Clinic",
          glyph: "V",
          crumb_root: "PawChart"
        })
    )

    # 4. Marketing — clinic outreach (wellness reminders, referral thank-yous). The SECOND
    #    vertical's proof of the framework outreach/consent surface: mounts the samen_core
    #    Marketing scope with ZERO PawChart LiveView code. The `:crm_namespace` label wires
    #    the Leads lens over `PawChart.Crm.Person` (same posture as Driftwood).
    samen_module_routes(:marketing, PawChart.Marketing,
      repo: PawChart.Repo,
      labels:
        Map.merge(@current_org_labels, %{
          title: "Happy Paws Clinic",
          glyph: "V",
          crumb_root: "PawChart",
          crm_namespace: PawChart.Crm
        })
    )

    # 5. Notifications (WS-A A4/A5) — the framework inbox (+ /notifications/settings),
    #    mounted over PawChart's Primitives mount in ONE line. The sidebar
    #    "Notifications" nav item the framework `module_nav/1` already renders now
    #    resolves. Realtime rides `PawChart.PubSub` (id-only envelopes).
    samen_notifications_routes(:notifications, PawChart.Primitives,
      repo: PawChart.Repo,
      labels:
        Map.merge(@current_org_labels, %{
          title: "Happy Paws Clinic",
          glyph: "V",
          crumb_root: "PawChart",
          pubsub: PawChart.PubSub
        })
    )

    # WS-E E7.1 — the framework end-user surfaces, mounted over PawChart's EXISTING
    # namespaces at ≈0 authored LOC (the leverage guard, §3). Three one-liners; zero
    # PawChart LiveView/engine code. The SECOND vertical's proof that files/search/CSV
    # inherit framework-first exactly as CRM/Billing/Support did.

    # 6. Files (ADR-026) — upload + preview + plane-gated byte-serve over PawChart's
    #    Primitives mount (`PawChart.Primitives.File`, abbrev `vfl`).
    samen_files_routes(:files, PawChart.Primitives,
      repo: PawChart.Repo,
      labels: Map.merge(@current_org_labels, %{title: "Happy Paws Clinic", glyph: "V", crumb_root: "PawChart"})
    )

    # 7. CSV (ADR-028) — per-plane-masked export + governed import over PawChart's CRM
    #    domain (`/csv/*/:resource` resolves deny-by-default onto PawChart.Crm resources).
    samen_csv_routes(:csv, PawChart.Crm,
      repo: PawChart.Repo,
      labels: Map.merge(@current_org_labels, %{title: "Happy Paws Clinic", glyph: "V", crumb_root: "PawChart"})
    )

    # 7a. ICS (F2, spec §F2/§F8 c8) — per-plane-masked `.ics` calendar export over
    #     PawChart's Calendar domain (`PawChart.Calendar.Event`, abbrev `pce`).
    samen_ics_routes(:ics, PawChart.Calendar, repo: PawChart.Repo, labels: @current_org_labels)

    # 8. Search (ADR-027) — the ⌘K/per-list search page over the KERNEL `Samen.Search`
    #    engine, mounted over `PawChart.Primitives.{File,SearchIndex}` (`vfl`/`vsh`). The
    #    engine builds its tsvector at QUERY time from registered NON-PII columns, so
    #    search is correct without the observability trigger migration (E4-P2 follow-on:
    #    a per-abbrev `vfl_file` tsvector trigger/GIN index if a host registers at scale).
    samen_search_routes(:search, PawChart.Primitives,
      repo: PawChart.Repo,
      labels: Map.merge(@current_org_labels, %{title: "Happy Paws Clinic", glyph: "V", crumb_root: "PawChart"})
    )

    # WS-E E5 (ADR-029) — the framework SELF-SERVE SETTINGS surface (Profile · API keys ·
    # Security), mounted over PawChart's Identity namespace (`PawChart.Operator.{User,ApiKey,
    # Membership}`) in ONE line. PP-2 (Batch 5a): pawchart NOW mounts the tenant Identity spine
    # (`samen_auth_routes`/`samen_onboarding_routes` above), so the earlier "no tenant Identity
    # mount → settings stays unmounted (honest boundary)" caveat is retired — a clinic can reach
    # tenant Settings exactly as driftwood does. `spine_totp`/`spine_sessions` are left at their
    # honest-placeholder defaults (the same posture driftwood ships).
    samen_settings_routes(:settings, PawChart.Operator,
      repo: PawChart.Repo,
      labels: @current_org_labels
    )
  end

  # PP-4 (Batch 5b CLINIC-SURFACE) — the vertical 20%: the clinic's OWN tenant workspace over its
  # namesake domain (`PawChart.Clinic.{Patient,Pet}`). Aliased under `PawChartWeb` because
  # `ClinicLive` is a host-local LiveView (the resource SHAPE is vet-specific — the owner + their
  # pets — even though every MECHANISM it uses is inherited framework substrate). On the `:browser`
  # pipe (the prod `PawChartWeb.Auth` gate + the `@current_org_labels` authn seam apply), TENANT
  # plane. Its own named live_session carries the tenant mount so the current-org + org-scope
  # resolution runs on every mount — the clinic reads ONLY its own patients/pets.
  scope "/", PawChartWeb do
    pipe_through(:browser)

    # B-SEC / S1 — the clinic console carries the SAME framework tenant gate the mounted
    # `samen_*_routes` surfaces carry: `{Samen.Web.TenantAuthz, :require_tenant}` halts an
    # armed, unauthenticated request before `handle_params/3` can run on the dead render, and
    # pins the org authority so a client `?org=` can only select among the principal's
    # authorized orgs (`Samen.Web.CurrentOrg.reresolve/2` in `ClinicLive.handle_params/3`).
    live_session :pawchart_clinic,
      on_mount: [{Samen.Web.TenantAuthz, :require_tenant}],
      session: %{"samen_mount" => @clinic_mount} do
      live("/clinic", ClinicLive)
    end
  end

  # ============================================================================
  # T157 — the OPERATOR / SaaS-company control plane, ADOPTED at ≈0 authored LOC.
  # PawChart mounts the framework operator plane by MOUNT (this scope + a roster), NOT by
  # re-implementing operator-plane behavior. The framework's OWN `Samen.Web.Operator.*`
  # LiveViews render pawchart's (vet-shaped) book of business — the second-vertical proof.
  # ============================================================================

  # T146 (round 3) — the session-safe mount for the operator IMPERSONATION live_session. Its ONLY
  # load-bearing job is to carry the `:operator_authority` seam so the `Samen.Web.Operator.Authz`
  # `:require_operator` on_mount can resolve operator authority on the WEBSOCKET mount (the conn
  # pipeline gates only the HTTP dead-render). Its OWN named live_session prevents a tenant socket
  # from `live_redirect`-ing in with no gate running.
  @impersonate_mount Samen.Web.Mount.to_session(
                       Samen.Web.Mount.new(
                         :operator,
                         PawChart.Operator,
                         PawChart.Repo,
                         plane: Samen.Web.Plane.tenant(),
                         labels: %{operator_authority: {PawChart.Auth, :operator_role, [:pawchart]}}
                       )
                     )

  # ADR-010 — the OPERATOR workspace, mounted from samen_web in ONE macro call over PawChart's
  # operator namespace (`PawChart.Operator` — its FIRST Identity mount; accounts ARE tenant orgs).
  # Accounts · Platform billing · Revenue · Desk. Every route rides the `:require_operator`
  # on_mount (a tenant-user session can never reach `/operator/*`) AND the conn-level AuthGate.
  scope "/" do
    pipe_through([:browser, :require_authenticated_operator])

    samen_operator_routes(PawChart.Operator,
      repo: PawChart.Repo,
      operator_org_id: "0f000000-0000-4000-8000-0000000000c1",
      include_aggregate: false,
      labels: %{
        operator_workspace: "PawChart Ops",
        operator_glyph: "P",
        # ADR-013 §5.2 — the operator Accounts "Open account →" two-grade drill-in:
        #   :tenant_landing   — where act-as (clear) lands (the clinic landing),
        #   :impersonate_path — the masked operator-plane impersonation surface (below).
        tenant_landing: "/",
        impersonate_path: "/operator/impersonate",
        # T146 / T157 — the REAL operator-ROLE authority seam. `PawChart.Auth.operator_role/2`
        # derives authority from the AUTHENTICATED PRINCIPAL via the configured `:operator_roster`
        # (NOT the framework dev fallback) and FAILS CLOSED for any non-operator.
        operator_authority: @operator_authority,
        # WS-B — the platform flag admin namespace seam.
        flags_namespace: PawChart.Primitives
      }
    )
  end

  # T146 — the pawchart-LOCAL masked impersonation console (vet-shaped: clinic patient/owner
  # roster), in its OWN named live_session carrying the operator-ROLE on_mount. Aliased under
  # `PawChartWeb` because `OperatorImpersonationLive` is a host-local LiveView (the vertical 20%).
  scope "/", PawChartWeb do
    pipe_through([:browser, :require_authenticated_operator])

    live_session :pawchart_operator_impersonate,
      on_mount: [{Samen.Web.Operator.Authz, :require_operator}],
      session: %{"samen_mount" => @impersonate_mount} do
      live("/operator/impersonate", OperatorImpersonationLive)
    end
  end

  # T142 (folded into T157, per operator ruling) — the AI-plane MCP server endpoint (ADR-043 §9),
  # mounted in ONE line with a REAL constant-time `:actor_resolver`. `PawChartWeb.Api.McpKeyResolver`
  # digests the bearer token (SHA-256) and confirms it against the stored per-operator token digest
  # with `Plug.Crypto.secure_compare/2`, returning a `%Samen.Scope{}` scoped to the token owner's org
  # (org-A token cannot reach org-B data). Bare `forward` (no browser session/CSRF) — auth is the
  # bearer token alone; unauth / forged / revoked ⇒ 401 (proven by the e2e auth test).
  scope "/" do
    pipe_through(:api)

    samen_mcp_route(
      actor_resolver: {PawChartWeb.Api.McpKeyResolver, :resolve_scope, []},
      tool_opts: [domains: [PawChart.Crm], repo: PawChart.Repo]
    )
  end
end
