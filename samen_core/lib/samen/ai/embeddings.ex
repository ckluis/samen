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

  alias Samen.AI.{Chokepoint, Embedder}
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
  """
  @spec embed_field(term(), module(), String.t(), atom(), term(), keyword()) ::
          {:ok, [float()]} | {:error, term()}
  def embed_field(scope, resource, source_id, field, text, opts) when is_atom(field) do
    with {:ok, org_id} <- org_id_from(scope, opts),
         :ok <- assert_embeddable(resource, field),
         {:ok, {embedder, config}} <- embedder_for(opts),
         {:ok, [vector]} <- Chokepoint.embed(embedder, config, [text], chokepoint_opts(opts)) do
      # `text` already passed `assert_embeddable/2` (declared embeddable AND non-vault), so it
      # is non-PII by construction; `snippet_of/1` is the belt (stores only a `vt_`-free
      # binary excerpt, `nil` otherwise) — the Hit is self-describing, masking-safe (T152).
      store_vector(repo_for(opts), org_id, resource, source_id, field, vector, snippet_of(text))
      {:ok, vector}
    else
      {:error, _} = err -> err
      other -> {:error, other}
    end
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

  # --- storage (raw SQL; pgvector `::vector` text cast, dependency-free) --------------------

  defp store_vector(repo, org_id, resource, source_id, field, vector, snippet) do
    now = NaiveDateTime.utc_now()

    sql = """
    INSERT INTO #{@table}
      (aie_org_id, aie_source_resource, aie_source_id, aie_field, aie_embedding, aie_snippet,
       aie_inserted_at, aie_updated_at)
    VALUES ($1::text::uuid, $2, $3, $4, $5::text::vector, $6, $7, $7)
    ON CONFLICT (aie_org_id, aie_source_resource, aie_source_id, aie_field)
    DO UPDATE SET aie_embedding = EXCLUDED.aie_embedding, aie_snippet = EXCLUDED.aie_snippet,
                  aie_updated_at = EXCLUDED.aie_updated_at
    """

    params = [
      org_id,
      inspect(resource),
      to_string(source_id),
      Atom.to_string(field),
      encode_vector(vector),
      snippet,
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
