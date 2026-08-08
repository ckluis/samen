defmodule Samen.Web.AI.Server do
  @moduledoc """
  The context seam behind the tenant-plane AI UI kit (T155, ADR-043 §5.3 ≈0-LOC adoption).
  Every AI LiveView in `Samen.Web.AI.*` calls THIS module; this module calls ONLY the
  `Samen.AI` kernel surfaces (`Samen.AI.Verbs`, `Samen.AI.Embeddings`, `Samen.AI.Crm`,
  `Samen.AI.Analytics`, `Samen.AI.SupportOperator`) — never a `Samen.AI.Provider` callback
  and never `%Samen.AI.MaskedPayload{}`. So every provider-bound byte the UI produces routes
  through `Samen.AI.Chokepoint` by construction (INV-7): the full-tree
  `Samen.AI.ChokepointAntiBypassProbeTest` scans `samen_web/lib` too, so a raw provider call
  introduced here would flip it exactly like one in a verb module (RP-AI-1). The UI cannot
  become a PII-egress path the plane's chokepoint does not see.

  ## Scope is the caller's REAL scope (INV-2)

  Every function builds the scope from the mount's plane via `Samen.Web.Mount.scope/2` — the
  same actor every other framework read surface runs on. The AI plane never elevates: a
  tenant-plane mount reads clear over its OWN org (masked egress to the provider per §6.1);
  an operator-plane mount reads masked. No function here substitutes or synthesizes an actor.

  ## Org-scope pins (deny-by-default, drop-filter-flips-a-test)

  The two reads THIS module owns — `crm_preview/4` (the grounded record the CRM surface
  renders) and `list_drafts/2` — filter `org_id == ^org` from the TRUSTED scope, never from
  params. Dropping either filter flips a named cross-org test. The remaining reads
  (`search/3`, the CRM verbs, analytics) org-scope inside the kernel already.
  """

  alias Samen.AI
  alias Samen.AI.Embeddings
  alias Samen.Web.Mount

  require Ash.Query

  @type result :: {:ok, Samen.AI.Completion.t()} | {:error, term()}

  @doc "The verb names the Verbs surface exposes (the six ADR-043 §7.5 intelligence verbs)."
  @spec verbs() :: [atom()]
  def verbs, do: Samen.AI.Verbs.verbs()

  @doc """
  The human-facing provider-config pointer (`Samen.AI.configuration_hint/0`), rendered
  VERBATIM by every surface's `:not_configured` state. The machine error stays the bare
  `{:error, :not_configured}` atom — this is the additive DX guidance path, never the error
  term (T152).
  """
  @spec configuration_hint() :: String.t()
  def configuration_hint, do: AI.configuration_hint()

  # --- Verbs surface (the six verbs over free text / a record's pasted content) ------------

  @doc """
  Run one of the six verbs in the mount's scope over `input` (free text — the record's own
  content, §3.2 step 2d user-consented keystrokes). `params` are extra `{{key}}` template
  substitutions (e.g. `%{labels: "billing, sales"}` for classify). Returns the kernel
  `complete/4` result verbatim (fail-honest `{:error, :not_configured}` when unwired).
  """
  @spec run_verb(Mount.t(), String.t() | nil, atom(), String.t(), map(), keyword()) :: result()
  def run_verb(mount, org_id, verb, input, params \\ %{}, opts \\ [])
      when is_atom(verb) and is_binary(input) do
    Samen.AI.Verbs.run(verb, scope(mount, org_id), input, Keyword.merge([params: params], opts))
  end

  # --- Semantic search surface (T152 Hit snippets + the simulated ranking badge) -----------

  @doc """
  Org-scoped semantic search. Returns `{search_result, simulated?}` where `search_result`
  is `{:ok, [%Samen.AI.Embeddings.Hit{}]}` | `{:error, term()}` and `simulated?` is the
  T78/T152 honesty flag for the ranking (`Samen.AI.Embeddings.embedder_simulated?/1`) — the
  UI renders an honest "simulated ranking" badge from it, never a confident-looking real
  result. Cross-org rows are never ranked (the `Embeddings.search/3` `aie_org_id` filter).
  """
  @spec search(Mount.t(), String.t() | nil, String.t(), keyword()) ::
          {{:ok, [Embeddings.Hit.t()]} | {:error, term()}, boolean()}
  def search(mount, org_id, query, opts \\ []) when is_binary(query) do
    search_opts = Keyword.merge([repo: mount.repo], opts)
    result = Embeddings.search(scope(mount, org_id), query, search_opts)

    simulated? =
      case Embeddings.embedder_simulated?(search_opts) do
        {:ok, sim} -> sim
        {:error, _} -> false
      end

    {result, simulated?}
  end

  # --- CRM-AI surface (D6 helpers on a named record — masked-path, org-scoped) -------------

  @crm_helpers [:summarize_timeline, :classify_inbound, :recommend_next_step, :draft_sequence]

  @doc "The CRM-AI helper names the CRM surface exposes (ADR-043 §6.4)."
  @spec crm_helpers() :: [atom()]
  def crm_helpers, do: @crm_helpers

  @doc """
  Run a CRM-AI helper. `:classify_inbound` runs over free text (`input`); the other three
  ground on the named CRM `resource` + `id` (read org-scoped by `Samen.AI.Crm`, every
  vault-routed field `••••`-masked in the provider payload — grants never apply here).
  Returns the kernel result verbatim; for `:draft_sequence` a `{:ok, %{status: :draft, ...}}`.
  """
  @spec crm_run(Mount.t(), String.t() | nil, atom(), module() | nil, String.t(), String.t(), map()) ::
          result() | {:ok, %{status: :draft, body: String.t()}}
  def crm_run(mount, org_id, helper, resource, id, input, params \\ %{})

  def crm_run(mount, org_id, :classify_inbound, _resource, _id, input, params) do
    Samen.AI.Crm.classify_inbound(scope(mount, org_id), input, params: params)
  end

  def crm_run(_mount, _org_id, _helper, resource, id, _input, _params)
      when is_nil(resource) or id == "" do
    {:error, :no_record}
  end

  def crm_run(mount, org_id, :summarize_timeline, resource, id, input, _params),
    do: Samen.AI.Crm.summarize_timeline(scope(mount, org_id), resource, id, input: input)

  def crm_run(mount, org_id, :recommend_next_step, resource, id, input, _params),
    do: Samen.AI.Crm.recommend_next_step(scope(mount, org_id), resource, id, input: input)

  def crm_run(mount, org_id, :draft_sequence, resource, id, input, _params),
    do: Samen.AI.Crm.draft_sequence(scope(mount, org_id), resource, id, input)

  @doc """
  A masking-safe preview of the CRM record the surface will ground on — read ORG-SCOPED
  (a hard `org_id == ^org` filter from the trusted scope, NEVER from params) and resolved
  through `Samen.Api.PiiResolution` on the mount's plane, exactly like every framework read
  surface. Returns `{:ok, resolved_record}` (a map of the public fields, vault-routed ones
  as `%Samen.Masked{}` on the operator plane) or `{:error, :not_found}`.

  ORG-SCOPE PIN: the `org_id == ^org` conjunct is the guarantee patch 141 flips — drop it and
  a caller can render another org's record on the AI grounding surface.
  """
  @spec crm_preview(Mount.t(), String.t() | nil, module() | nil, String.t()) ::
          {:ok, map()} | {:error, term()}
  def crm_preview(_mount, org_id, resource, id)
      when is_nil(org_id) or is_nil(resource) or id == "",
      do: {:error, :not_found}

  def crm_preview(mount, org_id, resource, id) do
    query =
      resource
      |> Ash.Query.filter(org_id == ^org_id and id == ^id)
      |> ensure_public_selected(resource)

    case Ash.read(query, authorize?: false) do
      {:ok, [record | _]} ->
        [resolved] =
          Samen.Api.PiiResolution.resolve(
            [record],
            resource,
            actor_of(scope(mount, org_id)),
            repo: mount.repo
          )

        {:ok, preview_fields(resolved, resource)}

      {:ok, []} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, {:read_failed, reason}}
    end
  rescue
    _ -> {:error, :not_found}
  end

  # --- Analytics surface (D7 token-blind ask box — operator/platform-gated by the kernel) --

  @doc """
  Ask a natural-language analytics question over `resource` (a `use Samen.Aggregate.Resource`
  projection). The read runs as the singleton token-blind aggregate actor with
  k-anon/l-diversity floors; the CALLER must hold a platform/operator capability
  (`Samen.AI.Analytics.ask/4`'s T144 deny-by-default gate). A tenant-plane caller is refused
  `{:error, :unauthorized}` fail-closed BEFORE any row is read — the surface renders that
  honestly, never a fabricated answer. Returns the kernel result verbatim.
  """
  @spec analytics_ask(Mount.t(), String.t() | nil, module() | nil, String.t()) :: result()
  def analytics_ask(_mount, _org_id, resource, _question) when is_nil(resource),
    do: {:error, :no_resource}

  def analytics_ask(mount, org_id, resource, question) when is_binary(question) do
    Samen.AI.Analytics.ask(scope(mount, org_id), resource, question)
  end

  # --- Support-draft surface (D5 compose — persists in a host that adopted Samen.AI.Domain) -

  @doc """
  Compose an AI support-reply draft: `Samen.AI.SupportOperator.draft_reply/3` grounds
  (masked), persists a `Samen.AI.SupportReplyDraft` row, and opens a PENDING `ai_support_reply`
  approval decided by a DISTINCT human — it NEVER sends. `attrs` must carry `:org_id`
  (injected from the trusted scope by the caller LiveView, never from client params) +
  `:to_subscriber_id`; optional `:inbound_ref`/`:subject`/`:source_resource`/`:source_id`.
  Fail-honest `{:error, :not_configured}` on an unwired provider; `{:error, ...}` when the
  host has not adopted `Samen.AI.Domain` (no draft repo/table) — the surface reports it truthfully.
  """
  @spec support_draft(Mount.t(), String.t() | nil, map(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def support_draft(mount, org_id, attrs, opts \\ []) when is_map(attrs) do
    attrs = Map.put(attrs, :org_id, org_id)
    Samen.AI.SupportOperator.draft_reply(scope(mount, org_id), attrs, opts)
  rescue
    e -> {:error, {:persist_unavailable, Exception.message(e)}}
  end

  @doc """
  List this org's support-reply drafts (org-scoped read of `Samen.AI.SupportReplyDraft`).
  ORG-SCOPE PIN: the `org_id == ^org` filter is from the trusted scope; dropping it flips a
  named cross-org test (patch 142). Fail-safe `[]` when the host has not adopted the AI domain
  (no table/repo) — an empty list, NEVER another org's drafts.
  """
  @spec list_drafts(Mount.t(), String.t() | nil) :: [struct()]
  def list_drafts(_mount, nil), do: []

  def list_drafts(_mount, org_id) do
    Samen.AI.SupportReplyDraft
    |> Ash.Query.filter(org_id == ^org_id)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(50)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, drafts} -> drafts
      {:error, _} -> []
    end
  rescue
    _ -> []
  end

  # --- shared helpers ----------------------------------------------------------------------

  @doc "The `%Samen.Scope{}` for the mount's plane over `org_id` (the framework read seam)."
  @spec scope(Mount.t(), String.t() | nil) :: Samen.Scope.t()
  def scope(%Mount{} = mount, org_id), do: Mount.scope(mount, org_id)

  defp actor_of(%Samen.Scope{actor: actor}), do: actor
  defp actor_of(other), do: other

  defp ensure_public_selected(query, resource) do
    case public_field_names(resource) do
      [] -> query
      fields -> Ash.Query.ensure_selected(query, fields)
    end
  end

  defp preview_fields(record, resource) do
    resource
    |> public_field_names()
    |> Map.new(fn f -> {f, Map.get(record, f)} end)
    |> Map.put(:__id__, Map.get(record, :id))
  end

  defp public_field_names(resource) do
    resource |> Ash.Resource.Info.public_attributes() |> Enum.map(& &1.name)
  rescue
    _ -> []
  end
end
