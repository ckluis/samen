defmodule Samen.AI.Embeddings do
  @moduledoc """
  The D3 semantic-search plane (ADR-043 §7, T67) — embed-on-write + vector similarity search
  over the org-scoped `aie_embedding` store, keyless in CI and deny-by-default by construction.

  ## The three guarantees this module is responsible for

    1. **Deny-by-default embedding (§7.2).** `embed_record/4` embeds ONLY the fields a resource
       DECLARES embeddable (`embeddable_fields/0`, the `samen` section seam). A vault-routed
       (🔒) field is refused at THREE layers — it fails compile if declared embeddable
       (`Samen.Verifiers.EmbeddableNoPii`), the `ai_prompt_masking` verifier flags it in ci.sh,
       and here `embed_field/6` re-refuses `{:error, :field_not_embeddable}` for any field not
       in the declared allowlist OR that is vault-routed. And every embed input is sealed by
       `Samen.AI.Chokepoint` (`:embed`), whose fail-closed scrub refuses a `%Samen.Masked{}` /
       `vt_*`-bearing value outright — so even if all the above were bypassed, a vaulted value
       cannot reach the embedder or the vector store (`{:error, :pii_egress_refused}`). Grants
       NEVER unlock embedding: a vector persists beyond any grant window and is invertible.

    2. **Org isolation (§7.3).** Every row carries `aie_org_id`; every read/write filters on the
       calling scope's `org_id`. Org B's vectors are never returned — never even *ranked* — for
       org A. A scope with no org is refused fail-closed (`{:error, :no_org}`), the
       `Samen.Scope.new/1` cross-org-hazard posture.

    3. **Keyless, fail-honest (§4, M9).** The embedder resolves to
       `Samen.AI.Embedder.Deterministic` when unwired in `:test` (deterministic ⇒ ranking-shape
       and org-scoping tests are REAL); unwired elsewhere ⇒ `{:error, :not_configured}` (never a
       faked vector). A host wires a real embeddings provider via
       `config :samen_core, Samen.AI, embedder: {Module, config}`.

       > **Keyless ranking is by HASH distance, not meaning (T152, honest framing).** The
       > deterministic embedder is a stable bag-of-tokens hash projection — a self-query lands
       > at distance 0 and shared tokens rank nearer, but there is NO semantic quality
       > (synonyms/paraphrase do not rank closer). Meaningful semantic ranking needs a LIVE
       > embedder (wire one + `SAMEN_AI_LIVE=1`). This is the inherent keyless limitation, not
       > a bug — see `Samen.AI.Embedder.Deterministic` and `docs/guides/ai-quickstart.md`.

  ## Routes through the chokepoint (never a raw embedder call)

  `embed_field/6` seals its input via `Samen.AI.Chokepoint.embed/4` — the ONE
  provider-invocation site — so the masking/refusal pipeline runs before a byte is embedded or
  stored. This module never calls an embedder's `embed/2` directly.

  ## Storage is a plain-Ecto derived index (not an Ash resource)

  `aie_embedding` is kernel infrastructure (the `Samen.Reveal.RevealGrant` / `Samen.AuditEvent`
  precedent), so it carries no allocator abbrev and org-scoping is enforced in the query builder
  (a hard `WHERE aie_org_id = $org`) rather than an `OrgScope` policy — functionally identical
  for a derived index, and proven by the cross-org red test. The `pgvector` `<->` L2 distance
  ranks; the HNSW index (§7.1) accelerates it.
  """

  alias Samen.AI.{Chokepoint, CrossRunWriteGuard, Embedder}
  alias Samen.Pii.Info

  defmodule Hit do
    @moduledoc """
    One ranked semantic-search hit (org-scoped). Self-describing: `:snippet` is a bounded
    excerpt of the matched field's value (T152) so a caller sees WHAT matched without a
    second fetch. The snippet is masking-safe by construction — an embedded field is
    non-vault by deny-by-default (`Samen.AI.Embeddings.assert_embeddable/2`), so it carries
    no 🔒/`%Samen.Masked{}`/`vt_*` value; `snippet_of/1` additionally stores `nil` for
    anything that is not a `vt_`-free binary. `:snippet` is `nil` for a row embedded before
    the snippet column existed (never a fabricated excerpt).
    """
    @enforce_keys [:source_resource, :source_id, :field, :distance]
    defstruct [:source_resource, :source_id, :field, :distance, :snippet]

    @type t :: %__MODULE__{
            source_resource: String.t(),
            source_id: String.t(),
            field: String.t(),
            distance: float(),
            snippet: String.t() | nil
          }
  end

  @table "aie_embedding"
  @default_limit 20
  # Bounded excerpt length for the self-describing Hit snippet (T152). Long enough to be
  # legible, short enough that the vector index stays a lean derived store.
  @snippet_limit 240
  # The vault FK-token sentinel (`vt_*`). `snippet_of/1` refuses to store any snippet carrying
  # it — a belt to the deny-by-default brace (an embedded field is non-vault by construction).
  @vt_sentinel "vt_"

  @doc """
  Embed every DECLARED embeddable field of `record` (a struct of `resource`) and store one
  org-scoped vector per field. Deny-by-default: only `resource.embeddable_fields/0` fields are
  embedded. Returns `{:ok, embedded_field_count}` or a fail-closed `{:error, reason}` (the
  first refusal halts and stores nothing further — refuse, never partially leak).

  `opts`: `:repo` (defaults to the configured vault/reveal repo), `:embedder`
  (`{module, config}` override), plus any `Samen.AI.Chokepoint` opts.
  """
  @spec embed_record(term(), struct(), module(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def embed_record(scope, record, resource, opts \\ []) when is_atom(resource) do
    with {:ok, org_id} <- org_id(scope),
         {:ok, source_id} <- source_id(record) do
      fields = declared_embeddable_fields(resource)

      Enum.reduce_while(fields, {:ok, 0}, fn field, {:ok, n} ->
        text = Map.get(record, field)

        case embed_field(scope, resource, source_id, field, text, Keyword.put(opts, :org_id, org_id)) do
          {:ok, _} -> {:cont, {:ok, n + 1}}
          {:error, _} = err -> {:halt, err}
        end
      end)
    end
  end

  @doc """
  Embed one field's `text` for a source row and store its vector (org-scoped upsert). This is
  the governed unit: it refuses fail-closed (`{:error, :field_not_embeddable}`) unless `field`
  is a DECLARED embeddable field of `resource` AND not vault-routed (the deny-by-default belt),
  then seals the text through `Samen.AI.Chokepoint` (`:embed`) before the embedder runs.

  The row is stamped with `model_identifier/1` of the RESOLVED embedder (T186) — the single
  write path every vector goes through, so every row this function ever writes carries a
  model identifier by construction. `Samen.AI.Embeddings.stale_rows/2` is the read side.
  """
  @spec embed_field(term(), module(), String.t(), atom(), term(), keyword()) ::
          {:ok, [float()]} | {:error, term()}
  def embed_field(scope, resource, source_id, field, text, opts) when is_atom(field) do
    with {:ok, org_id} <- org_id_from(scope, opts),
         # ADR-048 §8 P12 / D3 — CATEGORICAL write-time refusal. Compaction output
         # (a fold summary, or any other derived-summary artifact) may never enter
         # pgvector or any other cross-run store. Refused HERE, before the embedder
         # is even resolved, so nothing can land and be cleaned up later.
         :ok <- assert_not_cross_run(opts),
         :ok <- assert_embeddable(resource, field),
         {:ok, {embedder, config}} <- embedder_for(opts),
         {:ok, [vector]} <- Chokepoint.embed(embedder, config, [text], chokepoint_opts(opts)) do
      # `text` already passed `assert_embeddable/2` (declared embeddable AND non-vault), so it
      # is non-PII by construction; `snippet_of/1` is the belt (stores only a `vt_`-free
      # binary excerpt, `nil` otherwise) — the Hit is self-describing, masking-safe (T152).
      model = model_identifier({embedder, config})
      store_vector(repo_for(opts), org_id, resource, source_id, field, vector, snippet_of(text), model)
      {:ok, vector}
    else
      {:error, _} = err -> err
      other -> {:error, other}
    end
  end

  @doc """
  T186: the model identifier that produced (or would produce) an embedding — the value stamped
  into `aie_model` and the drift-detection key `stale_rows/2` compares against. Reads
  `Map.get(config, :model)` first (the standard `Samen.AI.Provider` config convention: an
  adapter's `config` map carries an explicit `:model` string), falling back to
  `inspect(module)` when the resolved provider has no `:model` config key at all — e.g.
  `Samen.AI.Embedder.Deterministic`, whose keyless hash projection has no model NAME but is
  still a distinct, versionable engine (module identity IS its version). Either way the
  identifier is stable and content-free (never a vector, never source text) — it only ever
  answers "which engine wrote this row".
  """
  @spec model_identifier({module(), map()}) :: String.t()
  def model_identifier({module, config}) when is_atom(module) and is_map(config) do
    case Map.get(config, :model) do
      model when is_binary(model) and model != "" -> model
      _ -> inspect(module)
    end
  end

  @doc """
  T186 drift/staleness: the currently CONFIGURED embedder's `model_identifier/1`, or
  `{:error, :not_configured}` if unwired outside `:test` (mirrors `embedder_for/1`'s own
  fail-honest contract — there is no "current model" to compare against when nothing is
  wired). This is what a caller (an ops dashboard, `reembed_stale/1`) uses to answer "what
  model would a fresh embed use right now", independent of any stored row.
  """
  @spec current_model(keyword()) :: {:ok, String.t()} | {:error, term()}
  def current_model(opts \\ []) do
    case embedder_for(opts) do
      {:ok, resolved} -> {:ok, model_identifier(resolved)}
      {:error, _} = err -> err
    end
  end

  @doc """
  T186 stale-detection: org-unscoped kernel maintenance read (mirrors `Samen.Retention.sweep/2`
  and `Samen.AuditEvent.PartitionManager` — cross-org housekeeping is legitimate for kernel
  infrastructure; it is EMBEDDING RESULTS, not tenant data, that stay org-scoped, and this
  reads only routing metadata: id/org/resource/source/field/model, never a vector or plaintext).
  A row is stale when `aie_model IS NULL` (never stamped — the fail-honest default, §pre-T186
  rows) OR `aie_model <> current_model` (the provider was upgraded since this row was written).
  Bounded by `:limit` (default 500) so a large backlog is swept incrementally, never as one
  unbounded scan. Returns raw maps (`:id`, `:org_id`, `:source_resource`, `:source_id`,
  `:field`, `:model`) — the shape `reembed_stale/1` consumes.
  """
  @spec stale_rows(term(), String.t(), keyword()) :: [map()]
  def stale_rows(repo, current_model, opts \\ []) when is_binary(current_model) do
    limit = Keyword.get(opts, :limit, 500)

    sql = """
    SELECT aie_id::text, aie_org_id::text, aie_source_resource, aie_source_id, aie_field, aie_model
    FROM #{@table}
    WHERE aie_model IS NULL OR aie_model <> $1
    ORDER BY aie_inserted_at ASC
    LIMIT $2
    """

    case repo.query(sql, [current_model, limit]) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [id, org_id, resource, source_id, field, model] ->
          %{
            id: id,
            org_id: org_id,
            source_resource: resource,
            source_id: source_id,
            field: field,
            model: model
          }
        end)

      {:error, _} ->
        []
    end
  end

  @doc """
  T186 incremental re-embed: re-embeds ONLY the rows `stale_rows/2` reports — never a fresh
  row (a byte-unchanged fresh row is proof the batch job is scoped, not a full-table sweep).
  For each stale row, resolves the source resource module + field atom from the row's stored
  strings, loads the CURRENT source record via `:record_loader` (default `Ash.get/3`,
  `authorize?: false` — a system-context read, the `Samen.Approvals`/`Samen.Sequences`
  precedent for kernel maintenance jobs with no actor), and re-runs `embed_field/6` for that
  ONE field through the SAME chokepoint every embed goes through (never a raw embedder call,
  never a hand-rolled INSERT). A row whose resource/record can no longer be resolved is
  recorded as an error, never silently dropped or falsely marked fresh.

  `opts`: `:repo`, `:embedder` (override), `:limit` (default 500, forwarded to `stale_rows/2`),
  `:record_loader` (`(module(), String.t() -> {:ok, struct()} | {:error, term()})`, the test
  seam — mirrors the `:env_reader` pattern `embedder_for/1` already uses).

  Returns `{:ok, %{reembedded: n, errors: [{row, reason}]}}` or the fail-closed
  `{:error, :not_configured}` when no embedder is wired (nothing to compare staleness against).
  """
  @spec reembed_stale(keyword()) ::
          {:ok, %{reembedded: non_neg_integer(), errors: [{map(), term()}]}} | {:error, term()}
  def reembed_stale(opts \\ []) do
    with {:ok, {embedder, config} = resolved} <- embedder_for(opts) do
      current = model_identifier(resolved)
      repo = repo_for(opts)
      rows = stale_rows(repo, current, Keyword.take(opts, [:limit]))
      loader = Keyword.get(opts, :record_loader, &default_record_loader/2)

      result =
        Enum.reduce(rows, %{reembedded: 0, errors: []}, fn row, acc ->
          case reembed_row(row, loader, Keyword.put(opts, :embedder, {embedder, config})) do
            :ok -> %{acc | reembedded: acc.reembedded + 1}
            {:error, reason} -> %{acc | errors: [{row, reason} | acc.errors]}
          end
        end)

      {:ok, result}
    end
  end

  defp reembed_row(row, loader, opts) do
    with {:ok, resource} <- resolve_resource(row.source_resource),
         {:ok, field} <- resolve_field(resource, row.field),
         {:ok, record} <- loader.(resource, row.source_id),
         text <- Map.get(record, field),
         row_opts <- Keyword.put(opts, :org_id, row.org_id),
         {:ok, _vector} <- embed_field(nil, resource, row.source_id, field, text, row_opts) do
      :ok
    else
      {:error, _} = err -> err
      other -> {:error, other}
    end
  end

  # `aie_source_resource` was written via `inspect(resource)` (store_vector/8) — a module's
  # `inspect/1` form (e.g. "Samen.Foo.Bar", no "Elixir." prefix). Reversed with
  # `Module.concat/1` on the dot-split segments; `Code.ensure_loaded?/1` refuses a module that
  # no longer exists (a renamed/removed resource) fail-closed rather than crashing the batch.
  defp resolve_resource(inspected) when is_binary(inspected) do
    module = inspected |> String.split(".") |> Module.concat()

    if Code.ensure_loaded?(module) do
      {:ok, module}
    else
      {:error, {:unresolvable_resource, inspected}}
    end
  rescue
    _ -> {:error, {:unresolvable_resource, inspected}}
  end

  # `aie_field` was written via `Atom.to_string/1` — the field atom already exists (it was
  # declared via `use Samen.Resource, embeddable: [...]` at compile time), so
  # `String.to_existing_atom/1` is safe and fail-closed (never mints a NEW atom from row data).
  defp resolve_field(resource, field_str) when is_binary(field_str) do
    field = String.to_existing_atom(field_str)

    if field in declared_embeddable_fields(resource) do
      {:ok, field}
    else
      {:error, {:field_no_longer_embeddable, field_str}}
    end
  rescue
    ArgumentError -> {:error, {:unknown_field, field_str}}
  end

  # The default `:record_loader` — a system-context read (no actor: this is kernel
  # maintenance, the `Samen.Approvals.gate/3` / `Samen.Sequences` `authorize?: false`
  # precedent for a job with no human actor in scope).
  defp default_record_loader(resource, source_id) do
    Ash.get(resource, source_id, authorize?: false)
  end

  @doc """
  Semantic search: embed `query` and return the `:limit` nearest org-scoped vectors as ranked
  `%Hit{}`s (smallest L2 distance first). NEVER crosses orgs — the `WHERE aie_org_id` filter is
  applied before ranking, so a foreign org's rows do not exist for this query (§7.3). An empty
  query, a scope with no org, or no stored vectors ⇒ `{:ok, []}` (no match-all default).
  """
  @spec search(term(), String.t(), keyword()) :: {:ok, [Hit.t()]} | {:error, term()}
  def search(scope, query, opts \\ []) do
    with {:ok, org_id} <- org_id(scope),
         normalized when normalized != "" <- normalize_query(query),
         {:ok, {embedder, config}} <- embedder_for(opts) do
      # Embed the QUERY through the same chokepoint + embedder as the documents (identical
      # projection ⇒ a self-query lands at distance 0). Free-text query keystrokes are the
      # user's own input (§3.2 step-2 consent boundary); the scrub still refuses a `vt_*` token.
      case Chokepoint.embed(embedder, config, [normalized], chokepoint_opts(opts)) do
        {:ok, [qvec]} -> {:ok, knn(repo_for(opts), org_id, qvec, limit(opts))}
        {:error, _} = err -> err
      end
    else
      "" -> {:ok, []}
      {:error, _} = err -> err
      other -> {:error, other}
    end
  end

  @doc """
  Whether the CURRENTLY RESOLVED embedder for `search/3` / `embed_field/6` self-declares as
  simulated (T78, mirroring T152's `%Samen.AI.Completion{simulated:}` mechanism —
  `Samen.AI.Chokepoint`'s private `simulated_provider?/1`, duplicated here because it is the
  embeddings lane's own resolution, not the completion lane's). `Samen.AI.Embedder.
  Deterministic` (the keyless `:test`-only fallback, `unwired_embedder/1` above) self-declares
  `true` via the optional `Samen.AI.Provider.simulated?/0` callback; a live adapter that omits
  the callback is treated as LIVE (`false`, fail-honest default). A caller (a KB-suggestion
  panel, say) uses this to render an honest "simulated ranking" badge next to `search/3` hits
  instead of presenting keyless hash-distance ranking as if it were real semantic search.

  `{:error, :not_configured}` when unwired outside `:test` — nothing to ask (the caller already
  has `search/3`'s own `{:error, :not_configured}` to render the honest not-configured state).
  """
  @spec embedder_simulated?(keyword()) :: {:ok, boolean()} | {:error, :not_configured}
  def embedder_simulated?(opts \\ []) do
    case embedder_for(opts) do
      {:ok, {module, _config}} -> {:ok, simulated_provider?(module)}
      {:error, _} = err -> err
    end
  end

  # Mirrors `Samen.AI.Chokepoint`'s private `simulated_provider?/1` exactly (T152's mechanism):
  # a provider that OMITS the optional callback is LIVE by default (fail-honest — never claim a
  # real provider is simulated, never claim a keyless one is real). Wrapped so a provider whose
  # `simulated?/0` raises can never crash the caller.
  defp simulated_provider?(provider) do
    Code.ensure_loaded?(provider) and function_exported?(provider, :simulated?, 0) and
      provider.simulated?() == true
  rescue
    _ -> false
  end

  # --- deny-by-default allowlist ------------------------------------------------------------

  defp declared_embeddable_fields(resource) do
    # `Code.ensure_loaded?/1` FIRST — mirrors `Samen.AI.resolved_env/1` and the T143
    # `Samen.Approvals.exports?/3` pattern. Without it, `function_exported?/3` reports `false`
    # for a not-yet-loaded resource module, collapsing the deny-by-default allowlist to `[]`
    # so `assert_embeddable/2` wrongly returns `{:error, :field_not_embeddable}` for a
    # genuinely-declared embeddable field (masking the ADR-014 `{:error, :not_configured}`
    # contract). Forcing the load makes detection reflect what the module ACTUALLY defines,
    # not load order. Fail-closed either way, but now honest.
    if Code.ensure_loaded?(resource) and function_exported?(resource, :embeddable_fields, 0) do
      resource.embeddable_fields() |> List.wrap()
    else
      []
    end
  end

  # A field is embeddable ONLY if declared AND not vault-routed. The vault-routed re-check keys
  # on the SAME union the structural verifier + the chokepoint use (`Samen.Pii.Info`), so the
  # plane, the chokepoint, and ci.sh agree by construction (T135). Fail-closed.
  defp assert_embeddable(resource, field) do
    cond do
      field not in declared_embeddable_fields(resource) -> {:error, :field_not_embeddable}
      vault_routed?(resource, field) -> {:error, :field_not_embeddable}
      true -> :ok
    end
  end

  defp vault_routed?(resource, field) do
    # Force the load FIRST (same guard as `declared_embeddable_fields/1`): the `Info.*`
    # introspection below reads the compiled Spark DSL, so on a not-yet-loaded module it would
    # raise `UndefinedFunctionError` and `safe/2` would swallow it to `[]` — a fail-OPEN
    # result (a vault-routed field read as NOT routed). If the module can't be loaded at all we
    # cannot prove the field is safe, so fail-CLOSED (treat as vault-routed).
    if Code.ensure_loaded?(resource) do
      pii = safe(fn -> Enum.map(Info.pii_attributes(resource), & &1.name) end, [])
      routed = safe(fn -> Info.vault_routed_columns(resource) end, [])
      field in pii or field in routed
    else
      true
    end
  end

  # --- embedder resolution (the Samen.AI.provider_for/2 mirror, embeddings lane) ------------

  # T141 (fail-honest sentinel): return a TAGGED `{:ok, {module, config}}` / `{:error, reason}`
  # so an unwired-prod resolution short-circuits the `with` in `embed_field/6`/`search/3`
  # instead of being destructured — the pre-fix `{embedder, config} <- embedder_for(opts)`
  # matched a bare `{:error, :not_configured}` tuple as `embedder=:error, config=:not_configured`
  # and dispatched to a bogus `:error` provider, surfacing `{:error, {:provider_error, :error}}`
  # rather than the ADR-014/M9 contract's `{:error, :not_configured}`. The `:env_reader` opt is
  # the test-only seam (mirrors `Samen.AI`'s T66-F2 pattern) — never set outside a test.
  defp embedder_for(opts) do
    case Keyword.get(opts, :embedder) || configured_embedder() do
      {module, config} when is_atom(module) and is_map(config) -> {:ok, {module, config}}
      _ -> unwired_embedder(Samen.AI.resolved_env(Keyword.get(opts, :env_reader, &Mix.env/0)))
    end
  end

  defp unwired_embedder(:test), do: {:ok, {Embedder.Deterministic, %{}}}
  defp unwired_embedder(_env), do: {:error, :not_configured}

  defp configured_embedder do
    Application.get_env(:samen_core, Samen.AI, []) |> Keyword.get(:embedder)
  end

  # Only forward the masking-relevant chokepoint opts (actor/scope/grant plumbing); never the
  # embeddings-plane opts (:repo, :embedder, :org_id, :limit).
  defp chokepoint_opts(opts) do
    Keyword.take(opts, [:actor, :scope, :grant, :repo, :vault, :grant_egress?, :grounding, :meta])
    |> Keyword.drop([:repo])
  end

  # --- ADR-048 §8 P12 / D3: the categorical cross-run write refusal -------------------------

  # The write-time refusal `embed_field/6` runs BEFORE it resolves an embedder, so nothing
  # can land and be cleaned up later — it stands here, immediately in front of the storage
  # section, because that is what it guards. It is a claim about the ARTIFACT (is this
  # compaction output?), where `assert_embeddable/2` above is a claim about the FIELD (is
  # this field declared and non-vault?) — orthogonal, which is why `P12`'s red drives a fold
  # summary at a field that embeds perfectly well for ordinary content.
  # `Samen.AI.CrossRunWriteGuard` owns the decision so the same rule can guard a future
  # cross-run store without being re-derived here; the `@table` pgvector index is the ONE
  # cross-run store this module writes to today.
  defp assert_not_cross_run(opts), do: assert_not_cross_run(:pgvector, opts)

  defp assert_not_cross_run(store, opts), do: CrossRunWriteGuard.check(store, opts)

  # --- storage (raw SQL; pgvector `::vector` text cast, dependency-free) --------------------

  defp store_vector(repo, org_id, resource, source_id, field, vector, snippet, model) do
    now = NaiveDateTime.utc_now()

    sql = """
    INSERT INTO #{@table}
      (aie_org_id, aie_source_resource, aie_source_id, aie_field, aie_embedding, aie_snippet,
       aie_model, aie_inserted_at, aie_updated_at)
    VALUES ($1::text::uuid, $2, $3, $4, $5::text::vector, $6, $7, $8, $8)
    ON CONFLICT (aie_org_id, aie_source_resource, aie_source_id, aie_field)
    DO UPDATE SET aie_embedding = EXCLUDED.aie_embedding, aie_snippet = EXCLUDED.aie_snippet,
                  aie_model = EXCLUDED.aie_model, aie_updated_at = EXCLUDED.aie_updated_at
    """

    params = [
      org_id,
      inspect(resource),
      to_string(source_id),
      Atom.to_string(field),
      encode_vector(vector),
      snippet,
      model,
      now
    ]

    {:ok, _} = repo.query(sql, params)
    :ok
  end

  # A bounded, masking-safe excerpt of the matched field's value (T152). Only a `vt_`-free
  # binary yields a snippet — a `%Samen.Masked{}`, a `vt_*`-bearing string, or any non-binary
  # value stores `nil` (never surface a token / masked / non-plaintext shape in a Hit). Since
  # `assert_embeddable/2` already guarantees the field is non-vault, this is the belt to that
  # brace, not the primary gate. Whitespace is collapsed so the excerpt is single-line-legible.
  defp snippet_of(text) when is_binary(text) do
    if String.contains?(text, @vt_sentinel) do
      nil
    else
      text |> String.replace(~r/\s+/u, " ") |> String.trim() |> binary_slice_safe(@snippet_limit)
    end
  end

  defp snippet_of(_), do: nil

  defp binary_slice_safe(s, limit) when byte_size(s) <= limit, do: s
  defp binary_slice_safe(s, limit), do: String.slice(s, 0, limit)

  defp knn(repo, org_id, qvec, limit) do
    sql = """
    SELECT aie_source_resource, aie_source_id, aie_field, aie_snippet,
           aie_embedding <-> $2::text::vector AS distance
    FROM #{@table}
    WHERE aie_org_id = $1::text::uuid
    ORDER BY aie_embedding <-> $2::text::vector
    LIMIT $3
    """

    case repo.query(sql, [org_id, encode_vector(qvec), limit]) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [res, sid, field, snippet, dist] ->
          %Hit{
            source_resource: res,
            source_id: sid,
            field: field,
            snippet: snippet,
            distance: to_float(dist)
          }
        end)

      {:error, _} ->
        []
    end
  end

  # pgvector's text input form: "[0.1,0.2,...]".
  defp encode_vector(vec) when is_list(vec) do
    "[" <> Enum.map_join(vec, ",", &to_string/1) <> "]"
  end

  # --- org / repo / misc --------------------------------------------------------------------

  defp org_id(scope), do: extract_org(scope)

  defp org_id_from(scope, opts) do
    case Keyword.get(opts, :org_id) do
      nil -> extract_org(scope)
      org -> {:ok, org}
    end
  end

  defp extract_org(%Samen.Scope{actor: %{org_id: org}}) when not is_nil(org), do: {:ok, org}
  defp extract_org(%{org_id: org}) when not is_nil(org), do: {:ok, org}
  defp extract_org(org) when is_binary(org), do: {:ok, org}
  defp extract_org(_), do: {:error, :no_org}

  defp source_id(%{id: id}) when not is_nil(id), do: {:ok, id}
  defp source_id(_), do: {:error, :no_source_id}

  defp repo_for(opts) do
    Keyword.get(opts, :repo) ||
      Application.get_env(:samen_core, :vault_repo) ||
      Application.get_env(:samen_core, :reveal_grant_repo) ||
      raise(ArgumentError, "Samen.AI.Embeddings requires a :repo (or a configured vault repo)")
  end

  defp limit(opts), do: Keyword.get(opts, :limit, @default_limit)

  defp normalize_query(q) when is_binary(q), do: String.trim(q)
  defp normalize_query(nil), do: ""
  defp normalize_query(q), do: q |> to_string() |> String.trim()

  defp to_float(n) when is_float(n), do: n
  defp to_float(n) when is_integer(n), do: n * 1.0
  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float(_), do: 0.0

  defp safe(fun, default) do
    fun.()
  rescue
    _ -> default
  end
end
