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

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:put_root_layout, html: {PawChartWeb.Layouts, :root})
    plug(:protect_from_forgery)
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
    samen_module_routes(:crm, PawChart.Crm,
      repo: PawChart.Repo,
      labels: %{
        title: "Happy Paws Clinic",
        glyph: "V",
        crm_logo_style: "background:linear-gradient(150deg,#0A6E9E,#1A8DC5)",
        crumb_root: "PawChart",
        user_name: "Clinic Staff",
        user_role: "veterinarian"
      }
    )

    # 2. Billing — clinic subscription billing (mounts AS-IS, no reshape).
    samen_module_routes(:billing, PawChart.Billing,
      repo: PawChart.Repo,
      labels: %{
        title: "Happy Paws Clinic",
        glyph: "V",
        crumb_root: "PawChart"
      }
    )

    # 3. Support — clinics file tickets with the platform (the operator plane).
    samen_module_routes(:support, PawChart.Support,
      repo: PawChart.Repo,
      labels: %{
        title: "Happy Paws Clinic",
        glyph: "V",
        crumb_root: "PawChart"
      }
    )

    # 3b. Work (F1 / ADR-041 §3, T43) — internal follow-up/reminder tasks (task
    #     inbox/detail + project list). Zero CRM contact.
    samen_module_routes(:work, PawChart.Work,
      repo: PawChart.Repo,
      labels: %{
        title: "Happy Paws Clinic",
        glyph: "V",
        crumb_root: "PawChart"
      }
    )

    # 4. Marketing — clinic outreach (wellness reminders, referral thank-yous). The SECOND
    #    vertical's proof of the framework outreach/consent surface: mounts the samen_core
    #    Marketing scope with ZERO PawChart LiveView code. The `:crm_namespace` label wires
    #    the Leads lens over `PawChart.Crm.Person` (same posture as Driftwood).
    samen_module_routes(:marketing, PawChart.Marketing,
      repo: PawChart.Repo,
      labels: %{
        title: "Happy Paws Clinic",
        glyph: "V",
        crumb_root: "PawChart",
        crm_namespace: PawChart.Crm
      }
    )

    # 5. Notifications (WS-A A4/A5) — the framework inbox (+ /notifications/settings),
    #    mounted over PawChart's Primitives mount in ONE line. The sidebar
    #    "Notifications" nav item the framework `module_nav/1` already renders now
    #    resolves. Realtime rides `PawChart.PubSub` (id-only envelopes).
    samen_notifications_routes(:notifications, PawChart.Primitives,
      repo: PawChart.Repo,
      labels: %{
        title: "Happy Paws Clinic",
        glyph: "V",
        crumb_root: "PawChart",
        pubsub: PawChart.PubSub
      }
    )

    # WS-E E7.1 — the framework end-user surfaces, mounted over PawChart's EXISTING
    # namespaces at ≈0 authored LOC (the leverage guard, §3). Three one-liners; zero
    # PawChart LiveView/engine code. The SECOND vertical's proof that files/search/CSV
    # inherit framework-first exactly as CRM/Billing/Support did.

    # 6. Files (ADR-026) — upload + preview + plane-gated byte-serve over PawChart's
    #    Primitives mount (`PawChart.Primitives.File`, abbrev `vfl`).
    samen_files_routes(:files, PawChart.Primitives,
      repo: PawChart.Repo,
      labels: %{title: "Happy Paws Clinic", glyph: "V", crumb_root: "PawChart"}
    )

    # 7. CSV (ADR-028) — per-plane-masked export + governed import over PawChart's CRM
    #    domain (`/csv/*/:resource` resolves deny-by-default onto PawChart.Crm resources).
    samen_csv_routes(:csv, PawChart.Crm,
      repo: PawChart.Repo,
      labels: %{title: "Happy Paws Clinic", glyph: "V", crumb_root: "PawChart"}
    )

    # 7a. ICS (F2, spec §F2/§F8 c8) — per-plane-masked `.ics` calendar export over
    #     PawChart's Calendar domain (`PawChart.Calendar.Event`, abbrev `pce`).
    samen_ics_routes(:ics, PawChart.Calendar, repo: PawChart.Repo)

    # 8. Search (ADR-027) — the ⌘K/per-list search page over the KERNEL `Samen.Search`
    #    engine, mounted over `PawChart.Primitives.{File,SearchIndex}` (`vfl`/`vsh`). The
    #    engine builds its tsvector at QUERY time from registered NON-PII columns, so
    #    search is correct without the observability trigger migration (E4-P2 follow-on:
    #    a per-abbrev `vfl_file` tsvector trigger/GIN index if a host registers at scale).
    samen_search_routes(:search, PawChart.Primitives,
      repo: PawChart.Repo,
      labels: %{title: "Happy Paws Clinic", glyph: "V", crumb_root: "PawChart"}
    )

    # Settings (ADR-029) is NOT mounted here: `samen_settings_routes` requires a mounted
    # IDENTITY namespace (`User`/`ApiKey`/`Membership`). As of T157 PawChart DOES materialize an
    # Identity scope — but only on the OPERATOR namespace (`PawChart.Operator`, the SaaS's own
    # book of business), NOT on a tenant clinic. The tenant self-serve settings surface still has
    # no tenant Identity mount, so it stays unmounted (honest boundary, docs/gate-ws-e.md).
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
