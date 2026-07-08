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
  `live_session`, and declares all operator routes (Accounts · Platform billing · Desk).

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
        live("#{path}/billing", Samen.Web.Operator.PlatformBillingLive)
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

  defp default_path(:crm), do: "/crm"
  defp default_path(:billing), do: "/billing"
  defp default_path(:support), do: "/support"
  defp default_path(:marketing), do: "/marketing"
  defp default_path(:chat), do: "/chat"

  defp session_name(kind, path) do
    :"samen_#{kind}_#{path |> String.replace(~r/[^a-zA-Z0-9]/, "_") |> String.trim("_")}"
  end
end
