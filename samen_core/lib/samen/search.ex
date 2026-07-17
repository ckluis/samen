defmodule Samen.Search.Result do
  @moduledoc """
  One ranked search hit (WS-E E4.1; ADR-027). `record` is the matched row ALREADY
  projected through `Samen.Api.PiiResolution` on the actor's plane — a vaulted field
  is `%Samen.Masked{}` (`••••`) / `%Ash.ForbiddenField{}` here, NEVER plaintext on a
  plane the tenant would not show. `display` is the bounded NON-PII allowlist (the
  registered searchable field names — guard-guaranteed non-PII) taken off that same
  projected record, so a palette row can render only masked-safe values.
  """
  @enforce_keys [:resource, :resource_name, :id, :rank, :record, :display]
  defstruct [:resource, :resource_name, :id, :rank, :record, :display]

  @type t :: %__MODULE__{
          resource: module(),
          resource_name: String.t(),
          id: term(),
          rank: float(),
          record: struct(),
          display: map()
        }
end

defmodule Samen.Search do
  @moduledoc """
  The KERNEL full-text search engine (WS-E E4.1; ADR-027) — `query/3` over the
  non-PII tsvector, registry-gated, org-scoped, ranked, bounded, and PII-safe at
  QUERY time. Mirrors ADR-020's kernel-engine / web-UI split: this module is the
  pure, web-dep-free query builder every caller (⌘K palette, per-list box, future
  API search) shares; `Samen.UI.command_palette` is the only UI.

  ## PII-safety at BOTH ends — the QUERY end is WS-E's new guarantee

  Index-time is already guarded: `Samen.Scopes.Primitives.SearchIndexGuard` refuses
  to register a vault-routed column into a search index (T3.7 red path). WS-E adds the
  QUERY-time guarantee, in two layers that both key on the SAME registry:

    1. **Registered-column-only (RP-SE-1 / AC-G9-2).** `query/3` builds its
       `websearch_to_tsquery` filter ONLY from columns present in the `SearchIndex`
       registry for the acting org — and re-refuses any that is a `pii_attribute` or
       is not a real attribute of the resource. A term can never target an arbitrary /
       unregistered / vaulted column. (Sabotaging the engine to search an arbitrary
       column FAILS its red-path; the index guard's PII refusal stays green.)

    2. **Result masking per plane (RP-SE-2 / AC-G9-3).** EVERY matched row is projected
       through `Samen.Api.PiiResolution.resolve/4` on the actor's plane BEFORE it
       leaves this module — a masked field can neither be a *match* (layer 1) nor leak
       as a *display* field (this layer). Operator-without-grant sees `••••`; the
       tenant sees its own plaintext. This is the "search results" entry on the
       masking watch-list (a per-plane red-path proves it).

  ## Org-scoped + bounded by construction (RP-SE-3 / AC-G9-4)

  Every read runs `Ash.read!(query, scope: scope)` — the resource's `OrgScope` read
  policy applies, so a search from org A can never return org B rows — and carries an
  explicit `limit` (per-resource and global), so search can never become an unbounded
  read. This is the "Reads conventions" (always-limit, org-scoped) applied in the
  kernel; `samen_web`'s `Reads` builds the same discipline for list pages.

  ## Fail-closed (RP-SE-4 / AC-G9-5)

  An empty/blank term, an org with no registered index, a resource with no registered
  non-PII field, or a resource the caller did not offer → `[]`. There is no
  "match-all" default and no full-table dump.

  ## The tsvector

  The query builds `to_tsvector(ts_config, coalesce(field₁,'') || ' ' || …)` over the
  registered NON-PII field columns at query time and matches it with
  `websearch_to_tsquery`, ranking by `ts_rank`. The framework-owned searchable columns
  (the `File` resource's `filename`/`content_type`) additionally carry a DB trigger +
  GIN functional index (the E4 tsvector-populate migration) so File search is
  index-backed; other registered resources are correct via the same query-time
  expression and get their own GIN index as a documented follow-on when registered.
  """

  import Ash.Expr

  alias Samen.Search.Result

  @default_limit 20
  @default_ts_config "english"

  @doc """
  Run a full-text search for `term` on `scope`, returning ranked `%Samen.Search.Result{}`s.

  `opts` (required seams — the caller wires the mount's facts):

    * `:resources`    — REQUIRED. The candidate resource modules the caller offers
      (from the mount's domain). Only a registry row whose `resource_name` names one
      of these is searched (deny-by-default cross-domain).
    * `:search_index` — REQUIRED. The `SearchIndex` registry resource module to read
      the org's registered `(resource, field, vector_column)` rows from.
    * `:repo`         — REQUIRED. The vault repo `PiiResolution` resolves through.
    * `:limit`        — global cap on returned results (default `#{@default_limit}`).
    * `:per_resource_limit` — per-resource cap before the global merge (default `:limit`).
  """
  @spec query(map(), term(), keyword()) :: [Result.t()]
  def query(scope, term, opts \\ []) do
    case normalize(term) do
      "" ->
        []

      normalized ->
        resources = Keyword.get(opts, :resources, [])
        index_mod = Keyword.fetch!(opts, :search_index)
        repo = Keyword.fetch!(opts, :repo)
        limit = Keyword.get(opts, :limit, @default_limit)
        per = Keyword.get(opts, :per_resource_limit, limit)

        by_resource =
          index_mod
          |> read_registry(scope)
          |> Enum.group_by(& &1.resource_name)

        resources
        |> Enum.flat_map(fn resource ->
          entries = Map.get(by_resource, resource_key(resource), [])
          search_one(resource, entries, normalized, scope, repo, per)
        end)
        |> Enum.sort_by(& &1.rank, :desc)
        |> Enum.take(limit)
    end
  end

  # -- one resource ------------------------------------------------------------

  defp search_one(_resource, [], _term, _scope, _repo, _limit), do: []

  defp search_one(resource, entries, term, scope, repo, limit) do
    ts_config = entries |> List.first() |> Map.get(:ts_config) || @default_ts_config

    # Registered-column-only + non-PII (RP-SE-1). The registry field_names are the
    # ONLY columns searched; each must be a real attribute AND not vault-routed. The
    # SearchIndexGuard already refuses PII at register-time — this is the query-time
    # twin so a smuggled/misconfigured PII column is refused HERE too.
    pii = pii_names(resource)

    fields =
      entries
      |> Enum.map(& &1.field_name)
      |> Enum.map(&existing_attribute(resource, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(&(&1 in pii))
      |> Enum.uniq()

    case fields do
      [] ->
        []

      fields ->
        tsv = tsvector_expr(fields, ts_config)

        match =
          expr(fragment("? @@ websearch_to_tsquery(?::text::regconfig, ?)", ^tsv, ^ts_config, ^term))

        rank =
          expr(fragment("ts_rank(?, websearch_to_tsquery(?::text::regconfig, ?))", ^tsv, ^ts_config, ^term))

        rows =
          resource
          |> Ash.Query.new()
          |> Ash.Query.ensure_selected(attribute_names(resource))
          |> Ash.Query.do_filter(match)
          |> Ash.Query.calculate(:search_rank, :float, rank)
          |> Ash.Query.sort([{calc(^rank, type: :float), :desc}])
          |> Ash.Query.limit(limit)
          |> Ash.read!(scope: scope)

        # RP-SE-2: project EVERY row through PiiResolution on the actor's plane before
        # it leaves the engine. The display allowlist is the registered non-PII fields.
        Samen.Api.PiiResolution.resolve(rows, resource, actor_of(scope), repo: repo)
        |> Enum.map(fn record ->
          %Result{
            resource: resource,
            resource_name: resource_key(resource),
            id: Map.get(record, :id),
            rank: to_float(rank_of(record)),
            record: record,
            display: Map.take(record, fields)
          }
        end)
    end
  end

  # -- expression building -----------------------------------------------------

  # to_tsvector(config, coalesce(f₁,'') || ' ' || coalesce(f₂,'') || …) over the
  # registered non-PII field columns (real attribute refs).
  defp tsvector_expr(fields, ts_config) do
    concat =
      fields
      |> Enum.map(fn f -> expr(fragment("coalesce(?, '')", ^ref(f))) end)
      |> Enum.reduce(fn piece, acc -> expr(fragment("? || ' ' || ?", ^acc, ^piece)) end)

    expr(fragment("to_tsvector(?::text::regconfig, ?)", ^ts_config, ^concat))
  end

  # -- registry / introspection ------------------------------------------------

  defp read_registry(index_mod, scope) do
    index_mod
    |> Ash.Query.new()
    |> Ash.Query.do_filter(expr(enabled == true))
    |> Ash.read!(scope: scope)
  rescue
    _ -> []
  end

  # The registry stores `resource_name` as the module's inspect form
  # (e.g. "Demo.PrimitivesScope.File").
  defp resource_key(resource) when is_atom(resource), do: inspect(resource)

  # Resolve a registered field_name string to a real attribute atom WITHOUT minting
  # atoms; nil if it is not an existing attribute of the resource (fail-closed).
  defp existing_attribute(resource, name) when is_binary(name) do
    atom = String.to_existing_atom(name)
    if Ash.Resource.Info.attribute(resource, atom), do: atom, else: nil
  rescue
    ArgumentError -> nil
  end

  defp attribute_names(resource) do
    resource |> Ash.Resource.Info.attributes() |> Enum.map(& &1.name)
  end

  defp pii_names(resource) do
    resource
    |> Samen.Pii.Info.pii_attributes()
    |> Enum.map(& &1.name)
  rescue
    _ -> []
  end

  # The ad-hoc `:search_rank` expression calc lands in the record's `calculations`
  # map (not a struct field); PiiResolution preserves it.
  defp rank_of(%{calculations: %{} = calcs}), do: Map.get(calcs, :search_rank)
  defp rank_of(_), do: nil

  defp actor_of(%Samen.Scope{actor: actor}), do: actor
  defp actor_of(%{actor: actor}) when is_map(actor), do: actor
  defp actor_of(actor) when is_map(actor), do: actor
  defp actor_of(_), do: %{}

  defp normalize(term) when is_binary(term), do: String.trim(term)
  defp normalize(nil), do: ""
  defp normalize(term), do: term |> to_string() |> String.trim()

  defp to_float(n) when is_float(n), do: n
  defp to_float(n) when is_integer(n), do: n * 1.0
  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float(_), do: 0.0
end
