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

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:put_root_layout, html: {PawChartWeb.Layouts, :root})
    plug(:protect_from_forgery)
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
    # IDENTITY namespace (`User`/`ApiKey`/`Membership`), and PawChart materializes no
    # `Samen.Scopes.Identity` scope (it has no operator/account book — the clinic is a
    # single-tenant dogfood). Mounting settings would require first materializing an
    # Identity scope (new abbrev-owning resources via the sanctioned allocator), which is
    # beyond an ≈0-LOC adoption. Recorded honestly in docs/gate-ws-e.md (E7.1 mount matrix).
  end
end
