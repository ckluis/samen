defmodule Samen.Retention do
  @moduledoc """
  Per-scope retention / TTL enforcement (F3.2). Turns "data lives forever unless a
  subject asks for erasure" into "each data class has a documented lifetime, and a
  worker enforces it" — the missing lifecycle half of the privacy story (today only
  the Oban pruner trims job rows at 7d; domain data had no TTL).

  ## Spec-driven, framework-first

  The framework does not know a host's resource modules, so retention is expressed as
  a list of `Samen.Retention.Spec` structs the HOST registers (app config
  `:samen_core, :retention_specs`), exactly like the rollup-erasure spec registry.
  Each spec says: *for this resource, rows whose `timestamp_field` is older than
  `ttl_seconds` are swept via `action`.*

  Two actions:

    * `:shred`  — the resource is subject-bearing (has vaulted PII). Each distinct
      `subject_field` value on an expired row is crypto-shredded via
      `Samen.Erasure.shred/2` — the key-destruction guarantee, not a copy-chase. The
      row's ciphertext becomes undecryptable everywhere at once. (Subscribers.)
    * `:delete` — the resource carries no subject key of its own (or is a pure
      event/log row); expired rows are hard-deleted (pruned). (Files/messages/tickets
      whose subject is erased via their parent, or whose retention is a straight prune.)
      When the resource is **blob-backed** (`Samen.Retention.blob_backed?/1` — it carries a
      `storage_key`), a `:delete` purge routes each expired row's blob through the governed,
      ref-counted, fail-honest `Samen.Files.delete_file/3` chokepoint (last-reference-aware,
      T130-safe, audited) — never a raw `Ash.destroy!` that drops the row and orphans the raw
      file bytes (ADR-046 §8 residual #3). The `:storage`/`:storage_config` `Spec` fields name
      the adapter.

  ## Fail-closed cutoff — the load-bearing safety

  A spec with a non-positive / non-integer `ttl_seconds` is REFUSED (skipped, logged):
  a zero/`nil` TTL would sweep the WHOLE table. Retention only ever deletes rows
  strictly older than a positive TTL — never "all rows". `cutoff/2` computes the wall
  (`now - ttl`); the sweep filters `timestamp_field <= cutoff`, so a row exactly at
  its TTL edge is swept and a fresher row is retained. This is the guarantee the trio
  proves (an over-TTL row IS swept; an in-TTL row is NEVER touched) and the sabotage
  flips.

  ## Documented defaults

  `default_ttl_seconds/0` gives the recommended per-class defaults a host starts from
  (files 365d · messages 180d · tickets 365d · subscribers 730d · archived 90d). They
  are DEFAULTS, not enforced values — a host sets its own retention in config; these
  document intent.

  ## E6 (soft-delete) retention interplay (ADR-040 §5.6)

  `Spec` gains no new fields for archivable resources — the existing `timestamp_field`
  seam carries the convention: `timestamp_field: :archived_at` means "purge N days
  after archive." Live rows have a NULL `archived_at` and never match the `<=` cutoff
  comparison — fail-safe by SQL semantics, with no special-casing needed. Two duties
  this module owns for every such spec:

    * **Archived-inclusive reads.** An archivable resource's DEFAULT read excludes
      archived rows (`Samen.Archival`/ash_archival's `FilterArchived`) — exactly the
      rows a retention sweep must see. `expired_query/2` detects an archivable
      resource (`Samen.Info.archivable?/1`) and reads through
      `Samen.Archival.archived_query/1` (the `:archived` include-path) instead of the
      resource's default read.
    * **`:delete` rides `:destroy_permanently`.** On an archivable resource the
      PRIMARY `:destroy` action is now SOFT (it archives, ADR-040 §5.2) — a bare
      `Ash.destroy!/2` would silently re-archive an already-archived row instead of
      purging it. A `:delete` spec on an archivable resource therefore invokes the
      resource's `:destroy_permanently` action explicitly (never the soft path, never
      a bare Ecto delete) — the terminal hard-delete `:shred`/erasure already use
      untouched (§5.1).

  `archived_count/2` and `archivable_specs/2` are the two new surfaces this ADR asks
  for: a point-in-time "N archived items" count (pure metadata — never PII, INV-1: it
  is an integer from `Ash.count!/2`, never selects/decrypts a vaulted field), and a
  catalog-driven spec builder so a host (or a test) never hand-lists the archivable
  roster — see their docs below.
  """

  require Ash.Query
  require Logger

  alias Samen.Retention.Spec

  @doc "Recommended default TTLs per data class (seconds). Documentation, not enforcement."
  @spec default_ttl_seconds() :: %{atom() => pos_integer()}
  def default_ttl_seconds do
    day = 24 * 60 * 60

    %{
      files: 365 * day,
      messages: 180 * day,
      tickets: 365 * day,
      subscribers: 730 * day,
      # "purge N days after archive" (ADR-040 §5.6) — the trash-retention default for
      # any `archivable: true` resource's `timestamp_field: :archived_at` spec.
      archived: 90 * day
    }
  end

  @doc """
  Count of currently-archived rows for `resource` — the archived-count surface
  (ADR-040 §5.6/§5.9: "an operator/tenant can see N archived items"). Reads through
  the archived-inclusive `:archived` path (`Samen.Archival.archived_query/1`, scoped
  to `not is_nil(archived_at)`), so this is the same set a trash view or the sweep
  itself would purge from.

  A non-archivable resource always reports `0` (nothing can be archived).

  INV-1: this is metadata, never PII — `Ash.count!/2` never selects or decrypts a
  vaulted field, so the count cannot leak a masked value regardless of the caller's
  vault/KMS availability. `opts` are forwarded to `Ash.count!/2` (e.g. `scope:` /
  `authorize?:` for a tenant/operator-facing surface — the internal sweep call below
  passes `authorize?: false` like its other internal reads, matching the existing
  house convention for framework-internal sweep reads).
  """
  @spec archived_count(module(), keyword()) :: non_neg_integer()
  def archived_count(resource, opts \\ []) do
    if Samen.Info.archivable?(resource) do
      resource |> Samen.Archival.archived_query() |> Ash.count!(opts)
    else
      0
    end
  end

  @doc """
  Build one `Retention.Spec` per archivable resource found by walking `domains`
  (`Samen.Catalog.resource_modules/1` filtered through `Samen.Info.archivable?/1`) —
  never a hand-maintained resource list, so this cannot silently drift as scopes flip
  `archivable: true` (ADR-040 §5.6's binding done-criterion: "assert via
  `Samen.Info.archivable?/1` enumeration, not a hand-maintained list").

  Every generated spec rides the binding convention: `timestamp_field: :archived_at`
  ("purge N days after archive"). `ttl_seconds` (default
  `default_ttl_seconds().archived`) and `action` (default `:delete`, rides
  `:destroy_permanently` per the moduledoc above; pass `action: :shred` for a
  subject-bearing resource-class subset) are host-tunable — no new host-config shape,
  per §5.6's own text ("`Spec` gains no new fields").
  """
  @spec archivable_specs([module()] | module(), keyword()) :: [Spec.t()]
  def archivable_specs(domains, opts \\ []) do
    ttl_seconds = Keyword.get(opts, :ttl_seconds, default_ttl_seconds().archived)
    action = Keyword.get(opts, :action, :delete)
    subject_field = Keyword.get(opts, :subject_field, :id)

    domains
    |> Samen.Catalog.resource_modules()
    |> Enum.filter(&Samen.Info.archivable?/1)
    |> Enum.map(fn resource ->
      %Spec{
        resource: resource,
        ttl_seconds: ttl_seconds,
        action: action,
        timestamp_field: :archived_at,
        subject_field: subject_field
      }
    end)
  end

  @doc "The retention cutoff wall for a TTL at `now`: rows at/before this instant are expired."
  @spec cutoff(pos_integer(), DateTime.t()) :: DateTime.t()
  def cutoff(ttl_seconds, now) when is_integer(ttl_seconds) and ttl_seconds > 0 do
    DateTime.add(now, -ttl_seconds, :second)
  end

  @doc """
  Sweep every spec. Returns `%{swept: total, archived: total_archived, by_spec:
  [%{resource, action, swept, archived}]}`.

  `opts`:
    * `:now`  — the sweep instant (defaults to `DateTime.utc_now/0`; tests pin it).
    * `:repo` — forwarded to the shred path (`Samen.Erasure.shred/2`).

  A spec with an invalid TTL is skipped (fail-closed) and contributes `swept: 0`.

  `archived` (per-spec and the top-level total) is the DISTINCT archived-row count
  taken after this spec's pass (`archived_count/2`, ADR-040 §5.6 "T37 c2") — never
  conflated with `swept` (the rows this pass actually purged/shredded): `archived` is
  "how many archived rows remain right now" (0 for a non-archivable resource), the
  same "N archived items" surface a trash view would show.

  Emits `[:samen, :retention, :sweep]` telemetry with `%{swept: total, specs: n,
  archived: archived_total}`.
  """
  @spec sweep([Spec.t()], keyword()) :: %{
          swept: non_neg_integer(),
          archived: non_neg_integer(),
          by_spec: [map()]
        }
  def sweep(specs, opts \\ []) when is_list(specs) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    by_spec =
      Enum.map(specs, fn spec ->
        spec = Spec.normalize(spec)
        swept = sweep_one(spec, now, opts)
        archived = archived_count(spec.resource, authorize?: false)
        %{resource: spec.resource, action: spec.action, swept: swept, archived: archived}
      end)

    total = Enum.reduce(by_spec, 0, &(&1.swept + &2))
    archived_total = Enum.reduce(by_spec, 0, &(&1.archived + &2))

    :telemetry.execute(
      [:samen, :retention, :sweep],
      %{swept: total, specs: length(specs), archived: archived_total},
      %{}
    )

    %{swept: total, archived: archived_total, by_spec: by_spec}
  end

  # A single spec. Refuse an invalid TTL (fail-closed — never sweep the whole table).
  defp sweep_one(%Spec{ttl_seconds: ttl} = spec, _now, _opts)
       when not (is_integer(ttl) and ttl > 0) do
    Logger.error(
      "[Samen.Retention] REFUSING spec for #{inspect(spec.resource)} — invalid ttl_seconds " <>
        "#{inspect(ttl)} (a non-positive TTL would sweep the whole table). Skipped."
    )

    0
  end

  defp sweep_one(%Spec{action: :delete} = spec, now, opts) do
    wall = cutoff(spec.ttl_seconds, now)

    expired =
      spec
      |> expired_query(wall)
      # A blob-backed (`storage_key`) resource must also purge its raw file bytes, so ensure
      # the key + org are loaded for the governed delete (they are not selected by default).
      |> ensure_delete_fields(spec)
      # authz-scope: system retention sweep — cross-org BY DESIGN (purges EVERY tenant's
      # rows past the TTL cutoff, narrowed by expired_query/2's timestamp filter); runs
      # under no tenant actor, selects no vault field. Cannot be org_id-pinned (T132).
      |> Ash.read!(authorize?: false)

    if blob_backed?(spec.resource) do
      # ADR-046 §8 residual #3: a `:delete` purge of a `storage_key`-bearing resource must
      # route the blob through the GOVERNED, ref-counted `Samen.Files.delete_file/3`
      # chokepoint (last-reference-aware, T130-safe, audited) — NEVER a raw `Ash.destroy!`
      # that drops the row and orphans the bytes. delete_file does the terminal row destroy
      # AND the ref-counted blob delete in one transaction.
      purge_blobs(spec, expired, opts)
    else
      destroy_opts = terminal_destroy_opts(spec.resource)

      Enum.reduce(expired, 0, fn row, acc ->
        Ash.destroy!(row, destroy_opts)
        acc + 1
      end)
    end
  rescue
    e ->
      Logger.error("[Samen.Retention] delete sweep failed for #{inspect(spec.resource)}: #{inspect(e)}")
      0
  end

  defp sweep_one(%Spec{action: :shred} = spec, now, opts) do
    wall = cutoff(spec.ttl_seconds, now)
    repo = Keyword.get(opts, :repo)

    subjects =
      expired_query(spec, wall)
      # Ensure the org column is loaded (it is not selected by default) so it can be
      # threaded into the shred (D5 / ADR-046 §4.4).
      |> Ash.Query.ensure_selected([spec.org_field])
      # authz-scope: system retention sweep (shred path) — cross-org BY DESIGN (every
      # tenant's expired subject rows, narrowed by expired_query/2's TTL filter); no
      # tenant actor. Cannot be org_id-pinned (T132).
      |> Ash.read!(authorize?: false)
      # Carry the row's owning org alongside its subject id (D5 / ADR-046 §4.4): the
      # row was just read, so its org is in hand — thread it into the shred so the
      # erasure event lands on the TENANT's T4.3 chain, not "__global__".
      |> Enum.map(&{Map.get(&1, spec.subject_field), Map.get(&1, spec.org_field)})
      |> Enum.reject(fn {subject, _org} -> is_nil(subject) end)
      |> Enum.map(fn {subject, org} -> {to_string(subject), org} end)
      |> Enum.uniq_by(fn {subject, _org} -> subject end)

    Enum.reduce(subjects, 0, fn {subject_id, org_id}, acc ->
      # Only pass keys we actually have — an absent repo/org_id must NOT override
      # Erasure.shred/2's own defaults (a nil org_id would defeat the D5 fix by
      # forcing the "__global__" fallback).
      shred_opts =
        [repo: repo, org_id: org_id]
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)

      case Samen.Erasure.shred(subject_id, shred_opts) do
        {:ok, _} -> acc + 1
        {:error, _} -> acc
      end
    end)
  rescue
    e ->
      Logger.error("[Samen.Retention] shred sweep failed for #{inspect(spec.resource)}: #{inspect(e)}")
      0
  end

  # Purge each expired blob-backed row through the governed ref-counted chokepoint. A row
  # with no blob (nil/blank `storage_key`) has no bytes to purge, so it takes the ordinary
  # terminal row destroy. A governed delete that FAILS (fail-honest: e.g. an unconfigured
  # adapter) is logged and the row is PRESERVED (delete_file rolls back) — never dropping a
  # reference while the blob survives, and never counting a delete that did not happen.
  defp purge_blobs(spec, rows, opts) do
    repo = Keyword.get(opts, :repo) || AshPostgres.DataLayer.Info.repo(spec.resource, :mutate)
    destroy_opts = terminal_destroy_opts(spec.resource)

    Enum.reduce(rows, 0, fn row, acc ->
      key = Map.get(row, :storage_key)

      cond do
        not (is_binary(key) and key != "") ->
          # No blob to purge — ordinary terminal row delete (unchanged behavior).
          Ash.destroy!(row, destroy_opts)
          acc + 1

        true ->
          scope = %{org_id: Map.get(row, spec.org_field), actor_id: "system:retention"}

          case Samen.Files.delete_file(scope, row,
                 file_module: spec.resource,
                 repo: repo,
                 storage: spec.storage,
                 storage_config: spec.storage_config
               ) do
            {:ok, _} ->
              acc + 1

            {:error, reason} ->
              Logger.error(
                "[Samen.Retention] governed blob delete failed for #{inspect(spec.resource)} " <>
                  "row #{inspect(Map.get(row, :id))}: #{inspect(reason)} — row PRESERVED " <>
                  "(fail-honest; the blob is never orphaned)."
              )

              acc
          end
      end
    end)
  end

  # Load the `storage_key`/org columns a governed `:delete` needs on a blob-backed resource
  # (they are not in the default select). A non-blob-backed resource's query is untouched.
  defp ensure_delete_fields(query, spec) do
    if blob_backed?(spec.resource) do
      Ash.Query.ensure_selected(query, [:storage_key, spec.org_field])
    else
      query
    end
  end

  @doc """
  Is `resource` **blob-backed** — does it carry a `storage_key` column, so a `:delete`
  retention sweep must route its bytes through the governed ref-counted
  `Samen.Files.delete_file/3` chokepoint (ADR-046 §8 residual #3)?

  This is the LIVE routing predicate `sweep_one/3`'s `:delete` arm branches on, and the
  same one the erasure-completeness gate (`Samen.Erasure.Completeness`) asserts is true for
  every discovered `storage_key` residue — so a change that stops routing blobs through the
  chokepoint flips BOTH the sweep behavior AND the gate (anti-tautology).
  """
  @spec blob_backed?(module()) :: boolean()
  def blob_backed?(resource) do
    Ash.Resource.Info.attribute(resource, :storage_key) != nil
  rescue
    _ -> false
  end

  # Rows whose retention timestamp is at/before the wall — the expired set. The field
  # is dynamic (a spec may retain on :inserted_at, :closed_at, :last_activity_at, …).
  #
  # ADR-040 §5.6: an archivable resource's DEFAULT read excludes archived rows (the
  # `Samen.Archival`/ash_archival `FilterArchived` preparation) — exactly the rows
  # retention must see (a `timestamp_field: :archived_at` spec can never match
  # anything through the default read: live rows have NULL archived_at, archived rows
  # are filtered out). Read through the archived-inclusive `:archived` path instead
  # (`Samen.Archival.archived_query/1`) so purge candidates are actually visible. This
  # is strictly more permissive, never less safe: a live row's `archived_at` is still
  # NULL under this base query and still never matches `<=` (fail-safe by SQL
  # semantics, unchanged).
  defp expired_query(%Spec{resource: resource, timestamp_field: field}, wall) do
    require Ash.Query

    base =
      if Samen.Info.archivable?(resource) do
        Samen.Archival.archived_query(resource)
      else
        resource
      end

    Ash.Query.filter(base, ^Ash.Expr.ref(field) <= ^wall)
  end

  # §5.6: on an archivable resource the PRIMARY `:destroy` is now SOFT (ADR-040 §5.2 —
  # a plain destroy archives). A bare `Ash.destroy!/2` in the `:delete` sweep would
  # therefore silently re-archive an already-archived row (a no-op against the very
  # row retention is supposed to purge) instead of actually removing it. Retention's
  # `:delete` action rides the terminal `:destroy_permanently` action explicitly on an
  # archivable resource — never the soft path, never a bare Ecto delete. A
  # non-archivable resource is unaffected: it has no `:destroy_permanently` action and
  # its primary `:destroy` is already a real hard delete (unchanged behavior).
  defp terminal_destroy_opts(resource) do
    if Samen.Info.archivable?(resource) do
      [action: :destroy_permanently, authorize?: false]
    else
      [authorize?: false]
    end
  end
end
