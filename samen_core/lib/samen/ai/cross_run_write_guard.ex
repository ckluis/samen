defmodule Samen.AI.CrossRunWriteGuard do
  @moduledoc """
  ADR-048 §7.1 / §8 `P12` / §10 row 3 **RATIFIED (a)** — the **CATEGORICAL WRITE-TIME
  REFUSAL** that keeps compaction output out of `pgvector` and out of every other
  cross-run store.

  ## The rule, and why it is a refusal and not a cleanup

  Every compaction artifact — fold summaries, extracted durable facts, memos, working
  notes, **any text a summarizer produced from a run's history** — is sealed inside the
  run's own DEK envelope (§7 D1). It is therefore **categorically ineligible** for
  embedding and for any cross-run memory store, fact table, or cache.

  The refusal happens **before the row lands**, never after. ADR-048 §8 `P12` says so in
  its own words: *"a build that embeds every fold summary into `pgvector` and dutifully
  marks them on shred passes both [`P7` and `P8`] and violates this."* A vector written
  and cleaned up later is an out-of-envelope residue of exactly the `email_bidx` species
  (ADR-046 §4.1 D1) for as long as it exists, and a vector outlives the key that could
  have made it unlinkable (ADR-043 M3: *vectors outlive grants and defeat crypto-shred*).
  So there is no cleanup arm in this module, by construction — only `check/2`.

  ## Why it is CATEGORICAL in both directions

    * **Categorical over destinations.** The decision reads the artifact's declared
      provenance and *nothing about where the write is going*. `cross_run_stores/0`
      enumerates the stores that exist today (`:pgvector` is the only one), but a store
      that is not on that list is refused just the same — a future fact table or cache
      cannot ship a hole by simply not being enumerated yet. §7.1 leaves the
      subject-DEK-keyed door open for a **later** memory ADR to walk through; until then
      every destination is closed to compaction output.
    * **Deny-by-default over provenance.** `@ordinary_source_kinds` is a closed ALLOWLIST,
      not a denylist of compaction kinds. A write declares itself as an ordinary record
      field (`:record_field`, or no `:source_kind` at all — the shape every pre-ADR-048
      caller has) and is allowed; **anything else is refused**, including a derived-artifact
      kind nobody has thought of yet. `compaction_source_kinds/0` exists to NAME §7.1's own
      enumeration for tests and error legibility, never as the decision surface — keying
      the decision off it would be exactly the enumerate-and-forget hole the deny-by-default
      belt in `Samen.AI.Embeddings.assert_embeddable/2` already refuses to be.

  ## Where this sits (it is the runtime sibling, it duplicates nothing)

  `Samen.Verifiers.EmbeddableNoPii` refuses, **at compile time**, a resource that declares
  a vault-routed (🔒) field embeddable — a claim about the FIELD. This module refuses, at
  **write time**, an otherwise perfectly embeddable field whose TEXT is compaction output —
  a claim about the ARTIFACT's provenance. The two are orthogonal and neither subsumes the
  other: `P12`'s red drives a fold summary at `Article.body`, a field that is legitimately
  embeddable and embeds fine for ordinary content (its positive control proves it).

  The single call site is `Samen.AI.Embeddings.embed_field/6` — the one governed unit every
  `store_vector/8` write funnels through (`embed_record/4` and `reembed_stale/1`'s
  `reembed_row/3` both route through it), so guarding it there is categorical over every
  lib call site `grep -rn 'store_vector\\|embed_field' samen_core/lib` reports.
  """

  @typedoc "A cross-run store a derived artifact could be written toward."
  @type store :: atom()

  # The cross-run stores that exist in the tree today. This list is for LEGIBILITY and for
  # the enumeration tests — it is deliberately NOT the decision surface (see the moduledoc:
  # a store missing from this list is refused too).
  @cross_run_stores [:pgvector]

  # The closed ALLOWLIST: provenances that are ordinary in-envelope record content and may
  # legitimately enter a derived index. `nil` (no declared `:source_kind`) is normalized to
  # `:record_field` — every caller predating ADR-048 is an ordinary record-field write.
  @ordinary_source_kinds [:record_field]

  # ADR-048 §7.1's OWN enumeration of compaction artifacts, named so a refusal is legible
  # and so a test can assert every one of them refuses. Never consulted by `check/2`.
  @compaction_source_kinds [
    :fold_summary,
    :durable_fact,
    :memo,
    :working_note,
    :compaction_summary
  ]

  @doc "The cross-run stores that exist today. Never the decision surface — see the moduledoc."
  @spec cross_run_stores() :: [store()]
  def cross_run_stores, do: @cross_run_stores

  @doc "ADR-048 §7.1's enumeration of compaction artifacts. Never the decision surface."
  @spec compaction_source_kinds() :: [atom()]
  def compaction_source_kinds, do: @compaction_source_kinds

  @doc "The closed allowlist of provenances that may enter a cross-run store."
  @spec ordinary_source_kinds() :: [atom()]
  def ordinary_source_kinds, do: @ordinary_source_kinds

  @doc """
  The write-time decision for a write of `opts`-declared provenance directed at `store`.

  Returns `:ok` only for a provenance on the closed `ordinary_source_kinds/0` allowlist;
  every other provenance is `{:error, :cross_run_write_refused}`, for EVERY `store`. The
  `store` is taken so the refusal reads as what it is — *this artifact may not go there,
  wherever there is* — and never to make the answer conditional on the destination.
  """
  @spec check(store(), keyword()) :: :ok | {:error, :cross_run_write_refused}
  def check(store, opts) when is_atom(store) and is_list(opts) do
    case source_kind(opts) do
      kind when kind in @ordinary_source_kinds -> :ok
      _derived -> {:error, :cross_run_write_refused}
    end
  end

  @doc """
  `true` when `opts` declares a provenance that may NOT enter a cross-run store. The pure
  predicate behind `check/2`, public so a caller can branch without matching on the tuple.
  """
  @spec cross_run_ineligible?(keyword()) :: boolean()
  def cross_run_ineligible?(opts) when is_list(opts), do: source_kind(opts) not in @ordinary_source_kinds

  defp source_kind(opts) do
    case Keyword.get(opts, :source_kind) do
      nil -> :record_field
      kind -> kind
    end
  end
end
