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
    @moduledoc "One ranked semantic-search hit (org-scoped; carries no source plaintext)."
    @enforce_keys [:source_resource, :source_id, :field, :distance]
    defstruct [:source_resource, :source_id, :field, :distance]

    @type t :: %__MODULE__{
            source_resource: String.t(),
            source_id: String.t(),
            field: String.t(),
            distance: float()
          }
  end

  @table "aie_embedding"
  @default_limit 20

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
      store_vector(repo_for(opts), org_id, resource, source_id, field, vector)
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
    if function_exported?(resource, :embeddable_fields, 0) do
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
    pii = safe(fn -> Enum.map(Info.pii_attributes(resource), & &1.name) end, [])
    routed = safe(fn -> Info.vault_routed_columns(resource) end, [])
    field in pii or field in routed
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

  defp store_vector(repo, org_id, resource, source_id, field, vector) do
    now = NaiveDateTime.utc_now()

    sql = """
    INSERT INTO #{@table}
      (aie_org_id, aie_source_resource, aie_source_id, aie_field, aie_embedding,
       aie_inserted_at, aie_updated_at)
    VALUES ($1::text::uuid, $2, $3, $4, $5::text::vector, $6, $6)
    ON CONFLICT (aie_org_id, aie_source_resource, aie_source_id, aie_field)
    DO UPDATE SET aie_embedding = EXCLUDED.aie_embedding, aie_updated_at = EXCLUDED.aie_updated_at
    """

    params = [
      org_id,
      inspect(resource),
      to_string(source_id),
      Atom.to_string(field),
      encode_vector(vector),
      now
    ]

    {:ok, _} = repo.query(sql, params)
    :ok
  end

  defp knn(repo, org_id, qvec, limit) do
    sql = """
    SELECT aie_source_resource, aie_source_id, aie_field,
           aie_embedding <-> $2::text::vector AS distance
    FROM #{@table}
    WHERE aie_org_id = $1::text::uuid
    ORDER BY aie_embedding <-> $2::text::vector
    LIMIT $3
    """

    case repo.query(sql, [org_id, encode_vector(qvec), limit]) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [res, sid, field, dist] ->
          %Hit{source_resource: res, source_id: sid, field: field, distance: to_float(dist)}
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
