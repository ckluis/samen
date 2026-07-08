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

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:put_root_layout, html: {DriftwoodWeb.Layouts, :root})
    plug(:protect_from_forgery)
  end

  pipeline :api do
    plug(:accepts, ["json"])
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

    # The freight vertical 20% (stays driftwood-local — freight-shaped resources).
    live("/broker", BrokerLive)
    live("/operator/impersonate", OperatorImpersonationLive)
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

    samen_module_routes(:crm, Driftwood.Crm, repo: Driftwood.Repo)
    samen_module_routes(:billing, Driftwood.Billing, repo: Driftwood.Repo)
    samen_module_routes(:support, Driftwood.Support, repo: Driftwood.Repo)

    # ADR-011 §7 — the Marketing / outreach surface (campaigns · segments · leads), mounted
    # over Driftwood's materialized Marketing scope resources. The `:crm_namespace` label lets
    # the Leads lens read CRM contacts by lifecycle_stage through the same PiiResolution seam.
    samen_module_routes(:marketing, Driftwood.Marketing,
      repo: Driftwood.Repo,
      labels: %{crm_namespace: Driftwood.Crm}
    )

    # ADR-012 — the FLAGSHIP cross-plane realtime CHAT, TENANT plane (the org's own chat
    # console — bodies + participant identities in the clear). The `:object_cards` label
    # registers Driftwood's bespoke `freight.driver` unfurl card (the vertical override seam);
    # every OTHER catalogued resource (`crm.person`, `support.ticket`, …) unfurls via the
    # framework default/first-class cards with zero cards written. `:pubsub` names the running
    # PubSub server for the realtime path.
    samen_chat_routes(:chat, Driftwood.Chat,
      repo: Driftwood.Repo,
      labels: %{
        title: "Blue Ridge Logistics",
        crumb_root: "Blue Ridge Logistics",
        pubsub: Driftwood.PubSub,
        object_cards: %{"freight.driver" => DriftwoodWeb.Chat.DriverCard}
      }
    )

    # ADR-012 §6.3 — the SAME chat LiveViews on the OPERATOR-DESK plane. The SaaS operator
    # drills into a tenant's cross-plane threads through the impersonation bridge (§2.3),
    # carrying the tenant org_id (supplied by `?org=<tenant>` for the dogfood). Bodies +
    # participant identities render `••••` unless the tenant has disclosed (the 3-state model).
    # A tenant chat and a SaaS-desk chat are the SAME LiveViews on different planes.
    samen_chat_routes(:chat, Driftwood.Chat,
      repo: Driftwood.Repo,
      plane: :operator,
      operator_id: "driftwood-operator",
      path: "/operator/desk-chat",
      labels: %{
        title: "Driftwood Ops",
        crumb_root: "Driftwood Ops",
        chat_path: "/operator/desk-chat",
        pubsub: Driftwood.PubSub,
        object_cards: %{"freight.driver" => DriftwoodWeb.Chat.DriverCard}
      }
    )
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
                         aggregate_loader: {Driftwood.OperatorAggregate, :load, []}
                       }
                     )
                   )

  # BARE `scope "/"` (see the CRM/Billing/Support note above): the aggregate LiveView is
  # the framework's fully-qualified module.
  scope "/" do
    pipe_through(:browser)

    live_session :driftwood_operator_aggregate,
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
    pipe_through(:browser)

    samen_operator_routes(Driftwood.Operator,
      repo: Driftwood.Repo,
      operator_org_id: "0f000000-0000-4000-8000-0000000000aa",
      include_aggregate: false,
      labels: %{operator_workspace: "Driftwood Ops", operator_glyph: "D"}
    )
  end
end
