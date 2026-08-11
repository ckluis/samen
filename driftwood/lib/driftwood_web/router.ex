defmodule DriftwoodWeb.Router do
  @moduledoc """
  The Driftwood host router (T5.3; rewired to the framework per ADR-009).

  The inherited-80% product UI (CRM / Billing / Support + the operator aggregate) is no
  longer driftwood-local: it is MOUNTED from `samen_web`. Driftwood supplies the three
  host facts (namespace + repo) and the framework derives everything else:

    * TENANT plane — the org acts over its OWN data (PII in the clear):
      * `/broker` (`DriftwoodWeb.BrokerLive`) — the freight console (the vertical 20%).
      * CRM / Billing / Support — mounted via `samen_module_routes` over the inherited
        `Driftwood.{Crm,Billing,Support}` scope namespaces (`Samen.Web.{CRM,Billing,Support}`
        LiveViews). PII on contacts / customers / agents / message bodies is plane-resolved
        through `Samen.Api.PiiResolution`: tenant plane in the clear.
    * OPERATOR plane:
      * `/operator/impersonate` (`DriftwoodWeb.OperatorImpersonationLive`) — masked
        impersonation over ONE tenant's freight resources (PII ••••), plus the
        second-party reveal control. Freight-shaped, so it stays driftwood-local.
      * `/operator/aggregate` (`Samen.Web.Operator.AggregateLive`) — the framework
        token-blind cross-tenant dashboard, fed Driftwood's MRR / load-volume projection
        via the `aggregate_loader:` MFA on the mount labels (NO PII by construction).

  `/` is a plain landing/health page (the boot curl check). `/healthz` returns `ok`. The
  org/operator identity is passed as query params for the LOCAL dogfood — a real deploy
  derives them from an authenticated session (see docs/driftwood-dogfood.md).
  """
  use Phoenix.Router
  import Phoenix.LiveView.Router
  import Samen.Web.Router

  # ADR-013 §4.4 — the current-org data-on-the-mount labels shared by every tenant/shared mount:
  #   :default_org_id — the sensible dev default (Blue Ridge Logistics), so a page with no ?org
  #     renders a populated org (resolution step 3), never a dead-end;
  #   :org_directory  — the `{mod,fun,args}` the framework switcher + name resolution read
  #     (`Driftwood.Directory.orgs/0` → `[{tenant_org_id, name}]` over the operator accounts).
  # A module attribute (not a function) so it is a compile-time literal usable inside the
  # `samen_module_routes` macro expansion; both values are session-safe (a uuid + an MFA of atoms).
  # F2 (ADR-031) — the launch AUTH gate seams every tenant/shared mount carries:
  #   :authn          — `{:app_env, :driftwood, :auth_required?}`: OFF in dev/test (the
  #     query-param convenience identity stays), ON in prod (the actor is derived only from
  #     an authenticated session — see docs/launch-checklist.md).
  #   :authorized_orgs — the membership seam `Samen.Web.CurrentOrg` calls to constrain the
  #     tenant actor to the authenticated user's OWN orgs (`{mod, fun, args}`, user_id
  #     appended). Driftwood's reference sources it from `Driftwood.Auth`; a real deploy
  #     points it at `Identity.Membership` rows.
  # T116/P9-F2 — the operator-plane label the SHARED cross-plane chrome (workspace switcher
  # return link, acting-as crossing marker, no-org card) derives instead of the old hardcoded
  # "Driftwood Ops"/"mix driftwood.seed" framework leak. Data on the mount, not code: driftwood
  # keeps its own boundary names; every other host now labels its OWN boundary (neutral default).
  @current_org_labels %{
    default_org_id: Driftwood.Seeds.blue_ridge_org_id(),
    org_directory: {Driftwood.Directory, :orgs, []},
    authn: {:app_env, :driftwood, :auth_required?},
    authorized_orgs: {Driftwood.Auth, :authorized_org_ids, []},
    # PP-5 (Batch 2 TENANT-ROLE): the Identity scope the tenant-plane Billing surface reads
    # the caller's REAL per-org Membership role from (the `Driftwood.Operator.{User,Membership}`
    # spine — the SAME namespace `samen_settings_routes` mounts). Billing lives in its own
    # scope namespace (`Driftwood.Billing`), which materializes no Membership, so the
    # admin-gated checkout/portal writes derive the acting role through this sibling seam.
    identity_namespace: Driftwood.Operator,
    operator_workspace: "Driftwood Ops",
    seed_command: "mix driftwood.seed",
    # PP-10 (Batch 3 NAV-REACHABILITY): the freight "Operations" nav group (Dispatch board /
    # Loads / Drivers / Settlements) previously rendered ONLY on `BrokerLive`'s own bespoke
    # sidebar — it vanished the instant a tenant navigated to CRM/Billing/Support/Marketing.
    # `:host_nav_extra` is the SAME "host supplies DATA, framework renders it" pattern as
    # `:object_cards`/`:aggregate_loader` — every framework module sidebar now renders this
    # group identically (via `Samen.UI.host_nav_extra/1` in `module_nav/1`'s `:extra` slot),
    # so Operations is reachable from every tenant page, not only `/broker`.
    host_nav_extra: {DriftwoodWeb.BrokerLive, :operations_nav_data, []}
  }

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:put_root_layout, html: {DriftwoodWeb.Layouts, :root})
    plug(:protect_from_forgery)
    # F2 (ADR-031) — the prod auth gate. NO-OP in dev/test (`:auth_required?` false: the
    # query-param convenience identity stays); in prod it redirects unauthenticated requests
    # to /login (auth + health routes exempted). Defense-in-depth over the CurrentOrg actor gate.
    plug(DriftwoodWeb.Auth)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  # T146 — the OPERATOR control-plane authz pipeline. `Samen.Web.AuthGate` (armed by
  # `:auth_required?`) verifies the authenticated principal actually HOLDS operator authority
  # via the `:operator_authority` resolver (`config :driftwood, :operator_authority`), redirecting
  # any non-operator (a plain tenant user, anonymous) to /login BEFORE any operator surface
  # renders. This is the conn-level twin of the `Samen.Web.Operator.Authz` on_mount the operator
  # MACRO carries — and, unlike the macro's on_mount, it gates EVERY route in a scope piped
  # through it, INCLUDING operator surfaces mounted OUTSIDE `samen_operator_routes/2` (the
  # aggregate, the freight-shaped impersonation console, the operator desk-chat). Every
  # `/operator/*` scope below pipes `[:browser, :require_authenticated_operator]`, so no operator
  # surface is reachable by a tenant user. Driftwood's own reference gate (the driftwood
  # `DriftwoodWeb.Auth` plug on `:browser`) authenticates ONLY; this adds the ROLE check.
  pipeline :require_authenticated_operator do
    plug(Samen.Web.AuthGate, otp_app: :driftwood)
  end

  # F1 (Gate-5 carry) — the versioned public API surface. `forward` sends `/api/v1/*` to
  # the AshJsonApi endpoint (key-auth → the two key classes → the generated JSON:API
  # router over `Driftwood.Freight`). The declared route `/drivers` is reached at
  # `/api/v1/drivers` externally — the stable public contract (doc §external-surface
  # "explicitly versioned, URL-namespaced, e.g. /api/v1").
  forward("/api/v1", DriftwoodWeb.Api.Endpoint)

  scope "/", DriftwoodWeb do
    pipe_through(:browser)

    get("/", PageController, :index)
    get("/healthz", PageController, :healthz)
    get("/readyz", PageController, :readyz)

    # T148 — the BYO-auth login/logout surface is NO LONGER driftwood-local. The framework
    # IDENTITY SPINE (`samen_auth_routes` in the bare tenant scope below) now OWNS `/login` +
    # `/logout` (the generated golden-app pattern — `samen_core/.../router.ex.golden`), so
    # signup → verify → login → onboarding is ONE coherent framework flow over
    # `Driftwood.Operator`'s Ash Identity resources. `DriftwoodWeb.AuthController` +
    # `Driftwood.Auth`'s verifier remain the BYO REFERENCE (Driftwood.Auth is still the
    # `operator_role`/`authorized_org_ids` seam), but no route points at the controller — the
    # framework `Samen.Web.Auth.SessionController` is the login write. The `DriftwoodWeb.Auth`
    # prod gate still redirects unauthenticated tenants to `/login` (now the framework LoginLive).

    # The freight vertical 20% (stays driftwood-local — freight-shaped resources).
    live("/broker", BrokerLive)
    # NOTE (T146): `/operator/impersonate` was moved OUT of this bare `:browser` scope into the
    # operator-authz scope below — it is an OPERATOR surface and must be role-gated, not merely
    # authenticated. Mounting it here (authentication only) was the verifier-found bypass.
  end

  # ADR-009 — the inherited-80% product UI, MOUNTED from samen_web. Three one-liners
  # mount all 11 inherited CRM/Billing/Support pages over Driftwood's materialized scope
  # resources (`Driftwood.Crm.*` / `Driftwood.Billing.*` / `Driftwood.Support.*`). The
  # `Samen.Web.Mount` struct is built from the namespace + repo and threaded through a
  # `live_session`; NO driftwood LiveView code renders these pages anymore.
  #
  # NOTE: a BARE `scope "/"` (no `DriftwoodWeb` alias) — the mounted LiveViews are the
  # framework's OWN fully-qualified `Samen.Web.*` modules, so aliasing under `DriftwoodWeb`
  # would (wrongly) resolve them to `DriftwoodWeb.Samen.Web.*`.
  scope "/" do
    pipe_through(:browser)

    # ADR-013 §4.3 — the framework SESSION-write endpoint (`GET /session/org/:org_id`), the
    # target of the workspace switcher + the operator "Open account →". Sets the session current
    # org so tenant/shared navigation is sticky without a hand-typed UUID.
    samen_session_routes()

    # T148 / ADR-035 §5 A1–A5/A7 — the framework IDENTITY-SPINE pre-actor auth surfaces
    # (signup → verify → reset → login → 2fa → invite), mounted over Driftwood's sole Identity
    # mount (`Driftwood.Operator`) in ONE line — EXACTLY the generated golden router pattern
    # (`samen_auth_routes(namespace: Acme.Operator, repo: Acme.Repo)`). Pre-actor PUBLIC (no
    # plane/org data). These are TENANT-plane surfaces, NOT operator — they stay OUT of the
    # `:require_authenticated_operator` scopes below. The pre-actor paths (`/signup`, `/verify/:t`,
    # `/reset[/:t]`, `/2fa`, `/invite/:t`) are exempted from the `DriftwoodWeb.Auth` prod gate
    # (see its `@exempt_*`), so a NEW user can reach signup/verify even when auth is armed.
    #
    # PP-7 (Batch 3 NAV-REACHABILITY) — `tenant_landing: "/broker"` is the SAME string the
    # operator scope's own `tenant_landing:` label already names below (ADR-013 §5.2's "Open
    # account →" drill-in target); wiring it here too gives `Samen.Web.Auth.SessionController`'s
    # `finish_login/5` a real fallback for a login with no `return_to` (the ordinary case), so a
    # tenant logging in cold lands on the freight console instead of falling through to the
    # framework-neutral `"/"` (which on this host redirected unconditionally to the operator
    # console, W3 BLOCKER-1).
    samen_auth_routes(namespace: Driftwood.Operator, repo: Driftwood.Repo, labels: %{tenant_landing: "/broker"})

    # T148 / ADR-035 §5 A8 — the FIRST-RUN onboarding wizard (`GET /onboarding`): org-naming,
    # plan-selection (the honest "no plans configured" empty state — no `:plan_labels` wired
    # until billing self-serve), and the T05 teammate-invite step. Same Identity mount as the
    # auth spine (golden: `samen_onboarding_routes(Acme.Operator, repo: Acme.Repo)`). Post-login
    # (needs an actor), so it is deliberately NOT gate-exempt — a signed-in session passes.
    #
    # PP-7 — same `tenant_landing: "/broker"` label, read by `WizardLive`'s "You're all set"
    # card (the "Go to your workspace →" CTA) once onboarding is complete.
    samen_onboarding_routes(Driftwood.Operator, repo: Driftwood.Repo, labels: %{tenant_landing: "/broker"})

    # WS-F5 F5.1 — the framework `GET /metrics` Prometheus scrape endpoint over
    # `Samen.Metrics.definitions/0`, mounted in ONE line (leverage proof). OFF by
    # default: the route self-gates to 404 until an operator sets metrics_egress?
    # (config) + adds a reporter dep. Reporter name matches Samen.Observability's
    # default (`:driftwood_prometheus`).
    samen_metrics_route(name: :driftwood_prometheus)

    # ADR-044 §3.2/§9.2 (T82 fix round — the ADR §9.3 row (a) two-vertical proof:
    # "driftwood AND pawchart each mount samen_fleet_routes(), build a report from
    # their own substrate, and GET /fleet/health returns a schema-valid,
    # correctly-signed FleetReport for each"). Mode A/B reporting-side routes,
    # zero-config by default (:embedded honesty floor, J5) — the SAME two lines
    # `samen_web`'s own test host uses. See `driftwood/test/fleet_wire_test.exs`.
    samen_fleet_routes(otp_app: :driftwood)

    # ADR-013 §4.4/§4.6 — the current-org data-on-the-mount seams every tenant/shared mount
    # carries: `default_org_id` (dev default → Blue Ridge Logistics, so a page with no ?org
    # renders a populated org, not a dead-end) + `org_directory` (the switcher list + the
    # resolved tenant-name header, over `Driftwood.Directory.orgs/0`).
    samen_module_routes(:crm, Driftwood.Crm, repo: Driftwood.Repo, labels: @current_org_labels)
    samen_module_routes(:billing, Driftwood.Billing, repo: Driftwood.Repo, labels: @current_org_labels)
    samen_module_routes(:support, Driftwood.Support, repo: Driftwood.Repo, labels: @current_org_labels)

    # ADR-011 §7 — the Marketing / outreach surface (campaigns · segments · leads), mounted
    # over Driftwood's materialized Marketing scope resources. The `:crm_namespace` label lets
    # the Leads lens read CRM contacts by lifecycle_stage through the same PiiResolution seam.
    samen_module_routes(:marketing, Driftwood.Marketing,
      repo: Driftwood.Repo,
      labels: Map.put(@current_org_labels, :crm_namespace, Driftwood.Crm)
    )

    # WS-A A4/A5 — the framework NOTIFICATIONS inbox (+ /notifications/settings), mounted
    # over Driftwood's Primitives mount (`Driftwood.Primitives.{Notification,
    # NotificationPreference}`) in ONE line. The sidebar "Notifications" nav item the
    # framework `module_nav/1` already renders now resolves (it was a dead link before this
    # mount). Realtime rides `Driftwood.PubSub` (id-only envelopes; re-read-per-scope).
    samen_notifications_routes(:notifications, Driftwood.Primitives,
      repo: Driftwood.Repo,
      labels: Map.put(@current_org_labels, :pubsub, Driftwood.PubSub)
    )

    # WS-E E2 (ADR-026) — the framework FILES surface (upload + preview + plane-gated
    # byte-serve), mounted over Driftwood's Primitives mount (`Driftwood.Primitives.File`)
    # in ONE line. GATE PROBE (E2.3): mounted here to prove the ≈0-LOC macro mounts on a
    # real host router + browser pipeline. Remove if not adopting the files surface.
    samen_files_routes(:files, Driftwood.Primitives,
      repo: Driftwood.Repo,
      labels: @current_org_labels
    )

    # WS-E E3 (ADR-028) — the framework CSV surface (import LiveView + per-plane-masked
    # export download), mounted over Driftwood's CRM domain in ONE line. GATE PROBE
    # (E3.5): /csv/export/:resource + /csv/import/:resource resolve deny-by-default onto
    # Driftwood.Crm's registered resources only.
    samen_csv_routes(:csv, Driftwood.Crm,
      repo: Driftwood.Repo,
      labels: @current_org_labels
    )

    # WS-E E4 (ADR-027) — the framework ⌘K SEARCH surface, mounted over Driftwood's
    # Primitives mount (`Driftwood.Primitives.{File,SearchIndex}`) in ONE line. GATE
    # PROBE (E4.4): the KERNEL `Samen.Search` engine returns ranked, org-scoped,
    # per-plane-masked results over whatever the org registered in `SearchIndex` — zero
    # authored search LiveViews.
    samen_search_routes(:search, Driftwood.Primitives,
      repo: Driftwood.Repo,
      labels: @current_org_labels
    )

    # ADR-039 §12 done-criterion 4 / T118 — the tenant AUTOMATION (workflow)
    # builder, mounted over Driftwood's Automation domain (`Driftwood.Automation`,
    # T39/T118's first vertical adoption) in ONE line. Tenant plane ONLY — the
    # macro accepts no `:plane` option (INV-2; see
    # `Samen.Web.Router.samen_automation_routes/3`'s moduledoc). The operator-plane
    # counterpart (run log + kill-switch) is the separate, already-mounted
    # `Samen.Web.Operator.AutomationHealthLive` above (`samen_operator_routes/2`).
    samen_automation_routes(:automation, Driftwood.Automation,
      repo: Driftwood.Repo,
      labels: @current_org_labels
    )

    # WS-E E5 (ADR-029) — the framework SELF-SERVE SETTINGS surface (Profile · API keys ·
    # Security), mounted over Driftwood's Identity namespace (`Driftwood.Operator.{User,
    # ApiKey,Membership}`) in ONE line. GATE PROBE (E5.4): the `samen_settings_routes`
    # macro mounts all three surfaces at ≈0 authored LOC — profile self-edit routes
    # through the vault chokepoint, API keys are show-once/digest-only, Security is
    # read-only and honest about the host-auth boundary.
    samen_settings_routes(:settings, Driftwood.Operator,
      repo: Driftwood.Repo,
      labels: @current_org_labels
    )

    # ADR-012 — the FLAGSHIP cross-plane realtime CHAT, TENANT plane (the org's own chat
    # console — bodies + participant identities in the clear). The `:object_cards` label
    # registers Driftwood's bespoke `freight.driver` unfurl card (the vertical override seam);
    # every OTHER catalogued resource (`crm.person`, `support.ticket`, …) unfurls via the
    # framework default/first-class cards with zero cards written. `:pubsub` names the running
    # PubSub server for the realtime path.
    samen_chat_routes(:chat, Driftwood.Chat,
      repo: Driftwood.Repo,
      labels:
        Map.merge(@current_org_labels, %{
          title: "Blue Ridge Logistics",
          crumb_root: "Blue Ridge Logistics",
          pubsub: Driftwood.PubSub,
          object_cards: %{"freight.driver" => DriftwoodWeb.Chat.DriverCard}
        })
    )

    # NOTE (T146): the OPERATOR-DESK chat (`/operator/desk-chat`) was moved OUT of this bare
    # `:browser` (tenant) scope into the operator-authz scope below — it is an operator surface
    # (masked cross-plane threads) and must be role-gated, not merely authenticated.
  end

  # ADR-009 §5.3(2) — the framework OPERATOR aggregate plane, mounted over Driftwood's
  # token-blind aggregate projection. The aggregate PROJECTION is vertical-shaped (freight
  # lanes / tiers), so — unlike CRM/Billing/Support — the host supplies its data via an
  # `aggregate_loader:` MFA on the mount labels; the framework owns the token-blind chrome
  # (banner + `⊘` suppression). This is a plain `live` under a `live_session` carrying the
  # operator-plane mount (the aggregate has no `:crm/:billing/:support` route table).
  # The session-safe mount for the operator aggregate plane. `namespace` points at
  # Driftwood's aggregate domain; the token-blind projection is supplied by the
  # `aggregate_loader:` MFA (Driftwood.OperatorAggregate.load/0) — mapping
  # Driftwood.OperatorDashboard's MRR / load-volume into the framework's generic
  # `%{metrics:, groups:}` shape. Labels carry the operator branding (data, not code).
  # Built here (referencing only compiled external modules) so it is a plain session value.
  @aggregate_mount Samen.Web.Mount.to_session(
                     Samen.Web.Mount.new(
                       :aggregate,
                       Driftwood.Aggregate,
                       Driftwood.Repo,
                       plane: Samen.Web.Plane.operator("driftwood-operator", nil),
                       labels: %{
                         operator_title: "Portfolio",
                         operator_workspace: "Driftwood Ops",
                         # T146 — the operator-ROLE authority seam, so the aggregate is gated by
                         # the `Samen.Web.Operator.Authz` on_mount (below) IN ADDITION TO the
                         # conn-level AuthGate pipeline — defense-in-depth for the real leak
                         # (operator-confidential cross-tenant MRR / load-volume aggregates).
                         operator_authority: {Driftwood.Auth, :operator_role, [:driftwood]},
                         aggregate_loader: {Driftwood.OperatorAggregate, :load, []}
                       }
                     )
                   )

  # T146 (round 3) — the session-safe mount for the operator IMPERSONATION live_session. Its
  # ONLY load-bearing job is to carry the `:operator_authority` seam so the
  # `Samen.Web.Operator.Authz` `:require_operator` on_mount can resolve operator authority on the
  # WEBSOCKET mount (the conn pipeline gates only the HTTP dead-render). Without its OWN named
  # live_session, `/operator/impersonate` fell into the SHARED `:default` session alongside the
  # tenant `/broker` route — a tenant holding a `/broker` socket could `live_redirect` in with no
  # gate running. `OperatorImpersonationLive` reads operator_id/org_id from params/session and
  # ignores this mount; it is present solely for the authz hook.
  @impersonate_mount Samen.Web.Mount.to_session(
                       Samen.Web.Mount.new(
                         :operator,
                         Driftwood.Operator,
                         Driftwood.Repo,
                         plane: Samen.Web.Plane.tenant(),
                         labels: %{operator_authority: {Driftwood.Auth, :operator_role, [:driftwood]}}
                       )
                     )

  # BARE `scope "/"` (see the CRM/Billing/Support note above): the aggregate LiveView is
  # the framework's fully-qualified module.
  scope "/" do
    pipe_through([:browser, :require_authenticated_operator])

    live_session :driftwood_operator_aggregate,
      on_mount: [{Samen.Web.Operator.Authz, :require_operator}],
      session: %{"samen_mount" => @aggregate_mount} do
      live("/operator/aggregate", Samen.Web.Operator.AggregateLive)
    end
  end

  # ADR-010 — the OPERATOR / SaaS-company workspace, mounted from samen_web in ONE line over
  # Driftwood's operator namespace (`Driftwood.Operator` — its FIRST Identity mount; accounts
  # ARE tenant orgs). Accounts · Platform billing · Desk. The operator seat reads the operator
  # org over its OWN book of business on the TENANT plane (the SaaS's own customers — the
  # tenant-admins — CLEAR); drilling into a tenant ("Open account") is the existing masked
  # impersonation path. `:include_aggregate false` — the token-blind aggregate is already
  # mounted above with Driftwood's freight-shaped loader.
  scope "/" do
    pipe_through([:browser, :require_authenticated_operator])

    samen_operator_routes(Driftwood.Operator,
      repo: Driftwood.Repo,
      operator_org_id: "0f000000-0000-4000-8000-0000000000aa",
      include_aggregate: false,
      # ADR-013 §5.2 — the operator Accounts "Open account →" two-grade drill-in:
      #   :tenant_landing   — where act-as (clear) lands (the freight console),
      #   :impersonate_path — the existing masked operator-plane impersonation surface.
      labels: %{
        operator_workspace: "Driftwood Ops",
        operator_glyph: "D",
        tenant_landing: "/broker",
        impersonate_path: "/operator/impersonate",
        # T146 — the operator-ROLE authority seam. The `Samen.Web.Operator.Authz` on_mount
        # derives operator authority from the AUTHENTICATED SESSION PRINCIPAL via this MFA
        # (the principal id is appended) and FAILS CLOSED for any non-operator, so a plain
        # tenant-user session can never reach `/operator/*`. Reference resolver: a configured
        # operator roster in prod; a dev-only `:operator_admin` grant while auth is disarmed.
        operator_authority: {Driftwood.Auth, :operator_role, [:driftwood]},
        # WS-B B6/B9 — the FlagAdminLive namespace seam: the host's Primitives
        # mount whose FeatureFlag rows the platform flag admin manages (AC-G6-7).
        flags_namespace: Driftwood.Primitives,
        # T149 B2b — the aggregate-plane projection the operator AnalyticsLive "ask" box
        # narrates over via `Samen.AI.Analytics.ask/4` (cross-tenant MRR by tier, k-anon
        # floored, no PII column by construction). Absent it, the ask box fail-honests.
        analytics_ask_resource: Driftwood.Aggregate.MrrByTier
      }
    )
  end

  # T146 — the driftwood-LOCAL operator surfaces, RELOCATED here from the bare `:browser`
  # scopes above so they ride the operator-authz pipeline (conn-level operator-ROLE gate). Both
  # are OPERATOR surfaces; before T146 they piped `:browser` only (authentication), so a plain
  # tenant user reached them (the verifier bypass). Aliased under `DriftwoodWeb` because
  # `OperatorImpersonationLive` is a driftwood-local LiveView.
  scope "/", DriftwoodWeb do
    pipe_through([:browser, :require_authenticated_operator])

    # T146 (round 3) — the freight-shaped masked impersonation console + second-party reveal
    # control (ADR-009/010), in its OWN named live_session carrying the operator-ROLE on_mount.
    # A bare `live/2` here would fall into the SHARED `:default` live_session (alongside the
    # tenant `/broker` route), letting a tenant with a `/broker` socket `live_redirect` in over
    # the websocket with NO gate running (the conn pipeline gates only the HTTP dead-render). The
    # `on_mount` + the `@impersonate_mount`'s `:operator_authority` label close that live-nav
    # vector; a tenant is refused on the socket mount exactly as on HTTP.
    live_session :driftwood_operator_impersonate,
      on_mount: [{Samen.Web.Operator.Authz, :require_operator}],
      session: %{"samen_mount" => @impersonate_mount} do
      live("/operator/impersonate", OperatorImpersonationLive)
    end
  end

  # The operator-DESK chat (masked cross-plane threads, ADR-012 §6.3). BARE `scope "/"` (the
  # mounted LiveViews are the framework's fully-qualified `Samen.Web.*` modules — see the note
  # on the tenant-mount scope above), piped through the operator-authz pipeline.
  scope "/" do
    pipe_through([:browser, :require_authenticated_operator])

    samen_chat_routes(:chat, Driftwood.Chat,
      repo: Driftwood.Repo,
      plane: :operator,
      operator_id: "driftwood-operator",
      path: "/operator/desk-chat",
      # T146 (round 3) — belt-and-suspenders: the operator-ROLE on_mount runs on the WEBSOCKET
      # mount too (this chat already gets its OWN named live_session via the macro, so no tenant
      # route shares it; the on_mount makes the authz explicit rather than relying on
      # session-name isolation alone). `:operator_authority` on the labels lets it resolve.
      on_mount: [{Samen.Web.Operator.Authz, :require_operator}],
      labels: %{
        title: "Driftwood Ops",
        crumb_root: "Driftwood Ops",
        chat_path: "/operator/desk-chat",
        operator_authority: {Driftwood.Auth, :operator_role, [:driftwood]},
        pubsub: Driftwood.PubSub,
        object_cards: %{"freight.driver" => DriftwoodWeb.Chat.DriverCard}
      }
    )
  end
end
