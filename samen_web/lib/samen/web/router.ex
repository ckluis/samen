defmodule Samen.Web.Router do
  @moduledoc """
  The router macro a host uses to mount a `samen_web` module's LiveView pages in ~5 lines
  (ADR-009 §3.4).

  `samen_module_routes/3` builds a `Samen.Web.Mount` from the host's `namespace` + `repo`
  + `domain` (three facts; the struct derives resource modules), threads it through a
  `live_session` session, and declares the module's routes. The mount travels in the signed
  session so it is present on both the initial dead render and the websocket reconnect
  (ADR-009 §3.5).

  ## Usage

  The macro expands into `live_session` + `live` declarations, so the host router must have
  `Phoenix.LiveView.Router` imported — which a Phoenix app's `use MyAppWeb, :router` already
  provides (a bare `use Phoenix.Router` needs an explicit `import Phoenix.LiveView.Router`).

      import Samen.Web.Router

      scope "/", DriftwoodWeb do
        pipe_through :browser

        samen_module_routes :crm,     Driftwood.Crm,     repo: Driftwood.Repo
        samen_module_routes :billing, Driftwood.Billing, repo: Driftwood.Repo
        samen_module_routes :support, Driftwood.Support, repo: Driftwood.Repo
      end

  Three lines mount all inherited pages. `plane:` defaults `:tenant`; an operator surface
  passes `plane: :operator` (with `operator_id:` / `target_org_id:`).

  ## Options

    * `:repo`   — REQUIRED. The host's Ecto repo (PiiResolution needs it).
    * `:domain` — the host Ash domain (default: `namespace`).
    * `:plane`  — `:tenant` (default) or `:operator`.
    * `:operator_id` / `:target_org_id` — for the operator plane.
    * `:path`   — the mount path prefix (default `/crm`, `/billing`, `/support`).
    * `:labels` — optional UI copy overrides (workspace title, glyph, crumb root).
    * `:session_name` — override the `live_session` name (default derived from kind+path).
  """

  @doc "Mount a samen_web module (`:crm | :billing | :support | :marketing`) under the host router scope."
  defmacro samen_module_routes(kind, namespace, opts \\ []) do
    kind = Macro.expand(kind, __CALLER__)
    path = Keyword.get(opts, :path, default_path(kind))
    session_name = Keyword.get(opts, :session_name, session_name(kind, path))

    quote bind_quoted: [
            kind: kind,
            namespace: namespace,
            opts: opts,
            path: path,
            session_name: session_name
          ] do
      # Build the mount at compile-of-the-router time, serialize to a session-safe map.
      # This runs in the host router module context, so `namespace`/`repo` are resolved.
      mount =
        Samen.Web.Mount.new(
          kind,
          namespace,
          Keyword.fetch!(opts, :repo),
          domain: Keyword.get(opts, :domain, namespace),
          plane: Samen.Web.Router.__plane__(opts),
          labels: Keyword.get(opts, :labels)
        )

      live_session session_name, session: %{"samen_mount" => Samen.Web.Mount.to_session(mount)} do
        for {sub_path, module} <- Samen.Web.Router.__routes__(kind, path) do
          live(sub_path, module)
        end
      end
    end
  end

  @doc """
  Mount the OPERATOR / SaaS-company control-plane workspace in ONE line (ADR-010 §7.2).

  `namespace` is the host's OPERATOR namespace (a domain that mounted Identity + Billing +
  Support blueprints — e.g. `Driftwood.Operator`). The macro builds ONE operator-plane mount
  (`scope_kind: :operator`) carrying the operator org id in its labels, threads it through a
  `live_session`, and declares all operator routes (Accounts · Platform billing · Revenue ·
  Desk) — a WS-B surface added here (e.g. Revenue, B3) is inherited by every vertical that
  already calls the macro at 0 new LiveView lines (AC-X1).

      import Samen.Web.Router

      scope "/" do
        pipe_through :browser
        samen_operator_routes Driftwood.Operator,
          repo: Driftwood.Repo,
          labels: %{operator_authority: {MyApp.Auth, :operator_role, []}}
      end

  ## Operator-ROLE authorization (T146 — fail CLOSED, by construction)

  Every route this macro declares mounts through an `on_mount`
  (`{Samen.Web.Operator.Authz, :require_operator}`) that derives operator authority from the
  AUTHENTICATED SESSION PRINCIPAL — via the host's `:operator_authority` seam (below) — and
  FAILS CLOSED (redirect to `/login`, renders nothing) for any principal that is NOT an operator.
  A plain authenticated TENANT user therefore cannot reach `/operator/*`. The authority is NEVER
  fabricated from the mount. A host that wires no `:operator_authority` gets NO operator access
  (deny-by-default). See `Samen.Web.Operator.Authz`.

  ## The operator seat's PII plane is `:tenant` of the operator org, NOT `:operator`

  ADR-010 §7.2 (load-bearing): the operator's OWN workspace reads the operator org over its OWN
  book of business on the TENANT plane (clear). The word "operator" names the ORG/WORKSPACE; the
  PII plane is `:tenant`. Only the drill-into-a-tenant action ("Open account") uses
  `plane: :operator` (masked), via the existing `samen_module_routes ... plane: :operator`.

  ## Options

    * `:repo`            — REQUIRED. The host's Ecto repo.
    * `:domain`          — the host Ash domain (default: `namespace`).
    * `:operator_org_id` — the well-known operator org id (else resolved via app env or the
      single seeded Org row — see `Samen.Web.Operator.org_id/1`).
    * `:operator_authority` — the operator-ROLE seam (T146): an `{mod, fun, args}` MFA called
      with the authenticated principal id APPENDED, returning an operator role
      (`Samen.OperatorPlane.Actor.roles/0`) or `nil`. ABSENT → deny-by-default (no operator
      access). See `Samen.Web.Operator.Authz`; a dev-only default is
      `{Samen.Web.Operator.Authz, :dev_operator_role, [otp_app]}`.
    * `:login_path` — where a non-operator principal is redirected (default `"/login"`).
    * `:path`            — the mount path prefix (default `/operator`).
    * `:labels`          — optional UI copy overrides (operator workspace title/glyph, etc.).
    * `:include_aggregate` — also mount the `aggregate` page on THIS operator mount (default
      `false`). A host that already wires its own token-blind aggregate (a vertical-shaped
      projection via `aggregate_loader:`) mounts it separately and leaves this `false`, so the
      route is not declared twice.
    * `:fleet_cockpit` — mount the WS-J fleet cockpit (ADR-044 §5/§7/§9, T84b) on THIS operator
      mount (default `false`): `/fleet` (tier-1 platform aggregates + the merged T156 cross-
      tenant health surfaces), `/fleet/:app_id` (tier-2 cohort rows), `/fleet/directives` (J4
      flag/announcement publish), `/fleet/register` (J1 register/enroll). Rides the SAME
      `live_session` as every other operator route, so it inherits the T146 `:require_operator`
      `on_mount` gate (RP-J-12) — there is no separate fleet auth hook to forget. A further
      `roles[:fleet]` check (ADR-044 §6.3, the J3 args-carrier) runs INSIDE each fleet LiveView's
      own `mount/3` (role-gated, not session-gated — §5.4's tier-1/2 ladder).
    * `:fleet_namespace` — the `Samen.Fleet.Scope`-mounted Ash domain the cockpit reads
      (`Samen.Fleet.read/2`'s `namespace:` opt) — required when `:fleet_cockpit` is `true` and
      the host's `:fleet` mode is `:manual`/`:heartbeat`; irrelevant (and harmless) for the
      zero-config `:embedded` default (§8.1).
    * `:session_name`    — override the `live_session` name (default `:samen_operator`).

  ## The tier-2 deep-link RESOLVE routes (always mounted, ADR-044 §5.3)

  `GET #{"{path}"}/deliverability/resolve`, `.../automation/resolve`, `.../activity/resolve` —
  the handle→org_id lookup a cockpit's tier-2 deep link lands on — are mounted UNCONDITIONALLY
  (not gated by `:fleet_cockpit`), because ANY product with the drill-in family already mounted
  can be a resolve TARGET regardless of whether it also hosts a cockpit. Handle resolution is
  NOT tier-3 access (§16.4a) — it runs behind the SAME T146 `on_mount` this macro always
  attaches, then redirects to the canonical `:org_id` drill-in, which composes the FULL
  T146+scope+T150 gate exactly as it does for any other arrival (`Samen.Web.Operator.
  Impersonation.gate_socket/3`, wired by T84a).
  """
  defmacro samen_operator_routes(namespace, opts \\ []) do
    path = Keyword.get(opts, :path, "/operator")
    session_name = Keyword.get(opts, :session_name, :samen_operator)
    include_aggregate = Keyword.get(opts, :include_aggregate, false)
    fleet_cockpit = Keyword.get(opts, :fleet_cockpit, false)
    fleet_namespace = Keyword.get(opts, :fleet_namespace)

    quote bind_quoted: [
            namespace: namespace,
            opts: opts,
            path: path,
            session_name: session_name,
            include_aggregate: include_aggregate,
            fleet_cockpit: fleet_cockpit,
            fleet_namespace: fleet_namespace
          ] do
      operator_labels =
        (Keyword.get(opts, :labels) || %{})
        |> Samen.Web.Router.__operator_labels__(Keyword.get(opts, :operator_org_id))
        |> Samen.Web.Router.__fleet_namespace_label__(fleet_namespace)
        |> Samen.Web.Router.__fleet_cockpit_label__(fleet_cockpit)

      mount =
        Samen.Web.Mount.new(
          :operator,
          namespace,
          Keyword.fetch!(opts, :repo),
          domain: Keyword.get(opts, :domain, namespace),
          # The operator seat is the operator org over its OWN book of business — TENANT plane
          # (clear). Crossing to a tenant's masked world is the explicit impersonation link.
          plane: Samen.Web.Plane.tenant(),
          labels: operator_labels
        )

      # T146 — the operator-ROLE authorization hook. Every operator route mounts through this
      # `on_mount`, which derives operator authority from the AUTHENTICATED SESSION PRINCIPAL via
      # the host `:operator_authority` seam and FAILS CLOSED (redirect to /login, renders nothing)
      # for any principal that is not an operator. A plain tenant-user session cannot reach ANY
      # `/operator/*` surface. See `Samen.Web.Operator.Authz`.
      live_session session_name,
        on_mount: [{Samen.Web.Operator.Authz, :require_operator}],
        session: %{"samen_mount" => Samen.Web.Mount.to_session(mount)} do
        live("#{path}/accounts", Samen.Web.Operator.AccountsLive)
        # The B4 health drill-down (ADR-019 / AC-G17-4) — inherited at 0 vertical LOC.
        live("#{path}/accounts/:id", Samen.Web.Operator.AccountDetailLive)
        live("#{path}/billing", Samen.Web.Operator.PlatformBillingLive)
        live("#{path}/revenue", Samen.Web.Operator.RevenueLive)
        # The B6 platform flag admin (ADR-020 / AC-G6-7) — kill switch + ramp +
        # targeting + per-org state; inherited at 0 vertical LOC. Wire the host's
        # Primitives namespace via a `flags_namespace:` label to activate.
        live("#{path}/flags", Samen.Web.Operator.FlagAdminLive)
        # The B8 product-analytics SEED read (ADR-021 / AC-G12-6) — the one funnel +
        # 4-week retention curve over the paf rollup, cross-tenant under the k-anon
        # floor; inherited at 0 vertical LOC.
        live("#{path}/analytics", Samen.Web.Operator.AnalyticsLive)
        live("#{path}/desk", Samen.Web.Operator.DeskLive)
        # T149 B1 — the ticket DETAIL + conversation + reply surface (the missing "resolve a
        # ticket" affordance; DeskLive was list+create+delete only). Rides the SAME operator
        # live_session, so the `{Samen.Web.Operator.Authz, :require_operator}` on_mount gates it
        # (a tenant-user session can never reach it). Reads the operator org's OWN desk on the
        # TENANT plane (the SaaS's own book of business — NOT a per-tenant impersonation drill-in,
        # so not T150-session-gated); a reply posts through the governed `Support.Message` create.
        live("#{path}/desk/:id", Samen.Web.Operator.DeskDetailLive)
        # The B9 webhook DLQ (ADR-038 §5.5) — failed/unprocessable ingress envelopes,
        # listed TOKEN-BLIND (provider · kind · event id · timestamps · attempt count ·
        # error summary + the already-redacted payload; no PII, no vault tokens). Replay
        # + resolve operator actions. Inherited at 0 vertical LOC.
        live("#{path}/webhooks", Samen.Web.Operator.WebhookDlqLive)
        # The E8 automation observability surface (ADR-039 §8.3/§8.4; T42) —
        # run log + per-workflow health aggregates + the operator kill-switch,
        # scoped to ONE tenant org at a time (the route param), reached from
        # the account drill-down's "Automation health →" link. Inherited at
        # 0 vertical LOC; token-blind by construction (no PII column exists on
        # either resource it reads).
        #
        # The ADR-044 §5.3 tier-2 deep-link RESOLVE route (T84b) — a STATIC segment that
        # MUST be declared BEFORE its sibling dynamic `:org_id` route: Phoenix's router
        # dispatches in DECLARATION ORDER, so a dynamic segment declared first would
        # capture "resolve" as `org_id` and this literal route would never be reached.
        # Handle resolution is NOT tier-3 access (§16.4a) — it redirects to the canonical
        # `:org_id` route right below, which is where the full T146+scope+T150 gate
        # actually runs (unchanged, T84a-wired).
        live("#{path}/automation/resolve", Samen.Web.Operator.FleetResolveLive, :automation)
        live("#{path}/automation/:org_id", Samen.Web.Operator.AutomationHealthLive)
        # The R2/T114 per-tenant deliverability drill-down (dogfood-report.md R3 —
        # P4's "why didn't this tenant get their email?" job-test) — the T28/T30
        # delivery/suppression store, scoped to ONE tenant org at a time (the
        # route param), reached from the account drill-down's "Deliverability →"
        # link and from the webhook DLQ's org column. Inherited at 0 vertical LOC.
        # (Resolve route declared first — see the automation family's comment above.)
        live("#{path}/deliverability/resolve", Samen.Web.Operator.FleetResolveLive, :deliverability)
        live("#{path}/deliverability/:org_id", Samen.Web.Operator.DeliverabilityLive)
        # The R3/T115 operator activity/audit feed (dogfood-report.md R4 — P4's
        # "what changed in org X in the last 24h?" job-test) — the aud_chain
        # governance tier (incl. T38's impersonation-write rows) merged with
        # T119's versioned change-log, scoped to ONE tenant org at a time (the
        # route param), reached from the account drill-down's "Activity →"
        # link. Inherited at 0 vertical LOC. (Resolve route declared first — see above.)
        live("#{path}/activity/resolve", Samen.Web.Operator.FleetResolveLive, :activity)
        live("#{path}/activity/:org_id", Samen.Web.Operator.ActivityLive)

        if include_aggregate do
          live("#{path}/aggregate", Samen.Web.Operator.AggregateLive)
        end

        # WS-J fleet cockpit (ADR-044 §5/§7/§9, T84b) — opt-in via `fleet_cockpit: true`.
        # Rides this SAME live_session, so RP-J-12 ("no un-gated path") is a property of
        # the macro itself: every route declared here, cockpit or not, carries the
        # `:require_operator` on_mount — there is no separate branch that could omit it.
        if fleet_cockpit do
          live("#{path}/fleet", Samen.Web.Operator.FleetLive)
          live("#{path}/fleet/directives", Samen.Web.Operator.FleetDirectivesLive)
          live("#{path}/fleet/register", Samen.Web.Operator.FleetRegisterLive)
          live("#{path}/fleet/:app_id", Samen.Web.Operator.FleetDetailLive)
        end
      end
    end
  end

  @doc """
  Mount the SHARED webhook ingress (ADR-038 §5.1; B9) — `POST /webhooks/:provider` — in
  ONE line. Vendor-generic: the provider module + config are resolved from HOST config
  at runtime (`config :samen_web, Samen.Web.Webhook, providers: %{...}, repo: ...`), so
  the route stays vendor-free (INV-4). Billing (Stripe) and delivery (ESP) webhooks share
  this one endpoint.

      import Samen.Web.Router

      scope "/" do
        pipe_through :webhook_ingress   # a pipeline running Plug.Parsers with the
                                        # Samen.Web.Webhook.RawBodyReader body reader
        samen_webhook_routes()
      end

  ## One-time host endpoint add (raw-body capture)

  Signature verification needs the exact signed bytes, so the endpoint MUST cache the
  raw body BEFORE `Plug.Parsers` decodes it:

      plug Plug.Parsers,
        parsers: [:urlencoded, :json],
        body_reader: {Samen.Web.Webhook.RawBodyReader, :read_body, []},
        json_decoder: Jason

  ## Options

    * `:path` — the ingress path prefix (default `/webhooks`).
  """
  defmacro samen_webhook_routes(opts \\ []) do
    path = Keyword.get(opts, :path, "/webhooks")

    quote bind_quoted: [path: path] do
      post("#{path}/:provider", Samen.Web.Webhook.IngressController, :create)
    end
  end

  @doc """
  Mount the **reporting side** of the fleet (ADR-044 §3.2/§4.4a/§9.1, WS-J J1) —
  `GET /fleet/health` + `POST /fleet/directive`. Every product mounts this,
  INCLUDING a fleet cockpit (§9.2: "two lines to report"). ≈0-LOC adoption:

      import Samen.Web.Router

      samen_fleet_routes(otp_app: :my_app)

  The `POST /fleet/directive` receiver needs the exact signed bytes, so the
  host's endpoint must wire the SAME raw-body reader the webhook ingress uses:

      plug Plug.Parsers,
        parsers: [:urlencoded, :json],
        body_reader: {Samen.Web.Webhook.RawBodyReader, :read_body, []},
        json_decoder: Jason

  ## Options

    * `:otp_app` — required. The `Application.get_env(otp_app, ...)`
      namespace `Samen.Fleet.mode/1` and `Samen.Fleet.LocalCredential` read.
    * `:path` — the route path prefix (default `/fleet`).
  """
  defmacro samen_fleet_routes(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    path = Keyword.get(opts, :path, "/fleet")

    quote bind_quoted: [otp_app: otp_app, path: path] do
      fleet_opts = [otp_app: otp_app]

      get("#{path}/health", Samen.Web.FleetController, :health, private: %{samen_fleet: fleet_opts})

      post("#{path}/directive", Samen.Web.FleetController, :directive,
        private: %{samen_fleet: fleet_opts}
      )
    end
  end

  @doc """
  Mount the **cockpit-side ingest** of the fleet (ADR-044 §4.4a, WS-J J1) —
  `POST /fleet/enroll` + `POST /fleet/heartbeat`. Only a fleet COCKPIT mounts
  this (§3.1). ≈0-LOC adoption on whichever product hosts the cockpit:

      import Samen.Web.Router

      samen_fleet_ingest_routes(namespace: MyApp.Fleet)

  `namespace` is a `Samen.Fleet.Scope`-mounted Ash domain (see that module).
  Needs the SAME raw-body reader `samen_fleet_routes/1` documents.

  ## Options

    * `:namespace` — required. The Ash domain `Samen.Fleet.Registry` operates over.
    * `:path` — the route path prefix (default `/fleet`).
  """
  defmacro samen_fleet_ingest_routes(opts) do
    namespace = Keyword.fetch!(opts, :namespace)
    path = Keyword.get(opts, :path, "/fleet")

    quote bind_quoted: [namespace: namespace, path: path] do
      fleet_ingest_opts = [namespace: namespace]

      post("#{path}/enroll", Samen.Web.FleetIngressController, :enroll,
        private: %{samen_fleet_ingest: fleet_ingest_opts}
      )

      post("#{path}/heartbeat", Samen.Web.FleetIngressController, :heartbeat,
        private: %{samen_fleet_ingest: fleet_ingest_opts}
      )
    end
  end

  @doc """
  Mount the FLAGSHIP cross-plane realtime CHAT (ADR-012 §6.3) — the `/chat` inbox + `/chat/:id`
  room — over a host's materialized `Samen.Scopes.Chat` resources. A tenant chat and a
  SaaS-desk chat are the SAME LiveViews on different planes.

      import Samen.Web.Router

      # TENANT plane — the org's own chat console.
      samen_chat_routes :chat, Driftwood.Chat, repo: Driftwood.Repo

      # SaaS-DESK plane — the operator drills into a tenant's cross-plane threads (masked),
      # reaching them through the impersonation bridge carrying the tenant org_id (§2.3).
      samen_chat_routes :chat, Driftwood.Chat,
        repo: Driftwood.Repo,
        plane: :operator,
        target_org_id: tenant_org_id,
        path: "/operator/desk-chat"

  ## One-time host supervision-tree add

  The realtime path needs a running `Phoenix.PubSub` (the host's — default `Driftwood.PubSub`,
  overridable via a `:pubsub` label on the mount) and, for who's-online/typing, the framework
  presence server. Add to the host's supervision tree:

      {Phoenix.PubSub, name: Driftwood.PubSub},        # already present in a Phoenix app
      {Samen.Web.Chat.Presence, pubsub_server: Driftwood.PubSub}

  ## Options

    * `:repo`            — REQUIRED. The host's Ecto repo.
    * `:domain`          — the host Ash domain (default: `namespace`).
    * `:plane`           — `:tenant` (default) or `:operator`.
    * `:operator_id` / `:target_org_id` — for the operator-desk plane (§2.3).
    * `:path`            — the mount path prefix (default `/chat`).
    * `:labels`          — optional UI copy overrides + a `:pubsub`/`:presence`/`:object_cards`
      seam (data on the mount).
    * `:session_name`    — override the `live_session` name.
    * `:on_mount`        — OPTIONAL `on_mount` hooks for this chat `live_session` (default `[]`).
      An OPERATOR-plane chat mount (the operator desk-chat) passes
      `[{Samen.Web.Operator.Authz, :require_operator}]` (with an `:operator_authority` label) so
      the operator-ROLE gate runs on the WEBSOCKET mount, not just the HTTP dead-render (T146).
  """
  defmacro samen_chat_routes(kind, namespace, opts \\ []) do
    kind = Macro.expand(kind, __CALLER__)
    path = Keyword.get(opts, :path, "/chat")
    session_name = Keyword.get(opts, :session_name, session_name(:chat, path))

    quote bind_quoted: [
            kind: kind,
            namespace: namespace,
            opts: opts,
            path: path,
            session_name: session_name
          ] do
      mount =
        Samen.Web.Mount.new(
          :chat,
          namespace,
          Keyword.fetch!(opts, :repo),
          domain: Keyword.get(opts, :domain, namespace),
          plane: Samen.Web.Router.__plane__(opts),
          labels: Keyword.get(opts, :labels)
        )

      # T146 — an OPTIONAL `:on_mount` (default `[]`, a no-op for every existing caller). A host
      # mounting the chat LiveViews on the OPERATOR plane (`plane: :operator`, e.g. the operator
      # desk-chat) passes `on_mount: [{Samen.Web.Operator.Authz, :require_operator}]` so the
      # operator-ROLE authz gate runs on the WEBSOCKET mount too (the conn pipeline gates only the
      # HTTP dead-render; same-live_session live-nav is gated only by on_mount). Requires an
      # `:operator_authority` label on the mount. Tenant-plane chat passes nothing → unchanged.
      live_session session_name,
        on_mount: Keyword.get(opts, :on_mount, []),
        session: %{"samen_mount" => Samen.Web.Mount.to_session(mount)} do
        for {sub_path, module} <- Samen.Web.Router.__routes__(:chat, path) do
          live(sub_path, module)
        end
      end
    end
  end

  @doc """
  Mount the framework NOTIFICATIONS INBOX (WS-A design §2.4; ADR-016 §4) — the
  `/notifications` inbox every vertical inherits — in ONE line, on either plane.

  `namespace` is the host's mounted PRIMITIVES namespace (the domain that `use`d
  `Samen.Scopes.Primitives` — it materializes `Notification` + `NotificationPreference`,
  e.g. `Demo.PrimitivesScope`).

      import Samen.Web.Router

      # TENANT plane — the org's own inbox (rendered_body clear).
      samen_notifications_routes :notifications, Demo.PrimitivesScope, repo: Demo.Repo

      # OPERATOR / impersonation plane — the SAME LiveView, masked (••••), reached
      # through the impersonation bridge carrying the tenant org_id.
      samen_notifications_routes :notifications, Demo.PrimitivesScope,
        repo: Demo.Repo,
        plane: :operator,
        target_org_id: tenant_org_id,
        path: "/operator/notifications"

  Realtime needs a running `Phoenix.PubSub` (the host's — the mount's `:pubsub` label,
  default `Driftwood.PubSub`) and the kernel engine wired to the web broadcaster:

      config :samen_core, Samen.Notifications.Engine,
        broadcaster: Samen.Web.Notifications.PubSubBroadcaster
      config :samen_web, Samen.Web.Notifications.PubSubBroadcaster, pubsub: MyApp.PubSub

  Options: as `samen_chat_routes/3` (`:repo` required; `:domain`, `:plane`,
  `:operator_id`/`:target_org_id`, `:path` (default `/notifications`), `:labels`,
  `:session_name`).
  """
  defmacro samen_notifications_routes(kind, namespace, opts \\ []) do
    kind = Macro.expand(kind, __CALLER__)
    path = Keyword.get(opts, :path, "/notifications")
    session_name = Keyword.get(opts, :session_name, session_name(:notifications, path))

    quote bind_quoted: [
            kind: kind,
            namespace: namespace,
            opts: opts,
            path: path,
            session_name: session_name
          ] do
      _ = kind

      mount =
        Samen.Web.Mount.new(
          :notifications,
          namespace,
          Keyword.fetch!(opts, :repo),
          domain: Keyword.get(opts, :domain, namespace),
          plane: Samen.Web.Router.__plane__(opts),
          labels: Keyword.get(opts, :labels)
        )

      live_session session_name, session: %{"samen_mount" => Samen.Web.Mount.to_session(mount)} do
        for {sub_path, module} <- Samen.Web.Router.__routes__(:notifications, path) do
          live(sub_path, module)
        end
      end
    end
  end

  @doc """
  Mount the TENANT feature-flag admin (WS-B B6; ADR-020; design G6 §3.5) — the
  `/flags` settings page where a tenant ADMIN toggles/ramps/targets their org's own
  feature flags — in ONE line, on either plane.

  `namespace` is the host's mounted PRIMITIVES namespace (the domain that `use`d
  `Samen.Scopes.Primitives` — it materializes `FeatureFlag`, e.g.
  `Demo.PrimitivesScope`, `Driftwood.Primitives`).

      import Samen.Web.Router

      # TENANT plane — the org's own flag settings (admin-gated writes).
      samen_flags_routes :flags, Driftwood.Primitives, repo: Driftwood.Repo

      # OPERATOR / impersonation plane — the SAME LiveView, read-only posture,
      # reached through the impersonation bridge carrying the tenant org_id.
      samen_flags_routes :flags, Driftwood.Primitives,
        repo: Driftwood.Repo,
        plane: :operator,
        target_org_id: tenant_org_id,
        path: "/operator/tenant-flags"

  Writes are KERNEL-enforced (`OrgScope` + `RoleAtLeast :admin` + the
  `NonPiiTargeting` write refusal); the UI posture is `writable?/1`. Options: as
  `samen_notifications_routes/3` (`:repo` required; `:domain`, `:plane`,
  `:operator_id`/`:target_org_id`, `:path` (default `/flags`), `:labels`,
  `:session_name`).
  """
  defmacro samen_flags_routes(kind, namespace, opts \\ []) do
    kind = Macro.expand(kind, __CALLER__)
    path = Keyword.get(opts, :path, "/flags")
    session_name = Keyword.get(opts, :session_name, session_name(:flags, path))

    quote bind_quoted: [
            kind: kind,
            namespace: namespace,
            opts: opts,
            path: path,
            session_name: session_name
          ] do
      _ = kind

      mount =
        Samen.Web.Mount.new(
          :flags,
          namespace,
          Keyword.fetch!(opts, :repo),
          domain: Keyword.get(opts, :domain, namespace),
          plane: Samen.Web.Router.__plane__(opts),
          labels: Keyword.get(opts, :labels)
        )

      live_session session_name, session: %{"samen_mount" => Samen.Web.Mount.to_session(mount)} do
        for {sub_path, module} <- Samen.Web.Router.__routes__(:flags, path) do
          live(sub_path, module)
        end
      end
    end
  end

  @doc """
  Mount the framework FILES surface (WS-E E2.1; ADR-026) — the upload + preview LiveViews
  and the plane-gated `/files/:id` byte-serve route — in ONE line, on either plane.

  `namespace` is the host's mounted PRIMITIVES namespace (the domain that `use`d
  `Samen.Scopes.Primitives` — it materializes the `File` resource, e.g.
  `Demo.PrimitivesScope`, `Driftwood.Primitives`).

      import Samen.Web.Router

      # TENANT plane — the org's own file surface (filenames in the clear; bytes serveable).
      samen_files_routes :files, Demo.PrimitivesScope, repo: Demo.Repo

      # OPERATOR / impersonation plane — the SAME LiveViews, filenames masked (••••),
      # byte download refused (no partial-reveal for raw bytes). Reached through the
      # impersonation bridge carrying the tenant org_id.
      samen_files_routes :files, Demo.PrimitivesScope,
        repo: Demo.Repo,
        plane: :operator,
        target_org_id: tenant_org_id,
        path: "/operator/files"

  The macro mounts:

    * `GET  /<path>`      → `Samen.Web.Files.UploadLive`   (upload + file list)
    * `GET  /<path>/:id`  → `Samen.Web.Files.PreviewLive`  (file metadata preview)
    * `GET  /<path>/:id/bytes` → `Samen.Web.Files.BytesController, :serve`
      (org-scoped, plane-gated, quarantine-refused byte delivery)

  The LiveViews share a `live_session` carrying the mount. The `BytesController` route
  is mounted outside the `live_session` block (it is a plain controller action, not a
  LiveView); the host's `:browser` pipeline must include the session plug so the mount
  and current-org are readable.

  Options: as `samen_notifications_routes/3` (`:repo` required; `:domain`, `:plane`,
  `:operator_id`/`:target_org_id`, `:path` (default `/files`), `:labels`,
  `:session_name`).
  """
  defmacro samen_files_routes(kind, namespace, opts \\ []) do
    kind = Macro.expand(kind, __CALLER__)
    path = Keyword.get(opts, :path, "/files")
    session_name = Keyword.get(opts, :session_name, session_name(:files, path))

    quote bind_quoted: [
            kind: kind,
            namespace: namespace,
            opts: opts,
            path: path,
            session_name: session_name
          ] do
      _ = kind

      mount =
        Samen.Web.Mount.new(
          :files,
          namespace,
          Keyword.fetch!(opts, :repo),
          domain: Keyword.get(opts, :domain, namespace),
          plane: Samen.Web.Router.__plane__(opts),
          labels: Keyword.get(opts, :labels)
        )

      live_session session_name, session: %{"samen_mount" => Samen.Web.Mount.to_session(mount)} do
        for {sub_path, module} <- Samen.Web.Router.__routes__(:files, path) do
          live(sub_path, module)
        end
      end

      # The byte-serve route is a plain controller action — outside the live_session block.
      # The host's :browser pipeline (which wraps this scope) supplies the session plug so
      # the mount and current-org are readable in the controller.
      get("#{path}/:id/bytes", Samen.Web.Files.BytesController, :serve)
    end
  end

  @doc """
  Mount the framework CSV surface (WS-E E3.4; ADR-028) — the import LiveView and the
  export download route — in ONE line, on either plane.

  `namespace` is the host's mounted namespace whose DOMAIN's resources are servable
  (deny-by-default: `/csv/*/:resource` resolves only onto that domain's registered
  resources — `Samen.Web.Csv.resolve_resource/2`).

      import Samen.Web.Router

      # TENANT plane — export in the clear (own org), import via governed creates.
      samen_csv_routes :csv, Demo.Crm, repo: Demo.Repo

      # OPERATOR plane — the SAME routes; export cells render `••••` per
      # PiiResolution (AC-G15-2), import is refused row-by-row by the kernel guards.
      samen_csv_routes :csv, Demo.Crm,
        repo: Demo.Repo,
        plane: :operator,
        target_org_id: tenant_org_id,
        path: "/operator/csv"

  The macro mounts:

    * `GET /<path>/import/:resource` → `Samen.Web.Csv.ImportLive`
    * `GET /<path>/export/:resource` → `Samen.Web.Csv.ExportController, :export`
      (org-scoped, keyset-bounded, per-plane masked CSV download)

  Options: as `samen_files_routes/3` (`:repo` required; `:domain`, `:plane`,
  `:operator_id`/`:target_org_id`, `:path` (default `/csv`), `:labels`,
  `:session_name`).
  """
  defmacro samen_csv_routes(kind, namespace, opts \\ []) do
    kind = Macro.expand(kind, __CALLER__)
    path = Keyword.get(opts, :path, "/csv")
    session_name = Keyword.get(opts, :session_name, session_name(:csv, path))

    quote bind_quoted: [
            kind: kind,
            namespace: namespace,
            opts: opts,
            path: path,
            session_name: session_name
          ] do
      _ = kind

      mount =
        Samen.Web.Mount.new(
          :csv,
          namespace,
          Keyword.fetch!(opts, :repo),
          domain: Keyword.get(opts, :domain, namespace),
          plane: Samen.Web.Router.__plane__(opts),
          labels: Keyword.get(opts, :labels)
        )

      live_session session_name, session: %{"samen_mount" => Samen.Web.Mount.to_session(mount)} do
        for {sub_path, module} <- Samen.Web.Router.__routes__(:csv, path) do
          live(sub_path, module)
        end
      end

      # The export download is a plain controller action — outside the live_session
      # block. The host's :browser pipeline supplies the session plug so the mount
      # and current-org are readable (same posture as the files byte-serve route).
      get("#{path}/export/:resource", Samen.Web.Csv.ExportController, :export)
    end
  end

  @doc """
  Mount the framework `.ics` (iCalendar) export surface (F2; spec §F2/§F8 c8) —
  ONE line, on either plane. `namespace` is the host's mounted Calendar-scope
  namespace (`use Samen.Scopes.Calendar, namespace: ...` — its materialized
  `Event` resource is derived by the ADR-004 convention, same as every other
  `Samen.Web.Mount` consumer; unlike `samen_csv_routes` there is no `:resource`
  route segment — a Calendar mount serves exactly one resource).

      import Samen.Web.Router

      # TENANT plane — attendee lines in the clear (own org).
      samen_ics_routes :ics, Driftwood.Calendar, repo: Driftwood.Repo

      # OPERATOR plane — the SAME route shape, attendee lines masked per
      # PiiResolution (INV-1).
      samen_ics_routes :ics, Driftwood.Calendar,
        repo: Driftwood.Repo,
        plane: :operator,
        target_org_id: tenant_org_id,
        path: "/operator/calendar.ics"

  Mounts `GET <path>` (default `/calendar.ics`) → `Samen.Web.Ics.ExportController,
  :export` (org-scoped, keyset-bounded, per-plane masked `text/calendar`
  download). Options: as `samen_csv_routes/3` (`:repo` required; `:domain`,
  `:plane`, `:operator_id`/`:target_org_id`, `:path`, `:labels`).
  """
  defmacro samen_ics_routes(kind, namespace, opts \\ []) do
    kind = Macro.expand(kind, __CALLER__)
    path = Keyword.get(opts, :path, "/calendar.ics")

    quote bind_quoted: [kind: kind, namespace: namespace, opts: opts, path: path] do
      _ = kind

      mount =
        Samen.Web.Mount.new(
          :ics,
          namespace,
          Keyword.fetch!(opts, :repo),
          domain: Keyword.get(opts, :domain, namespace),
          plane: Samen.Web.Router.__plane__(opts),
          labels: Keyword.get(opts, :labels)
        )

      # A plain controller action — no LiveView needed (there is no import UI
      # for ICS, only a download). Same session/mount-assign posture as the
      # CSV export route and the files byte-serve route.
      get(path, Samen.Web.Ics.ExportController, :export, assigns: %{samen_mount: mount})
    end
  end

  @doc """
  Mount the framework SEARCH surface (WS-E E4.3; ADR-027) — the ⌘K search page over
  the KERNEL `Samen.Search` engine — in ONE line, on either plane. Zero authored
  search LiveViews per vertical.

  `namespace` is the host's mounted namespace whose DOMAIN registered its searchable
  resources in a `SearchIndex` (the domain that `use`d `Samen.Scopes.Primitives` — it
  materializes `SearchIndex` + a searchable `File`, e.g. `Driftwood.Primitives`).

      import Samen.Web.Router

      # TENANT plane — the org's own search (results in the clear).
      samen_search_routes :search, Driftwood.Primitives, repo: Driftwood.Repo

      # OPERATOR / impersonation plane — the SAME page + engine; every result row's
      # vaulted fields render `••••` per PiiResolution (AC-G9-3).
      samen_search_routes :search, Driftwood.Primitives,
        repo: Driftwood.Repo,
        plane: :operator,
        target_org_id: tenant_org_id,
        path: "/operator/search"

  The macro mounts `GET /<path>` → `Samen.Web.Search.SearchLive`. Options: as
  `samen_files_routes/3` (`:repo` required; `:domain`, `:plane`,
  `:operator_id`/`:target_org_id`, `:path` (default `/search`), `:labels`,
  `:session_name`).
  """
  defmacro samen_search_routes(kind, namespace, opts \\ []) do
    kind = Macro.expand(kind, __CALLER__)
    path = Keyword.get(opts, :path, "/search")
    session_name = Keyword.get(opts, :session_name, session_name(:search, path))

    quote bind_quoted: [
            kind: kind,
            namespace: namespace,
            opts: opts,
            path: path,
            session_name: session_name
          ] do
      _ = kind

      mount =
        Samen.Web.Mount.new(
          :search,
          namespace,
          Keyword.fetch!(opts, :repo),
          domain: Keyword.get(opts, :domain, namespace),
          plane: Samen.Web.Router.__plane__(opts),
          labels: Keyword.get(opts, :labels)
        )

      live_session session_name, session: %{"samen_mount" => Samen.Web.Mount.to_session(mount)} do
        for {sub_path, module} <- Samen.Web.Router.__routes__(:search, path) do
          live(sub_path, module)
        end
      end
    end
  end

  @doc """
  Mount the tenant-plane AUTOMATION (workflow) BUILDER (ADR-039 §12 done-criterion 4
  UI half; T118) — `/automation`, list + author/edit workflows over a host's
  materialized Automation scope (`use Samen.Scopes.Automation`, T39) — in ONE line.

  `namespace` is the host's mounted AUTOMATION namespace (the domain that `use`d
  `Samen.Scopes.Automation` — it materializes `Workflow` (+ `Reminder`/`Escalation`/
  `Run`, unused by this surface), e.g. `Driftwood.Automation`).

      import Samen.Web.Router

      samen_automation_routes :automation, Driftwood.Automation, repo: Driftwood.Repo

  ## TENANT PLANE ONLY (INV-2 — no `:plane` option)

  Unlike its sibling macros, this one does NOT accept a `:plane`/`:operator_id`/
  `:target_org_id` option — the mount is ALWAYS `Samen.Web.Plane.tenant()`. Automation
  is a tenant-AUTHORED surface (T39's done-criterion 4: "builder renders on tenant
  plane only"); the operator-plane counterpart is the SEPARATE, already-shipped
  `Samen.Web.Operator.AutomationHealthLive` (T42, cross-org run log + kill-switch,
  mounted via `samen_operator_routes/2`). There is structurally no code path to mount
  this builder on the operator plane.

  Every mutating affordance (create/edit a workflow, pause/resume, manual "Run now")
  runs through the SAME governed `Workflow` actions T39 shipped: the write-time
  `Samen.Automation.NonPiiPredicates` oracle refuses a vault/plaintext-PII condition
  key or action interpolation (INV-1) and the condition-key picker is sourced LIVE
  from `NonPiiPredicates.eligible_names/1` — never a hardcoded/second field list.
  Pause/resume writes the tenant `status` switch (`:draft | :active | :paused`, the
  SAME kill-switch column family T39/T42 read); it does NOT touch the operator-only
  `disabled_by_operator_at`/`disabled_reason` columns (T42's cross-org emergency stop).

  ADR-042 Class B: the workflow list renders real server HTML with JS off; authoring
  (save/pause/run-now) are `phx-click`/`phx-submit` writes that may need the socket.

  Options: as `samen_flags_routes/3`, minus `:plane`/`:operator_id`/`:target_org_id`
  (`:repo` required; `:domain`, `:path` (default `/automation`), `:labels`,
  `:session_name`).
  """
  defmacro samen_automation_routes(kind, namespace, opts \\ []) do
    kind = Macro.expand(kind, __CALLER__)
    path = Keyword.get(opts, :path, "/automation")
    session_name = Keyword.get(opts, :session_name, session_name(:automation, path))

    quote bind_quoted: [
            kind: kind,
            namespace: namespace,
            opts: opts,
            path: path,
            session_name: session_name
          ] do
      _ = kind

      mount =
        Samen.Web.Mount.new(
          :automation,
          namespace,
          Keyword.fetch!(opts, :repo),
          domain: Keyword.get(opts, :domain, namespace),
          # INV-2 — always tenant plane; see moduledoc (no :plane option exists here).
          plane: Samen.Web.Plane.tenant(),
          labels: Keyword.get(opts, :labels)
        )

      live_session session_name, session: %{"samen_mount" => Samen.Web.Mount.to_session(mount)} do
        for {sub_path, module} <- Samen.Web.Router.__routes__(:automation, path) do
          live(sub_path, module)
        end
      end
    end
  end

  @doc """
  Mount the framework SELF-SERVE SETTINGS surface (WS-E E5; ADR-029) — Profile,
  API keys, and a read-only Security view — in ONE line, on either plane. Zero
  authored settings LiveViews per vertical.

  `namespace` is the host's mounted IDENTITY namespace (the domain that `use`d
  `Samen.Scopes.Identity` — it materializes `User` + `ApiKey` + `Membership`, e.g.
  `Driftwood.Operator`, `Demo.Identity`).

      import Samen.Web.Router

      # TENANT plane — a user manages their OWN account (profile in the clear; mint keys).
      samen_settings_routes :settings, Driftwood.Operator, repo: Driftwood.Repo

      # OPERATOR / impersonation plane — the SAME LiveViews; the profile's vaulted fields
      # render `••••` and a plaintext PII write is refused by WriteGuard; key mint/revoke
      # are read-only.
      samen_settings_routes :settings, Driftwood.Operator,
        repo: Driftwood.Repo,
        plane: :operator,
        target_org_id: tenant_org_id,
        path: "/operator/settings"

  The macro mounts:

    * `GET /<path>`             → `Samen.Web.Settings.ProfileLive`
    * `GET /<path>/profile`     → `Samen.Web.Settings.ProfileLive`
    * `GET /<path>/api-keys`    → `Samen.Web.Settings.ApiKeysLive`
    * `GET /<path>/security`    → `Samen.Web.Settings.SecurityLive`
    * `GET /<path>/invitations` → `Samen.Web.Settings.InvitationsLive` (ADR-035 §5 A5)

  The current user is host-supplied (auth is host-owned): an explicit `?user=` param,
  else `session["samen_current_user"]`, else `Mount.label(mount, :current_user_id)`.

  Options: as `samen_files_routes/3` (`:repo` required; `:domain`, `:plane`,
  `:operator_id`/`:target_org_id`, `:path` (default `/settings`), `:labels`,
  `:session_name`), plus `:spine_sessions` (ADR-035 §4.3, default `false`) — the
  EXPLICIT opt-in that flips the Security surface from its honest "managed by
  your identity provider" placeholders to the real session list + revoke
  controls once the host's `namespace` actually mounts the framework spine's
  `Identity.Session` (never inferred from compilation alone — see
  `Samen.Web.Settings.SecurityLive`), plus `:spine_totp` (ADR-035 §5 A7, default
  `false`) — the EXPLICIT opt-in that mounts `/settings/security/2fa` →
  `Samen.Web.Auth.TotpEnrollLive` and flips SecurityLive's 2FA placeholder to a
  real enrollment link (wire it only when `namespace` mounts the spine's
  `Credential`; never inferred, same posture as `:spine_sessions`).
  """
  defmacro samen_settings_routes(kind, namespace, opts \\ []) do
    kind = Macro.expand(kind, __CALLER__)
    path = Keyword.get(opts, :path, "/settings")
    session_name = Keyword.get(opts, :session_name, session_name(:settings, path))

    quote bind_quoted: [
            kind: kind,
            namespace: namespace,
            opts: opts,
            path: path,
            session_name: session_name
          ] do
      _ = kind

      # ADR-035 §4.3 — `settings_path` lets SecurityLive build the revoke-form
      # `action=` URLs without hardcoding this macro's mount path; `spine_sessions`
      # is the EXPLICIT opt-in (default false) that flips SecurityLive from its
      # honest "managed by your identity provider" placeholders to the real
      # session list + revoke controls (RP-ST-4's honesty inversion, ADR-035
      # §4.3 — real ONLY when a host deliberately turns this on, never inferred
      # from whether `Identity.Session` happens to be compiled in the mount).
      # ADR-035 §5 A7 — `spine_totp` (default false) is the EXPLICIT opt-in that
      # flips SecurityLive's "Two-factor authentication — managed by your identity
      # provider" placeholder into a REAL enrollment affordance AND mounts the
      # `/settings/security/2fa` → `TotpEnrollLive` route. A host wires this ONLY
      # when its `namespace` actually mounts the framework Identity spine's
      # `Credential` (TOTP columns) — never inferred from compilation (the SAME
      # honesty posture as `spine_sessions`). Absent it, this surface is
      # byte-for-byte unchanged (the `settings_surface_test.exs` RP-ST-4 default).
      spine_totp = Keyword.get(opts, :spine_totp, false)

      labels =
        (Keyword.get(opts, :labels) || %{})
        |> Map.put(:settings_path, path)
        |> Map.put(:spine_sessions, Keyword.get(opts, :spine_sessions, false))
        |> Map.put(:spine_totp, spine_totp)

      mount =
        Samen.Web.Mount.new(
          :settings,
          namespace,
          Keyword.fetch!(opts, :repo),
          domain: Keyword.get(opts, :domain, namespace),
          plane: Samen.Web.Router.__plane__(opts),
          labels: labels
        )

      live_session session_name, session: %{"samen_mount" => Samen.Web.Mount.to_session(mount)} do
        for {sub_path, module} <- Samen.Web.Router.__routes__(:settings, path) do
          live(sub_path, module)
        end

        # ADR-035 §5 A7 — the self-service TOTP-enrollment surface. Mounted ONLY
        # under the `spine_totp` opt-in (a host with the Identity spine): a
        # tenant-plane LiveView over the same `:settings` mount whose namespace
        # materializes `Credential`/`User`. Before this route TotpEnrollLive had
        # NO HTTP mount anywhere — 2FA was fail-closed but unreachable in prod.
        if spine_totp do
          live("#{path}/security/2fa", Samen.Web.Auth.TotpEnrollLive)
        end
      end

      # ADR-035 §4.3/§5 A4 — Settings/Security's session revoke controls. A
      # LiveView cannot set a cookie mid-mount, so these two POSTs go through
      # `Samen.Web.Auth.SessionController` (the SessionController precedent).
      # Live ONLY when `namespace` mounts the framework spine's `Identity.Session`
      # — a settings namespace that does not is unaffected (the routes exist but
      # 404/error only if actually hit, exactly as honest as SecurityLive's own
      # "managed by your identity provider" fallback when the spine isn't there).
      post("#{path}/security/sessions/:id/revoke", Samen.Web.Auth.SessionController, :revoke,
        private: %{samen_mount: mount}
      )

      post("#{path}/security/sessions/revoke_others", Samen.Web.Auth.SessionController, :revoke_others,
        private: %{samen_mount: mount}
      )

      # ADR-035 §5 A7 + T110 — the no-JS POST fallbacks for TOTP enrollment,
      # emitted ONLY under `spine_totp` (paired with the GET enroll LiveView
      # above). Samen ships no client JS, so the enroll confirm form's native
      # submit was a GET that would leak the 6-digit TOTP code into the URL;
      # `Samen.Web.Auth.TotpEnrollController` gives it a real POST (code in the
      # body) and hands one-time recovery codes back via flash, never a URL.
      if spine_totp do
        post("#{path}/security/2fa", Samen.Web.Auth.TotpEnrollController, :confirm,
          private: %{samen_mount: mount, samen_totp_enroll_path: "#{path}/security/2fa"}
        )

        post("#{path}/security/2fa/recovery_codes", Samen.Web.Auth.TotpEnrollController, :regenerate,
          private: %{samen_mount: mount, samen_totp_enroll_path: "#{path}/security/2fa"}
        )

        post("#{path}/security/2fa/disable", Samen.Web.Auth.TotpEnrollController, :disable,
          private: %{samen_mount: mount, samen_totp_enroll_path: "#{path}/security/2fa"}
        )
      end
    end
  end

  @doc """
  Mount the framework IDENTITY-SPINE pre-actor auth surfaces — self-serve
  registration (A1), email verification (A2), and password reset (A3) — in
  ONE line:

      import Samen.Web.Router

      scope "/" do
        pipe_through :browser
        samen_auth_routes namespace: Demo.Identity, repo: Demo.Repo
      end

  Declares:

    * `GET /signup`        → `Samen.Web.Auth.RegistrationLive` (ADR-035 §5 A1)
    * `GET /verify/:token` → `Samen.Web.Auth.ConfirmLive` (ADR-035 §5 A2)
    * `GET /reset`         → `Samen.Web.Auth.ResetRequestLive` (ADR-035 §5 A3)
    * `GET /reset/:token`  → `Samen.Web.Auth.ResetLive` (ADR-035 §5 A3)
    * `GET /login`         → `Samen.Web.Auth.LoginLive` (ADR-035 §5 A4)
    * `POST /login`        → `Samen.Web.Auth.SessionController.create/2` (ADR-035 §5 A4)
    * `GET /2fa`           → `Samen.Web.Auth.TotpChallengeLive` (ADR-035 §5 A7 — the
      second-factor interstitial; only reached when `create/2` finds
      `Credential.totp_enabled_at` set)
    * `POST /2fa`          → `Samen.Web.Auth.SessionController.verify_totp/2` (ADR-035 §5 A7)
    * `GET /logout`        → `Samen.Web.Auth.SessionController.delete/2` (ADR-035 §5 A4)
    * `GET /invite/:token` → `Samen.Web.Auth.InviteAcceptLive` (ADR-035 §5 A5)

  The no-JS HTTP POST fallbacks (T110 — Samen ships no client JS, so every
  `phx-submit`-only form must have a real `method="post"` action or its native
  submit leaks credentials into the URL as a GET):

    * `POST /signup`        → `Samen.Web.Auth.AccountController.register/2` (A1)
    * `POST /reset`         → `Samen.Web.Auth.AccountController.request_reset/2` (A3)
    * `POST /reset/:token`  → `Samen.Web.Auth.AccountController.reset/2` (A3)
    * `POST /invite/:token` → `Samen.Web.Auth.AccountController.accept_invite/2` (A5)

  ## Optional OIDC (ADR-035 §5 A6)

  Pass `oidc: [:google]` to additionally mount the OPTIONAL OIDC endpoints:

    * `GET /auth/oidc/:provider`          → `Samen.Web.Auth.OidcController.request/2`
    * `GET /auth/oidc/:provider/callback` → `Samen.Web.Auth.OidcController.callback/2`

  An ABSENT/empty `oidc:` emits NEITHER route (the module-absent contract). IdP
  credentials come from app config (`config :samen_web, Samen.Web.Auth.Oidc,
  providers: %{google: [client_id: ..., client_secret: ..., signup: true]}`); an
  unconfigured provider fail-honests `{:error, :not_configured}` (never a dead
  button). `oidc_config:` is an optional compile-time literal override (tests) and
  `oidc_path:` overrides the `/auth/oidc` prefix.

  **Pre-actor public** (ADR-035 §6): no `plane:`/`operator_id:` options — none
  of these surfaces render org data. `:namespace` is the host's Identity
  mount (the SAME namespace `use Samen.Scopes.Identity, namespace: ...`
  materialized `Org`/`Credential`/`User`/`Membership`/`AuthToken`/`Session`/
  `Invitation` into); `:repo` is required. `:signup_path`/`:verify_path`/
  `:reset_path`/`:login_path`/`:logout_path`/`:invite_path`/`:totp_path`
  override the defaults (`/signup`, `/verify`, `/reset`, `/login`, `/logout`,
  `/invite`, `/2fa`) independently; `:path` (legacy, T02) is still honored as
  the signup path override alone.
  """
  defmacro samen_auth_routes(opts \\ []) do
    signup_path = Keyword.get(opts, :signup_path, Keyword.get(opts, :path, "/signup"))
    verify_path = Keyword.get(opts, :verify_path, "/verify")
    reset_path = Keyword.get(opts, :reset_path, "/reset")
    login_path = Keyword.get(opts, :login_path, "/login")
    logout_path = Keyword.get(opts, :logout_path, "/logout")
    invite_path = Keyword.get(opts, :invite_path, "/invite")
    # ADR-035 §5 A7 — the 2FA interstitial, mounted UNCONDITIONALLY like
    # `/login` (never opt-in): a host with no credential ever enrolling 2FA
    # simply never reaches it (`SessionController.create/2` only redirects
    # here when `Credential.totp_enabled_at` is set).
    totp_path = Keyword.get(opts, :totp_path, "/2fa")
    session_name = Keyword.get(opts, :session_name, session_name(:auth, signup_path))

    # ADR-035 §5 A6 — the OPTIONAL OIDC module. `oidc:` names the enabled
    # providers (e.g. `oidc: [:google]`); an EMPTY/ABSENT list emits NO
    # `/auth/oidc` routes at all (the module-absent contract, done-criterion 2).
    # `oidc_config` is an OPTIONAL compile-time literal override handed to the
    # controller (mainly the test stub); `nil` → the controller falls back to
    # app env (`config :samen_web, Samen.Web.Auth.Oidc, providers: %{...}`).
    oidc_enabled? = Keyword.get(opts, :oidc, []) != []
    oidc_config = Keyword.get(opts, :oidc_config)
    oidc_base = Keyword.get(opts, :oidc_path, "/auth/oidc")

    quote bind_quoted: [
            opts: opts,
            signup_path: signup_path,
            verify_path: verify_path,
            reset_path: reset_path,
            login_path: login_path,
            logout_path: logout_path,
            invite_path: invite_path,
            totp_path: totp_path,
            session_name: session_name,
            oidc_enabled?: oidc_enabled?,
            oidc_config: oidc_config,
            oidc_base: oidc_base
          ] do
      mount =
        Samen.Web.Mount.new(
          :auth,
          Keyword.fetch!(opts, :namespace),
          Keyword.fetch!(opts, :repo),
          domain: Keyword.get(opts, :domain, Keyword.fetch!(opts, :namespace)),
          # T110 — the pre-actor LiveViews resolve their real `<form action=>`
          # off these labels so a host-overridden path stays consistent between
          # the GET `live(...)` and the paired POST controller route.
          labels: %{
            login_path: login_path,
            totp_path: totp_path,
            signup_path: signup_path,
            reset_path: reset_path,
            invite_path: invite_path,
            # T126 — `ConfirmLive` rebuilds its own `/verify/:token` path off this
            # label to redirect to the `?verified=1`/`?error=` status flag after
            # the single-use consume (the double-mount guard).
            verify_path: verify_path
          }
        )

      live_session session_name, session: %{"samen_mount" => Samen.Web.Mount.to_session(mount)} do
        live(signup_path, Samen.Web.Auth.RegistrationLive)
        live("#{verify_path}/:token", Samen.Web.Auth.ConfirmLive)
        live(reset_path, Samen.Web.Auth.ResetRequestLive)
        live("#{reset_path}/:token", Samen.Web.Auth.ResetLive)
        live(login_path, Samen.Web.Auth.LoginLive)
        live(totp_path, Samen.Web.Auth.TotpChallengeLive)
        live("#{invite_path}/:token", Samen.Web.Auth.InviteAcceptLive)
      end

      # ADR-035 §5 A4/A7 — sign-in/out/2fa-verify are plain controller writes
      # (a LiveView cannot set a cookie mid-mount): `private: %{samen_mount:
      # ..., samen_login_path: ..., samen_totp_path: ...}` gives the
      # controller the SAME per-host parameterization the live_session above
      # carries, without a hardcoded host module (the `samen_module_routes`
      # pattern, for a Plug route).
      post(login_path, Samen.Web.Auth.SessionController, :create,
        private: %{samen_mount: mount, samen_login_path: login_path, samen_totp_path: totp_path}
      )

      post(totp_path, Samen.Web.Auth.SessionController, :verify_totp,
        private: %{samen_mount: mount, samen_login_path: login_path, samen_totp_path: totp_path}
      )

      get(logout_path, Samen.Web.Auth.SessionController, :delete,
        private: %{samen_mount: mount, samen_login_path: login_path, samen_totp_path: totp_path}
      )

      # ADR-035 §5 A1/A3/A5 + T110 — the no-JS HTTP POST fallbacks for the
      # PRE-ACTOR identity LiveViews. Since ADR-042 the LiveView client ships, so
      # with JS these forms enhance in place; but this spine is Class A (ADR-042
      # §5) — its controller-POST fallback is a BINDING no-JS floor, so every
      # `phx-submit` form also degrades to a native HTML submit. Registration's
      # native submit was a **GET** — it leaked the plaintext password into the
      # URL query string (T110 escalation). Each POST below pairs a real
      # controller WRITE with the matching GET `live(...)` above, EXACTLY as
      # `login`/`2fa` already pair with `SessionController`, so every credential
      # (and the new/reset/invite password) rides the POST body, never the URL.
      # `Samen.Web.Auth.AccountController` re-runs the mutation server-side and
      # enforces the ADR-038 §6.3 rate limits at this authoritative site (a
      # no-JS POST bypasses the LiveView's inline guard entirely).
      post(signup_path, Samen.Web.Auth.AccountController, :register,
        private: %{samen_mount: mount, samen_signup_path: signup_path}
      )

      post(reset_path, Samen.Web.Auth.AccountController, :request_reset,
        private: %{samen_mount: mount, samen_reset_path: reset_path}
      )

      post("#{reset_path}/:token", Samen.Web.Auth.AccountController, :reset,
        private: %{samen_mount: mount, samen_reset_path: reset_path}
      )

      post("#{invite_path}/:token", Samen.Web.Auth.AccountController, :accept_invite,
        private: %{samen_mount: mount, samen_invite_path: invite_path}
      )

      # ADR-035 §5 A6 — the OPTIONAL OIDC request + callback endpoints, emitted
      # ONLY when `oidc:` named ≥1 provider. A host that did not opt in has NONE
      # of these routes (the module-absent probe). Plain controller routes (the
      # flow is cookie/session writes on real HTTP responses — the
      # SessionController precedent); `private:` carries the same per-host mount +
      # the OIDC provider config, so the controller never hardcodes a host module.
      if oidc_enabled? do
        get("#{oidc_base}/:provider/callback", Samen.Web.Auth.OidcController, :callback,
          private: %{
            samen_mount: mount,
            samen_login_path: login_path,
            samen_oidc_config: oidc_config
          }
        )

        get("#{oidc_base}/:provider", Samen.Web.Auth.OidcController, :request,
          private: %{
            samen_mount: mount,
            samen_login_path: login_path,
            samen_oidc_config: oidc_config
          }
        )
      end
    end
  end

  @doc """
  Mount the framework ONBOARDING WIZARD (ADR-035 §5 A8; spec §WS-A A8) —
  `GET /onboarding` → `Samen.Web.Onboarding.WizardLive` — in ONE line:

      import Samen.Web.Router

      scope "/" do
        pipe_through :browser
        samen_onboarding_routes Demo.Identity, repo: Demo.Repo
      end

  `namespace`/`:repo` are the SAME Identity mount `samen_auth_routes`/
  `samen_settings_routes` use (the mount rides the `:settings` scope_kind —
  the `samen_settings_routes`/T05 `InvitationsLive` precedent: the wizard
  reads/writes `Org` + embeds the invite step over the SAME materialized
  Identity resources, no new scope_kind needed). Tenant plane (ADR-035 §6 —
  own-org writes only).

  ## Options

    * `:repo`         — REQUIRED. The host's Ecto repo.
    * `:domain`        — the host Ash domain (default: `namespace`).
    * `:path`          — the mount path (default `/onboarding`).
    * `:plan_labels`   — OPTIONAL `{mod, fun, args}` — the WS-B billing
      hookup point (ADR-035 §5 A8/§7 INV-4). Called as `apply(mod, fun, args
      ++ [org_id])`, expected to return `[%{key:, label:}, ...]`. ABSENT →
      the wizard's plan-selection step renders the HONEST "no plans
      configured" empty state — never a fabricated plan list.
    * `:labels`        — optional additional UI copy overrides, merged under
      `:plan_labels`.
  """
  defmacro samen_onboarding_routes(namespace, opts \\ []) do
    path = Keyword.get(opts, :path, "/onboarding")
    session_name = Keyword.get(opts, :session_name, session_name(:onboarding, path))

    quote bind_quoted: [namespace: namespace, opts: opts, path: path, session_name: session_name] do
      labels =
        (Keyword.get(opts, :labels) || %{})
        |> Map.put(:plan_labels, Keyword.get(opts, :plan_labels))

      mount =
        Samen.Web.Mount.new(
          :settings,
          namespace,
          Keyword.fetch!(opts, :repo),
          domain: Keyword.get(opts, :domain, namespace),
          labels: labels
        )

      live_session session_name, session: %{"samen_mount" => Samen.Web.Mount.to_session(mount)} do
        live(path, Samen.Web.Onboarding.WizardLive)
      end

      # T110 — no-JS HTTP POST fallbacks for the wizard's Continue / Send-invite
      # / Finish actions (Samen ships no client JS, so the `phx-submit`/`phx-click`
      # controls are inert in a real browser — persona F2). Skip needs NO route:
      # it is a plain GET `<.link patch>` to the next step. Each write redirects
      # back to `GET #{path}?...&step=<next>`. `Samen.Web.Onboarding.WizardController`
      # reconstructs the SAME own-org actor scope WizardLive builds.
      post("#{path}/name_org", Samen.Web.Onboarding.WizardController, :name_org,
        private: %{samen_mount: mount, samen_onboarding_path: path}
      )

      post("#{path}/plan", Samen.Web.Onboarding.WizardController, :select_plan,
        private: %{samen_mount: mount, samen_onboarding_path: path}
      )

      post("#{path}/invite", Samen.Web.Onboarding.WizardController, :invite,
        private: %{samen_mount: mount, samen_onboarding_path: path}
      )

      post("#{path}/finish", Samen.Web.Onboarding.WizardController, :finish,
        private: %{samen_mount: mount, samen_onboarding_path: path}
      )
    end
  end

  @doc false
  # ADR-035 §5 A6 — the OIDC route table the `samen_auth_routes` macro emits, as a
  # pure function so the module-absent contract is directly unit-testable: an
  # EMPTY provider list yields NO routes (done-criterion 2), a non-empty one
  # yields the request + callback endpoints. `providers` is the `oidc:` opt.
  def __oidc_routes__(providers, base \\ "/auth/oidc")

  def __oidc_routes__([], _base), do: []
  def __oidc_routes__(nil, _base), do: []

  def __oidc_routes__(providers, base) when is_list(providers) do
    [
      {"#{base}/:provider/callback", Samen.Web.Auth.OidcController, :callback},
      {"#{base}/:provider", Samen.Web.Auth.OidcController, :request}
    ]
  end

  @doc """
  Mount the framework SESSION endpoint that writes the current org (ADR-013 §4.3) in ONE line.

      import Samen.Web.Router

      scope "/" do
        pipe_through :browser
        samen_session_routes()
      end

  Declares `GET /session/org/:org_id` → `Samen.Web.SessionController.put_current_org/2`, the
  target of the workspace switcher + the operator "Open account →" clear act-as. Every vertical
  inherits the same durable current-org write. `:path` overrides the default `/session/org`.
  """
  defmacro samen_session_routes(opts \\ []) do
    path = Keyword.get(opts, :path, "/session/org")

    quote bind_quoted: [path: path] do
      get("#{path}/:org_id", Samen.Web.SessionController, :put_current_org)
    end
  end

  @doc """
  Mount the framework Prometheus scrape endpoint (WS-F5 F5.1) — `GET /metrics` — in ONE
  line. Every vertical + generated app exposes the SAME `/metrics` surface at ~0 LOC.

      import Samen.Web.Router

      scope "/" do
        pipe_through :browser
        samen_metrics_route(name: :driftwood_prometheus)
      end

  `name` is the registered name of the Prometheus reporter `Samen.Observability` starts
  when the host's `metrics_egress?` flag is on (default `:\#{otp_app}_prometheus`). The
  route self-gates: with egress OFF (the default) the reporter is not running and the
  endpoint returns `404` — no dep is required to COMPILE this line, only to serve real
  metrics (see `Samen.Web.MetricsController`).

  Options:
    * `:name`     — the reporter's registered name (REQUIRED; must match the
      `prometheus_name` `Samen.Observability` was configured with).
    * `:reporter` — the reporter module (default
      `Samen.Web.MetricsController.default_reporter/0`, i.e.
      `TelemetryMetricsPrometheus.Core`).
    * `:path`     — the route path (default `/metrics`).
  """
  defmacro samen_metrics_route(opts \\ []) do
    path = Keyword.get(opts, :path, "/metrics")
    name_ast = Keyword.fetch!(opts, :name)
    reporter_ast =
      Keyword.get(opts, :reporter, quote(do: Samen.Web.MetricsController.default_reporter()))

    quote do
      get(unquote(path), Samen.Web.MetricsController, :scrape,
        private: %{samen_metrics: %{reporter: unquote(reporter_ast), name: unquote(name_ast)}}
      )
    end
  end

  @doc """
  Mount the D4 MCP server (ADR-043 §9; T69) — the `browse` / `search` / `drafts` /
  `action-proposals` tool surface for external agents — over an HTTP + SSE endpoint, in ONE
  line (INV-5). A bare `forward` (no `pipe_through`), so it carries NO browser session/CSRF:
  auth is the per-operator bearer token the `:actor_resolver` seam resolves (§9).

      import Samen.Web.Router

      samen_mcp_route(
        actor_resolver: {MyWeb.Api.KeyAuthPlug, :resolve_scope, []},
        tool_opts: [domains: [MyApp.Crm], repo: MyApp.Repo,
                    approval_resource: MyApp.Primitives.Approval,
                    kinds: MyApp.approval_kinds()]
      )

  Every tool response is EG4 egress masked by the chokepoint `:mcp` scrub in `Samen.AI.Mcp`
  (masked vault fields, no `vt_*` tokens, org-scoped); grants never unlock `:mcp`; and
  action-proposals never execute — they open a T34 approval for a human.

  ## `:actor_resolver` is MANDATORY — safe-by-construction (T142)

  There is **no insecure default**: `samen_mcp_route/1` REFUSES TO COMPILE (raises
  `ArgumentError` at macro expansion) unless `:actor_resolver` is wired. This is deliberate —
  the resolver IS the bearer-credential check, so an adopter can never accidentally ship a
  mount that authenticates nobody. (Even were the raise bypassed, the plug's
  `resolve_actor(nil, _)` still 401s every request — fail-closed at both layers.)

  A vertical adopter's resolver MUST be **constant-time and org-scoped**: compare the
  presented bearer token against the STORED per-operator token DIGEST via
  `Plug.Crypto.secure_compare/2` over SHA-256 (never `==` on the raw token — a byte-by-byte
  `==` is a timing oracle), and return a `%Samen.Scope{}` whose `org_id`/plane come from THAT
  token's owner so `Samen.AI.Mcp`'s hard org filter isolates tenants. The demo/driftwood
  `KeyAuthPlug.digest` lookup is the reference shape. Every adopter that mounts this MUST ship
  an end-to-end auth test over the live HTTP path: unauth ⇒ 401, forged ⇒ 401, and an
  org-A token cannot reach org-B data (ADR-043 §9; the T142 vertical-adoption contract).

  ## Options

    * `:actor_resolver` — **REQUIRED** (compile-time enforced). A `{module, function, args}`
      MFA (or 1-arity fun) taking the RAW bearer token and returning `{:ok, scope}` or
      anything else (⇒ 401). See the constant-time requirement above.
    * `:tool_opts` — the host wiring threaded to `Samen.AI.Mcp.handle_rpc/3`
      (`:domains`/`:resources`/`:repo`/`:approval_resource`/`:kinds`). A kw list, a 0-arity
      fun, or an `{m, f, a}` MFA (resolved per request).
    * `:path` — the mount path (default `/mcp`).
  """
  defmacro samen_mcp_route(opts \\ []) do
    __require_actor_resolver__!(opts)
    path = Keyword.get(opts, :path, "/mcp")
    plug_opts = Keyword.take(opts, [:actor_resolver, :tool_opts])

    quote do
      forward(unquote(path), Samen.Web.AI.McpPlug, unquote(plug_opts))
    end
  end

  @doc false
  # T142: refuse (at compile time) to mount an MCP route with no `:actor_resolver` — the
  # seam that authenticates the bearer token. No insecure default; an adopter must wire a
  # real constant-time, org-scoped resolver (see the macro moduledoc). Called from the macro
  # body (expansion time), so a missing resolver fails the BUILD, not a runtime request.
  def __require_actor_resolver__!(opts) do
    unless Keyword.keyword?(opts) and Keyword.has_key?(opts, :actor_resolver) do
      raise ArgumentError,
            "samen_mcp_route/1 requires an :actor_resolver — the per-operator bearer-token " <>
              "check. There is no insecure default: wire a constant-time, org-scoped resolver " <>
              "(Plug.Crypto.secure_compare over a stored SHA-256 digest; see " <>
              "Samen.Web.Router.samen_mcp_route/1 docs) before mounting. Got: #{inspect(opts)}"
    end

    :ok
  end

  @doc false
  def __operator_labels__(labels, nil), do: labels

  def __operator_labels__(labels, operator_org_id),
    do: Map.put(labels, :operator_org_id, operator_org_id)

  @doc false
  def __fleet_namespace_label__(labels, nil), do: labels
  def __fleet_namespace_label__(labels, fleet_namespace), do: Map.put(labels, :fleet_namespace, fleet_namespace)

  @doc false
  def __fleet_cockpit_label__(labels, false), do: labels
  def __fleet_cockpit_label__(labels, true), do: Map.put(labels, :fleet_cockpit, true)

  @doc false
  def __plane__(opts) do
    case Keyword.get(opts, :plane, :tenant) do
      :operator ->
        Samen.Web.Plane.operator(
          Keyword.get(opts, :operator_id, "operator"),
          Keyword.get(opts, :target_org_id),
          Keyword.get(opts, :session_id)
        )

      _ ->
        Samen.Web.Plane.tenant()
    end
  end

  @doc false
  def __routes__(:crm, path) do
    [
      {"#{path}/companies", Samen.Web.CRM.CompaniesLive},
      {"#{path}/companies/:id", Samen.Web.CRM.CompanyLive},
      {"#{path}/contacts", Samen.Web.CRM.ContactsLive},
      {"#{path}/contacts/:id", Samen.Web.CRM.ContactLive},
      {"#{path}/gallery", Samen.Web.CRM.ContactsGalleryLive},
      {"#{path}/pipeline", Samen.Web.CRM.PipelineLive},
      {"#{path}/calendar", Samen.Web.CRM.CalendarLive},
      {"#{path}/dashboard", Samen.Web.CRM.DashboardLive},
      # T74 §I1 — the two-way email-sync connect seam + its HONEST empty state.
      {"#{path}/mailbox", Samen.Web.CRM.MailboxLive}
    ]
  end

  def __routes__(:billing, path) do
    [
      {"#{path}", Samen.Web.Billing.OverviewLive},
      {"#{path}/invoices", Samen.Web.Billing.InvoicesLive},
      {"#{path}/dunning", Samen.Web.Billing.DunningLive},
      {"#{path}/plans", Samen.Web.Billing.PlansLive},
      # B10/T26 — the billing SETTINGS page: plan picker + T23 hosted payment-method
      # portal + T22 invoice history when `Samen.Billing.Provider.configured?/1` is
      # true, the honest "bring your billing" empty state when false. Inherited by
      # every host that already calls `samen_module_routes(:billing, ...)` — zero
      # template/gen.app changes needed (ADR-038 §3.5 B10).
      {"#{path}/settings", Samen.Web.Billing.SettingsLive}
    ]
  end

  def __routes__(:support, path) do
    [
      {"#{path}", Samen.Web.Support.TicketsLive},
      {"#{path}/tickets/:id", Samen.Web.Support.TicketLive},
      # T78 (spec §I5) — the agent-facing KB surface (browse/author articles, list +
      # edit-modal — the `Samen.Web.Flags.SettingsLive` single-page shape). Reads
      # the host's CMS namespace via the `:kb_namespace` mount label (the
      # `flags_namespace`/`crm_namespace` sibling-mount seam); the honest "KB not
      # adopted" empty state renders when a host hasn't wired the label.
      {"#{path}/kb", Samen.Web.Support.KbLive}
    ]
  end

  # T78 (spec §I5) — the UNAUTHENTICATED tenant-portal route table: KB browse +
  # search (self-serve deflection) + a draft-ticket form that surfaces matching
  # articles BEFORE submit. Mounted DIRECTLY at the host's CMS namespace (no
  # Support needed — the portal never touches `Ticket`). A host wires this in a
  # PUBLIC router scope (no auth pipeline/on_mount), the same posture as
  # `samen_auth_routes` — never `samen_operator_routes`'s auth-gated one:
  #
  #     scope "/", DriftwoodWeb do
  #       pipe_through :browser
  #       samen_module_routes :kb, Driftwood.Cms, repo: Driftwood.Repo, path: "/portal"
  #     end
  def __routes__(:kb, path) do
    [
      {"#{path}/:org", Samen.Web.Support.PortalKbLive}
    ]
  end

  # T79 (spec §I6) — the UNAUTHENTICATED CSAT survey-response route table:
  # a single-use tokenized link (`GET /support/csat/:token`) mounted DIRECTLY
  # at the host's Support namespace (the token match IS the entire
  # authorization surface — org/ticket are derived FROM it, never a URL/
  # session org param). Mounted the SAME public posture as `:kb`:
  #
  #     scope "/", DriftwoodWeb do
  #       pipe_through :browser
  #       samen_module_routes :csat, Driftwood.Support, repo: Driftwood.Repo
  #     end
  def __routes__(:csat, path) do
    [
      {"#{path}/:token", Samen.Web.Support.CsatRespondLive}
    ]
  end

  # F1 / ADR-041 §3 (T43) — the Work scope route table: the task inbox (list/detail)
  # + the project list. Mirrors :support's shape (mount via `samen_module_routes
  # :work, HostNamespace, repo: ...` — there is no bespoke `samen_work_routes` macro,
  # same as :support/:crm/:billing use the generic macro, not a per-kind one).
  def __routes__(:work, path) do
    [
      {"#{path}", Samen.Web.Work.TasksLive},
      {"#{path}/tasks/:id", Samen.Web.Work.TaskLive},
      {"#{path}/projects", Samen.Web.Work.ProjectsLive},
      {"#{path}/timeline", Samen.Web.Work.TimelineLive},
      {"#{path}/tree", Samen.Web.Work.TaskTreeLive}
    ]
  end

  # ADR-011 §7 — the Marketing / outreach route table. Mounts the previously-unmounted
  # Marketing scope's surfaces: a campaigns/sequences list, a compose+send campaign page,
  # a segments/prospecting view, and a leads lens.
  def __routes__(:marketing, path) do
    [
      {"#{path}/campaigns", Samen.Web.Marketing.CampaignsLive},
      {"#{path}/campaigns/:id", Samen.Web.Marketing.CampaignLive},
      {"#{path}/segments", Samen.Web.Marketing.SegmentsLive},
      {"#{path}/leads", Samen.Web.Marketing.LeadsLive}
    ]
  end

  # ADR-012 §6.3 — the flagship chat route table: the inbox + the realtime room.
  def __routes__(:chat, path) do
    [
      {"#{path}", Samen.Web.Chat.ThreadsLive},
      {"#{path}/:id", Samen.Web.Chat.ThreadLive}
    ]
  end

  # WS-A A4 (ADR-016 §4) — the notifications inbox + settings route table.
  def __routes__(:notifications, path) do
    [
      {"#{path}", Samen.Web.Notifications.InboxLive},
      {"#{path}/settings", Samen.Web.Notifications.PreferencesLive}
    ]
  end

  # WS-B B6 (ADR-020 §2 / design G6 §3.5) — the tenant flag-admin route table.
  def __routes__(:flags, path) do
    [
      {"#{path}", Samen.Web.Flags.SettingsLive}
    ]
  end

  # WS-E E2.1 (ADR-026) — the files surface route table: upload+list + preview.
  # The byte-serve route (/files/:id/bytes → BytesController) is mounted separately
  # in `samen_files_routes/3` (it is a controller route, not a LiveView).
  def __routes__(:files, path) do
    [
      {"#{path}", Samen.Web.Files.UploadLive},
      {"#{path}/:id", Samen.Web.Files.PreviewLive}
    ]
  end

  # WS-E E3.4 (ADR-028) — the CSV surface route table: the import LiveView.
  # The export download (/csv/export/:resource → ExportController) is mounted
  # separately in `samen_csv_routes/3` (a controller route, not a LiveView).
  def __routes__(:csv, path) do
    [
      {"#{path}/import/:resource", Samen.Web.Csv.ImportLive}
    ]
  end

  # WS-E E4.3 (ADR-027) — the ⌘K search surface route table: the one search page.
  def __routes__(:search, path) do
    [
      {"#{path}", Samen.Web.Search.SearchLive}
    ]
  end

  # WS-E E5 (ADR-029) — the self-serve settings route table: profile (the index),
  # API keys, and the read-only security view. Three surfaces, one macro mount.
  def __routes__(:settings, path) do
    [
      {"#{path}", Samen.Web.Settings.ProfileLive},
      {"#{path}/profile", Samen.Web.Settings.ProfileLive},
      {"#{path}/api-keys", Samen.Web.Settings.ApiKeysLive},
      {"#{path}/security", Samen.Web.Settings.SecurityLive},
      {"#{path}/invitations", Samen.Web.Settings.InvitationsLive}
    ]
  end

  # T118 (ADR-039 §12) — the tenant-plane automation builder route table: ONE
  # LiveView, list + author/edit + pause/resume + manual run, all in one page
  # (the `Samen.Web.Flags.SettingsLive` shape — a list with an edit-modal, not a
  # separate list/detail pair).
  def __routes__(:automation, path) do
    [
      {"#{path}", Samen.Web.Automation.BuilderLive}
    ]
  end

  defp default_path(:crm), do: "/crm"
  defp default_path(:billing), do: "/billing"
  defp default_path(:support), do: "/support"
  defp default_path(:work), do: "/work"
  defp default_path(:marketing), do: "/marketing"
  defp default_path(:chat), do: "/chat"
  defp default_path(:notifications), do: "/notifications"
  defp default_path(:flags), do: "/flags"
  defp default_path(:search), do: "/search"
  defp default_path(:settings), do: "/settings"
  defp default_path(:automation), do: "/automation"
  # T78 (spec §I5) — the unauthenticated tenant-portal path.
  defp default_path(:kb), do: "/portal"
  # T79 (spec §I6) — the unauthenticated CSAT survey-response path.
  defp default_path(:csat), do: "/support/csat"

  defp session_name(kind, path) do
    :"samen_#{kind}_#{path |> String.replace(~r/[^a-zA-Z0-9]/, "_") |> String.trim("_")}"
  end
end
