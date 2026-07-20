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
        samen_operator_routes Driftwood.Operator, repo: Driftwood.Repo
      end

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
    * `:path`            — the mount path prefix (default `/operator`).
    * `:labels`          — optional UI copy overrides (operator workspace title/glyph, etc.).
    * `:include_aggregate` — also mount the `aggregate` page on THIS operator mount (default
      `false`). A host that already wires its own token-blind aggregate (a vertical-shaped
      projection via `aggregate_loader:`) mounts it separately and leaves this `false`, so the
      route is not declared twice.
    * `:session_name`    — override the `live_session` name (default `:samen_operator`).
  """
  defmacro samen_operator_routes(namespace, opts \\ []) do
    path = Keyword.get(opts, :path, "/operator")
    session_name = Keyword.get(opts, :session_name, :samen_operator)
    include_aggregate = Keyword.get(opts, :include_aggregate, false)

    quote bind_quoted: [
            namespace: namespace,
            opts: opts,
            path: path,
            session_name: session_name,
            include_aggregate: include_aggregate
          ] do
      operator_labels =
        (Keyword.get(opts, :labels) || %{})
        |> Samen.Web.Router.__operator_labels__(Keyword.get(opts, :operator_org_id))

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

      live_session session_name, session: %{"samen_mount" => Samen.Web.Mount.to_session(mount)} do
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

        if include_aggregate do
          live("#{path}/aggregate", Samen.Web.Operator.AggregateLive)
        end
      end
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

      live_session session_name, session: %{"samen_mount" => Samen.Web.Mount.to_session(mount)} do
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

  The current user is host-supplied (auth is host-owned): an explicit `?user=` param,
  else `session["samen_current_user"]`, else `Mount.label(mount, :current_user_id)`.

  Options: as `samen_files_routes/3` (`:repo` required; `:domain`, `:plane`,
  `:operator_id`/`:target_org_id`, `:path` (default `/settings`), `:labels`,
  `:session_name`).
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

      mount =
        Samen.Web.Mount.new(
          :settings,
          namespace,
          Keyword.fetch!(opts, :repo),
          domain: Keyword.get(opts, :domain, namespace),
          plane: Samen.Web.Router.__plane__(opts),
          labels: Keyword.get(opts, :labels)
        )

      live_session session_name, session: %{"samen_mount" => Samen.Web.Mount.to_session(mount)} do
        for {sub_path, module} <- Samen.Web.Router.__routes__(:settings, path) do
          live(sub_path, module)
        end
      end
    end
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

  @doc false
  def __operator_labels__(labels, nil), do: labels

  def __operator_labels__(labels, operator_org_id),
    do: Map.put(labels, :operator_org_id, operator_org_id)

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
      {"#{path}/pipeline", Samen.Web.CRM.PipelineLive}
    ]
  end

  def __routes__(:billing, path) do
    [
      {"#{path}", Samen.Web.Billing.OverviewLive},
      {"#{path}/invoices", Samen.Web.Billing.InvoicesLive},
      {"#{path}/plans", Samen.Web.Billing.PlansLive}
    ]
  end

  def __routes__(:support, path) do
    [
      {"#{path}", Samen.Web.Support.TicketsLive},
      {"#{path}/tickets/:id", Samen.Web.Support.TicketLive}
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
      {"#{path}/security", Samen.Web.Settings.SecurityLive}
    ]
  end

  defp default_path(:crm), do: "/crm"
  defp default_path(:billing), do: "/billing"
  defp default_path(:support), do: "/support"
  defp default_path(:marketing), do: "/marketing"
  defp default_path(:chat), do: "/chat"
  defp default_path(:notifications), do: "/notifications"
  defp default_path(:flags), do: "/flags"
  defp default_path(:search), do: "/search"
  defp default_path(:settings), do: "/settings"

  defp session_name(kind, path) do
    :"samen_#{kind}_#{path |> String.replace(~r/[^a-zA-Z0-9]/, "_") |> String.trim("_")}"
  end
end
