defmodule Samen.Web.Support.KbReads do
  @moduledoc """
  T78 (spec §I5 helpdesk knowledge base + composer suggestion + deflection) — the
  read/write layer for the KB surface. The KB article IS `Cms.Post` (a `visibility`
  attribute distinguishes internal from public, see
  `Samen.Scopes.Cms.Blueprint.define_post/5`) — this module never defines a
  parallel article resource.

  ## Two distinct namespaces, one sibling-mount seam

  The Support ticket composer and the CMS article live in DIFFERENT scopes
  (different Ash domains in a real host). `kb_mount/1` derives a sibling
  `Samen.Web.Mount` pointing at the host's CMS namespace via the `:kb_namespace`
  label — the SAME seam `Samen.Web.Operator.FlagAdminLive.flags_mount/1` uses for
  `:flags_namespace` (`crm_namespace`'s pattern, generalized). A host wires it with
  ONE label on its `samen_module_routes :support, ...` call:

      samen_module_routes :support, Driftwood.Support,
        repo: Driftwood.Repo,
        labels: %{kb_namespace: Driftwood.Cms}

  ## Two read paths, two authorization postures

    * `articles/2` — the AGENT view (org-scoped `Samen.Scope`, the default `:read`
      action + `OrgScope` policy). Sees BOTH internal and public articles,
      any status. This is the "internal article visible to agents" control.
    * `public_articles/2` — the PORTAL view (`Post.read_public`, no actor, an
      explicit `org_id`). Sees ONLY `visibility: :public, status: :published`
      articles — the action's own baked-in filter is the ENTIRE authorization
      surface (see `Samen.Scopes.Cms.PublicPostFilter`).

  ## AI-plane KB suggestion + deflection (D3, ADR-043 §7; T78)

  `suggest_for_agent/3` and `suggest_for_portal/3` both ride
  `Samen.AI.Embeddings.search/3` (never `Samen.AI.Provider`/`MaskedPayload`
  directly — the chokepoint anti-bypass probe covers this file exactly like any
  other `samen_core`/`samen_web` module). The vector index is CANDIDATE
  RETRIEVAL ONLY: every hit is RE-VERIFIED against the caller's own scoped read
  action before ever being rendered, so a stale or over-broad vector can never
  surface content the reader is not otherwise authorized to see (defense in
  depth — the T74-T77 masking-watch-list discipline, generalized to a derived
  index instead of a vault). Honest states, never a fabricated suggestion:

    * `:ok` — real hits (embedder configured, `simulated: false`) or the keyless
      `:test`-only deterministic ranking (`simulated: true`, clearly signposted —
      the T152 mechanism, mirrored onto the embeddings lane by
      `Samen.AI.Embeddings.embedder_simulated?/1`).
    * `:empty` — the embedder ran, found nothing (never a match-all default).
    * `:not_configured` — no AI provider wired; `configuration_hint` carries
      `Samen.AI.configuration_hint()` verbatim (never fabricated advice).
  """

  require Ash.Query

  alias Samen.AI.Embeddings
  alias Samen.Web.Mount

  @suggest_limit 5

  # --- namespace bridging (the flags_namespace / crm_namespace seam) -----------------------

  @doc """
  Derive the sibling CMS-namespace mount from the `:kb_namespace` label on a Support (or any)
  mount. `nil` when the host never wired the label — the honest "KB not adopted here" state
  every consumer must render (never a crash on a vertical that hasn't opted in yet).
  """
  @spec kb_mount(Mount.t() | nil) :: Mount.t() | nil
  def kb_mount(nil), do: nil

  def kb_mount(%Mount{} = mount) do
    case Mount.label(mount, :kb_namespace, nil) do
      ns when is_atom(ns) and not is_nil(ns) -> %{mount | namespace: ns, scope_kind: :kb}
      _ -> nil
    end
  end

  # --- agent view (org-scoped, sees internal + public) --------------------------------------

  @doc "All KB articles (internal + public, any status) visible to an org-scoped agent actor."
  def articles(kb_mount, scope) do
    Mount.resource(kb_mount, Post)
    |> Ash.Query.sort(updated_at: :desc)
    |> Ash.Query.limit(200)
    |> Ash.read!(scope: scope)
  end

  def get_article(kb_mount, scope, id) do
    Mount.resource(kb_mount, Post)
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(scope: scope)
  end

  def new_article_form(kb_mount, scope) do
    Mount.resource(kb_mount, Post)
    |> AshPhoenix.Form.for_create(:create, scope: scope)
    |> Phoenix.Component.to_form()
  end

  def edit_article_form(_kb_mount, scope, article) do
    article
    |> AshPhoenix.Form.for_update(:update, scope: scope)
    |> Phoenix.Component.to_form()
  end

  @doc """
  The tenant-ADMIN write scope for the kernel's admin-gated `:publish`/`:mark_archived`
  actions (`Post` carries `RoleAtLeast :admin`; the mount's plane scope is `:member`).

  ADR-045 §4.4 (S1a) — delegates to `Samen.Web.TenantRole.admin_scope/3`: the disarmed dev
  posture keeps `:admin` byte-for-byte; an ARMED host derives the principal's REAL
  `Identity.Membership` role (fail-closed `:member`, never `:admin`). PRESERVES every plane marker
  from `Mount.scope/2` (an operator-plane mount keeps `plane: :operator`), so the elevation raises
  RBAC rank only, never the masking plane.
  """
  def write_scope(kb_mount, org_id, principal \\ nil),
    do: Samen.Web.TenantRole.admin_scope(kb_mount, org_id, principal)

  @doc """
  Publish an article (admin-gated by the kernel — `write_scope/2` elevates for the
  actual `:publish` write; the lookup itself only needs the ordinary member-scoped
  read) — best-effort reindex on success. The armed host's REAL membership role is derived from
  the principal stashed on `kb_mount` by `Samen.Web.Live.assign_mount/2` (ADR-045 §4.4).
  """
  def publish_article(kb_mount, org_id, id) do
    read_scope = Mount.scope(kb_mount, org_id)

    case get_article(kb_mount, read_scope, id) do
      nil ->
        {:error, :not_found}

      post ->
        admin_scope = write_scope(kb_mount, org_id)

        case post |> Ash.Changeset.for_update(:publish, %{}, scope: admin_scope) |> Ash.update() do
          {:ok, published} ->
            reindex(admin_scope, published)
            {:ok, published}

          {:error, _} = err ->
            err
        end
    end
  end

  # Best-effort semantic reindex (T78) — never blocks a write on the AI plane's
  # availability. `:not_configured`/any error is swallowed; the article still
  # saved correctly, it simply is not yet semantically searchable (honest
  # degradation, not a fabricated success).
  defp reindex(scope, %{__struct__: resource} = post) do
    Embeddings.embed_record(scope, post, resource, [])
    :ok
  rescue
    _ -> :ok
  end

  # --- portal view (unauthenticated, sees ONLY public+published) ----------------------------

  @doc "Public, published KB articles for `org_id` — the unauthenticated portal read."
  def public_articles(kb_mount, org_id) do
    Mount.resource(kb_mount, Post)
    |> Ash.Query.for_read(:read_public, %{org_id: org_id})
    |> Ash.Query.sort(updated_at: :desc)
    |> Ash.read!(actor: nil, authorize?: true)
  end

  # --- AI-plane suggestion (composer) + deflection (portal) ----------------------------------

  @doc """
  Composer suggestion (T78): semantically-relevant KB articles for a ticket's `subject`
  (non-PII — the ticket header carries no 🔒 field; `message.body` is vault-routed and
  deliberately NOT fed to the AI plane here, out of scope for T78's suggestion seam).
  Hits are RE-VERIFIED against the agent's own org-scoped read (sees internal + public).
  """
  @spec suggest_for_agent(Mount.t() | nil, term(), String.t(), keyword()) :: map()
  def suggest_for_agent(kb_mount, scope, query, opts \\ [])
  def suggest_for_agent(nil, _scope, _query, _opts), do: %{state: :no_kb_namespace, hits: []}

  def suggest_for_agent(kb_mount, scope, query, opts) when is_binary(query) do
    with_hits(
      scope,
      query,
      fn hit_ids ->
        Mount.resource(kb_mount, Post)
        |> Ash.Query.filter(id in ^hit_ids)
        |> Ash.read!(scope: scope)
      end,
      opts
    )
  end

  @doc """
  Deflection (T78): semantically-relevant KB articles for a requester's draft ticket
  subject/description, BEFORE they submit. Hits are RE-VERIFIED against `read_public`
  (org_id, published+public ONLY) — an internal article can never surface here even if a
  stale vector still references it (defense in depth, see moduledoc).
  """
  @spec suggest_for_portal(Mount.t() | nil, String.t(), String.t(), keyword()) :: map()
  def suggest_for_portal(kb_mount, org_id, query, opts \\ [])
  def suggest_for_portal(nil, _org_id, _query, _opts), do: %{state: :no_kb_namespace, hits: []}

  def suggest_for_portal(kb_mount, org_id, query, opts) when is_binary(query) do
    with_hits(
      org_id,
      query,
      fn hit_ids ->
        Mount.resource(kb_mount, Post)
        |> Ash.Query.for_read(:read_public, %{org_id: org_id})
        |> Ash.Query.filter(id in ^hit_ids)
        |> Ash.read!(actor: nil, authorize?: true)
      end,
      opts
    )
  end

  # `scope_or_org_id`: a `%Samen.Scope{}` (agent path, org_id derived from the actor) or a
  # raw org_id STRING (portal path — `Samen.AI.Embeddings.search/3`'s `extract_org/1` accepts
  # both shapes). `refetch` re-verifies every hit against the CALLER's own scoped read. `opts`
  # forwards to BOTH `Embeddings.search/3` and `Embeddings.embedder_simulated?/1` (test-only:
  # `:env_reader`, `:embedder`, `:repo` — never set outside a test).
  defp with_hits(scope_or_org_id, query, refetch, opts) when is_function(refetch, 1) do
    case Embeddings.search(scope_or_org_id, query, Keyword.put(opts, :limit, @suggest_limit)) do
      {:ok, []} ->
        %{state: :empty, hits: []}

      {:ok, raw_hits} ->
        {:ok, simulated} = simulated_or_false(Embeddings.embedder_simulated?(opts))
        by_id = Map.new(raw_hits, &{&1.source_id, &1})

        articles =
          raw_hits
          |> Enum.map(& &1.source_id)
          |> refetch.()
          # Preserve rank order (nearest first) — the refetch does not.
          |> Enum.sort_by(&Map.get(by_id, &1.id).distance)

        if articles == [] do
          %{state: :empty, hits: []}
        else
          %{
            state: :ok,
            simulated: simulated,
            hits: Enum.map(articles, &%{article: &1, snippet: Map.get(by_id, &1.id).snippet})
          }
        end

      {:error, :not_configured} ->
        %{state: :not_configured, hits: [], configuration_hint: Samen.AI.configuration_hint()}

      {:error, _other} ->
        %{state: :error, hits: []}
    end
  end

  defp simulated_or_false({:ok, bool}), do: {:ok, bool}
  defp simulated_or_false({:error, _}), do: {:ok, false}
end
