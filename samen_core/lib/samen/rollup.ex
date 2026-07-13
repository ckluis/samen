defmodule Samen.Rollup.Spec do
  @moduledoc """
  A registered rollup descriptor (T2.3; doc §data rollup code block).

  A rollup is a small derived summary table over the raw append-only `aud_event`
  tier. Dashboards read the rollup, NEVER the raw events (doc: "the dashboard query
  hits ENG_daily_rollup (small), not raw events"). Each rollup is described
  declaratively so three subsystems can share one definition:

    1. **The refresh framework** (`Samen.Rollup.rebuild_all/1`) — materialises the
       rollup from raw events on the cron schedule (T2.1 `scheduler_cron
       "*/10 * * * *"` shape).

    2. **The erasure orchestration** (`Samen.Erasure`) — on `shred/2`, for each
       registered rollup, takes the **rebuild** arm (recompute without the subject)
       when the raw partitions covering it are retained, or the **exclude/suppress**
       arm (mark the derived rows suppressed for the subject) when the window is
       archived/detached and cannot be rebuilt from raw.

    3. **The `no_plaintext_pii` oracle** (`Samen.NoPlaintextPii.Tiers.Rollup`) —
       asserts the rollup table carries only token / bounded-ID / count columns,
       never a plaintext PII type.

  ## Source dimension (ADR-018 — resolves the ADR-007 defer)

  A rollup is `source: :aud_event` (the default, unchanged behavior — the summary is
  recomputed from the raw append-only `aud_event` tier) or `source: :domain` (the
  ADR-018 generalization — the summary is recomputed from a governed DOMAIN table,
  e.g. the `mov` subscription-movement ledger, grain
  `(org_id, period_month, mov_kind) → sum(mrr_delta_cents), count`).

  The `:source` chooses which erasure arm applies (see `Samen.Rollup` module doc):

    * `:aud_event` — REBUILD deletes the subject's raw `aud_event` rows (privileged
      trigger-disabled path) then recomputes; SUPPRESS flags the derived rows when
      the covering `aud_event` window is archived/detached. This is the historical,
      partition-aware behavior — unchanged.

    * `:domain` — REBUILD deletes the subject's rows from the DOMAIN table
      (`subject_delete_sql`, parameterized on the subject id) then recomputes
      subject-free. Per ADR-018 §2, a domain-sourced rollup takes the REBUILD arm
      ALWAYS: the domain rows ARE the raw, there is no partition-detach window, so
      the post-shred recompute is subject-free by construction with NO dependence on
      the `aud_event` `raw_retained?` check. (`mov` is append-only at the Ash-action
      level — no destroy action — so the domain DELETE needs no trigger-disable, it
      is the sanctioned erasure path over a resource with no mutation surface.)

  ## Fields

    * `name` — the rollup's registry key (atom, e.g. `:daily_event_count`).
    * `source` — `:aud_event` (default) | `:domain`. See above.
    * `table` — the physical rollup table (abbrev-prefixed, e.g.
      `"rol_daily_event_count"`).
    * `subject_column` — the physical column on the rollup table carrying the
      subject id / bounded id the rollup is grouped/keyed by (the column erasure
      matches on). MUST be a bounded id / token, never plaintext PII.
    * `suppressed_column` — the boolean physical column the suppress arm flips
      (`true` = this derived row has had a subject excluded). NULL/false = live.
    * `rebuild_sql` — a `{delete_sql, insert_sql}` pair. `delete_sql` truncates the
      rollup (parameterless); `insert_sql` recomputes it from the SOURCE (raw
      `aud_event` for `:aud_event`, the domain table for `:domain`). Used by BOTH
      the scheduled refresh and the erasure rebuild arm (the rebuild arm first
      deletes the source rows for the subject, then re-runs this).
    * `subject_delete_sql` — (`:domain` only, REQUIRED for `:domain`; MUST be `nil`
      for `:aud_event`) a parameterized `DELETE FROM <domain_table> WHERE <col> = $1`
      run with `[subject_id]` by the domain REBUILD arm to erase the subject's rows
      from the domain table before the recompute. This is the ADR-018 load-bearing
      erasure hook: after it, the subject contributes 0 to the recomputed period
      sums. (For `:aud_event`, deletion targets `aud_event` via the internal
      privileged path — no per-spec SQL.)
    * `domain_table` — (`:domain` only, REQUIRED for `:domain`; MUST be `nil` for
      `:aud_event`) the physical domain-ledger table the `subject_delete_sql` erases
      from (e.g. `"mov_subscription_event"`). Declared INDEPENDENTLY of
      `subject_delete_sql` so the post-shred oracle's DbContent rollup sub-tier can
      run its OWN subject-residue CONTENT scan
      (`SELECT count(*) FROM domain_table WHERE domain_subject_column::text = $1`) —
      an assertion that does NOT trust the (possibly sabotaged) erasure hook's
      self-attested arm label. This is the B2-P1 fix: the oracle is CONTENT-extended,
      not merely NAME-extended, over the domain ledger (ADR-018 §3/§5, AC-G7-7).
    * `domain_subject_column` — (`:domain` only, REQUIRED for `:domain`; MUST be
      `nil` for `:aud_event`) the physical column on `domain_table` carrying the
      erased subject's id (e.g. `"mov_customer_id"` — the customer IS the subject).
      The oracle's independent content scan matches `::text = $1` on it. MUST be a
      bounded id / token, never plaintext PII (it is a subject key, the same kind
      `subject_delete_sql` keys on). Kept separate from `subject_delete_sql` so a
      sabotaged (mis-scoped/no-op) delete hook cannot also fool the residue scan.
    * `bounded_columns` — the full list of physical columns on the rollup table
      (all must be token / bounded-ID / count / enum / timestamp). The oracle tier
      asserts every one is non-plaintext.
  """

  @sources [:aud_event, :domain]

  @enforce_keys [:name, :table, :subject_column, :suppressed_column, :rebuild_sql, :bounded_columns]
  defstruct [
    :name,
    :table,
    :subject_column,
    :suppressed_column,
    :rebuild_sql,
    :bounded_columns,
    source: :aud_event,
    subject_delete_sql: nil,
    domain_table: nil,
    domain_subject_column: nil
  ]

  @type source :: :aud_event | :domain

  @type t :: %__MODULE__{
          name: atom(),
          source: source(),
          table: String.t(),
          subject_column: String.t(),
          suppressed_column: String.t(),
          rebuild_sql: {String.t(), String.t()},
          subject_delete_sql: String.t() | nil,
          domain_table: String.t() | nil,
          domain_subject_column: String.t() | nil,
          bounded_columns: [String.t()]
        }

  @doc "The rollup source dimensions ADR-018 recognizes."
  @spec sources() :: [source()]
  def sources, do: @sources

  @doc """
  Build a `%Spec{}` from plain config data (a map with atom keys) or pass a
  `%Spec{}` through unchanged.

  The rollup registry lives in `config :samen_core, :rollups` as PLAIN MAPS, not
  struct literals — config is evaluated before this module is loaded, so a struct
  literal in config cannot resolve `Spec.__struct__/1`. This builder converts each
  config map into a validated struct at runtime and **fails closed** on a
  malformed entry (missing/blank keys, wrong `rebuild_sql` shape).
  """
  @spec from_config(t() | map()) :: t()
  def from_config(%__MODULE__{} = spec) do
    validate!(spec)
    spec
  end

  def from_config(%{} = data) do
    spec = %__MODULE__{
      name: fetch!(data, :name),
      # :source defaults to :aud_event when a legacy config omits it (behavior
      # unchanged — every pre-ADR-018 rollup is an aud_event rollup).
      source: Map.get(data, :source, :aud_event),
      table: fetch!(data, :table),
      # Optional for :domain (subject-free aggregate); required for :aud_event —
      # validate!/1 enforces the per-source requirement fail-closed.
      subject_column: Map.get(data, :subject_column),
      suppressed_column: Map.get(data, :suppressed_column),
      rebuild_sql: fetch!(data, :rebuild_sql),
      # nil for :aud_event; required (validated below) for :domain.
      subject_delete_sql: Map.get(data, :subject_delete_sql),
      # The oracle's independent domain-ledger residue scan target — nil for
      # :aud_event; required (validated below) for :domain.
      domain_table: Map.get(data, :domain_table),
      domain_subject_column: Map.get(data, :domain_subject_column),
      bounded_columns: fetch!(data, :bounded_columns)
    }

    validate!(spec)
    spec
  end

  defp fetch!(data, key) do
    case Map.fetch(data, key) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "rollup spec is missing required key #{inspect(key)}: #{inspect(data)}"
    end
  end

  # Fail-closed shape validation: a misconfigured rollup must NOT silently pass
  # (a registered rollup the erasure policy + oracle operate on must be well-formed).
  defp validate!(%__MODULE__{} = s) do
    unless is_atom(s.name) and not is_nil(s.name) do
      raise ArgumentError, "rollup :name must be a non-nil atom, got #{inspect(s.name)}"
    end

    unless s.source in @sources do
      raise ArgumentError,
            "rollup #{inspect(s.name)} :source must be one of #{inspect(@sources)}, got #{inspect(s.source)}"
    end

    # The ADR-018 commitment made fail-closed: the :source dimension and the
    # domain erasure hook must be internally consistent, or the erasure policy
    # would operate on the wrong tier.
    case s.source do
      :domain ->
        unless is_binary(s.subject_delete_sql) and s.subject_delete_sql != "" do
          raise ArgumentError,
                "rollup #{inspect(s.name)} is source: :domain and MUST declare a non-empty " <>
                  ":subject_delete_sql (the parameterized DELETE the domain REBUILD arm runs to " <>
                  "erase the subject's domain rows before recompute — ADR-018 §2). Got " <>
                  "#{inspect(s.subject_delete_sql)}."
        end

        # The post-shred oracle scans the domain ledger for surviving subject rows
        # INDEPENDENTLY of the erasure hook (B2-P1 fix). A :domain spec must declare
        # WHERE to scan and WHICH column keys the subject, or the oracle would be
        # content-blind to domain-rollup residue (a sabotaged/no-op delete hook that
        # still emits the report entry would pass silently). Fail closed.
        unless is_binary(s.domain_table) and s.domain_table != "" do
          raise ArgumentError,
                "rollup #{inspect(s.name)} is source: :domain and MUST declare a non-empty " <>
                  ":domain_table (the physical domain-ledger table the post-shred oracle scans " <>
                  "for surviving subject rows — B2-P1, ADR-018 §3/§5). Got #{inspect(s.domain_table)}."
        end

        unless is_binary(s.domain_subject_column) and s.domain_subject_column != "" do
          raise ArgumentError,
                "rollup #{inspect(s.name)} is source: :domain and MUST declare a non-empty " <>
                  ":domain_subject_column (the subject-id column on :domain_table the oracle's " <>
                  "residue scan matches on — kept independent of :subject_delete_sql so a " <>
                  "sabotaged delete hook cannot fool the scan — B2-P1). Got " <>
                  "#{inspect(s.domain_subject_column)}."
        end

        # Hard-gate the scan identifiers (developer-controlled registry, but they
        # ride into oracle SQL — refuse anything not a plain snake_case token).
        safe_ident!(s.domain_table)
        safe_ident!(s.domain_subject_column)

      :aud_event ->
        for {field, value} <- [
              subject_delete_sql: s.subject_delete_sql,
              domain_table: s.domain_table,
              domain_subject_column: s.domain_subject_column
            ] do
          unless is_nil(value) do
            raise ArgumentError,
                  "rollup #{inspect(s.name)} is source: :aud_event and MUST NOT declare a " <>
                    "#{inspect(field)} (aud_event deletion targets the aud_event tier via the " <>
                    "internal privileged path, not per-spec domain SQL). Got #{inspect(value)}."
          end
        end
    end

    # `table` is always required. `subject_column`/`suppressed_column` are the
    # arm-matching columns for the :aud_event REBUILD/SUPPRESS arms — required for
    # :aud_event, OPTIONAL for :domain (a domain movement-sum rollup is subject-free
    # aggregate BY CONSTRUCTION — grain (org, period, kind) — so it has no per-subject
    # column to match/suppress on; the domain REBUILD arm erases via the domain
    # ledger's own `subject_delete_sql`, not a rollup-table column). When a :domain
    # spec DOES declare them (e.g. to reuse the aud_event oracle-tier shape), they
    # are still validated to be real bounded columns below.
    required_string_fields =
      case s.source do
        :domain -> [table: s.table]
        :aud_event -> [table: s.table, subject_column: s.subject_column, suppressed_column: s.suppressed_column]
      end

    for {field, value} <- required_string_fields do
      unless is_binary(value) and value != "" do
        raise ArgumentError, "rollup #{inspect(s.name)} #{field} must be a non-empty string, got #{inspect(value)}"
      end
    end

    case s.rebuild_sql do
      {del, ins} when is_binary(del) and is_binary(ins) and del != "" and ins != "" ->
        :ok

      other ->
        raise ArgumentError,
              "rollup #{inspect(s.name)} :rebuild_sql must be a {delete_sql, insert_sql} pair of " <>
                "non-empty strings, got #{inspect(other)}"
    end

    unless is_list(s.bounded_columns) and s.bounded_columns != [] and
             Enum.all?(s.bounded_columns, &(is_binary(&1) and &1 != "")) do
      raise ArgumentError,
            "rollup #{inspect(s.name)} :bounded_columns must be a non-empty list of non-empty " <>
              "strings, got #{inspect(s.bounded_columns)}"
    end

    # When a subject/suppressed column IS declared (always for :aud_event, optionally
    # for :domain), it must be a real bounded column (the arm / the oracle tier both
    # rely on it). A :domain spec that leaves them nil skips this — it is subject-free.
    if not is_nil(s.subject_column) and s.subject_column not in s.bounded_columns do
      raise ArgumentError,
            "rollup #{inspect(s.name)} :subject_column #{inspect(s.subject_column)} must appear in " <>
              ":bounded_columns (the erasure arm matches on it)"
    end

    if not is_nil(s.suppressed_column) and s.suppressed_column not in s.bounded_columns do
      raise ArgumentError,
            "rollup #{inspect(s.name)} :suppressed_column #{inspect(s.suppressed_column)} must appear " <>
              "in :bounded_columns (the suppress arm flips it)"
    end

    :ok
  end

  # A physical identifier that rides into oracle/erasure SQL must be a plain
  # snake_case token. Hard gate (identifiers come from the developer-controlled
  # rollup registry, never end-user input). Mirrors `Samen.Rollup.safe_ident!/1`.
  defp safe_ident!(name) do
    str = to_string(name)

    if Regex.match?(~r/\A[a-z_][a-z0-9_]*\z/, str) do
      str
    else
      raise ArgumentError,
            "unsafe SQL identifier in rollup spec: #{inspect(str)} " <>
              "(identifiers must match /^[a-z_][a-z0-9_]*$/)"
    end
  end
end

defmodule Samen.Rollup do
  @moduledoc """
  The rollup framework + **rebuild-or-exclude-on-erasure** policy (T2.3; doc §data
  "The data tier" rollup code block + §limits "honest edges" derived-aggregates
  bullet).

  ## Why rollups are governed separately from key-shred

  Crypto-shred (`Samen.Erasure`) destroys the subject's vault DEK, making every
  *vaulted* value undecryptable across every key-reachable tier at once. But a
  **derived aggregate** (a rollup / matview) computed BEFORE the shred can still
  encode the subject — e.g. a per-day per-org event *count* that included the
  subject's events. Key-shred does not touch a count. The doc names this a
  separately-governed surface:

  > "an aggregate computed before a shred must not resurrect the erased subject …
  >  where the raw partition is still retained the rollup is rebuilt without the
  >  subject, and where the erasure falls in an already-archived/detached window …
  >  the exclude/suppress arm applies and the erased subject is suppressed from the
  >  derived row instead."

  ## The two arms (per source — ADR-018)

  On `Samen.Erasure.shred/2`, `Samen.Rollup.erase_subject/3` is called for every
  registered rollup. The arm depends on the rollup's `:source`:

  **`source: :aud_event`** (the historical behavior — unchanged): the arm is chosen
  by `raw_retained?/3` — whether the raw `aud_event` partitions covering the
  subject are still retained:

    * **REBUILD arm** (raw retained): delete the subject's raw `aud_event` rows,
      then recompute the rollup from the (now subject-free) raw events. The derived
      row no longer counts the subject — the subject is *gone*, not merely masked.

    * **EXCLUDE/SUPPRESS arm** (window archived/detached): the raw rows are no
      longer available to rebuild from, so we cannot recompute a subject-free
      aggregate. Instead we mark the affected derived rows suppressed for the
      subject (flip `suppressed_column = true`) and record the suppression. The row
      still exists (the cohort statistic an operator may have already exported is
      not retroactively scrubbed — doc), but it is flagged suppressed so dashboards
      can honor the erasure. The archived-window case is SIMULATED in tests by
      forcing `raw_retained?: false` (documented simulation seam).

  **`source: :domain`** (the ADR-018 generalization): ALWAYS the REBUILD arm. The
  domain table (e.g. `mov_subscription_event`) IS the raw — there is no
  partition-detach window, so the subject's domain rows are deleted (via the spec's
  `subject_delete_sql`, parameterized on the subject id) and the rollup is
  recomputed subject-free. Post-shred the subject contributes 0 to the period sums
  BY CONSTRUCTION (its ledger rows are gone), with NO dependence on the `aud_event`
  `raw_retained?` check (ADR-018 §2). A forced `raw_retained?: false` does NOT
  divert a `:domain` rollup to suppress — the domain source has no archived-window
  arm; the erasure is a real recompute, always. This is the crypto-shred discriminator
  the destruction oracle proves for the `mov`/`mrr` tiers (AC-G7-7): a sabotaged
  recompute that still counted the subject leaves a re-identifying delta and
  FAILS the oracle.

  That FAIL is CONTENT-verified, not report-attested (B2-P1). The post-shred oracle
  (`Samen.NoPlaintextPii.Tiers.PostShred.DbContent`, `rollup` sub-tier) scans the
  domain ledger directly for surviving subject rows — `SELECT count(*) FROM
  <domain_table> WHERE <domain_subject_column>::text = $1` — INDEPENDENTLY of the
  erasure report's self-attested arm label and of the spec's `subject_delete_sql`.
  So a sabotaged/no-op delete hook that still emits an `arm=rebuild` report entry
  does NOT pass: the surviving ledger rows (whose delta re-materialises in the
  recomputed rollup) are caught as an oracle VIOLATION. A `:domain` spec therefore
  DECLARES `domain_table` + `domain_subject_column` (the scan target) separately from
  `subject_delete_sql`, so the residue scan cannot inherit the delete hook's bug.

  ## Registry

  Rollups are registered via config (`:rollups`) or passed explicitly. The registry
  is the single source of truth the refresh framework, the erasure orchestration,
  and the oracle all read.
  """

  alias Samen.Rollup.Spec

  @doc """
  The registered rollup specs.

  Configure via:

      config :samen_core, :rollups, [%Samen.Rollup.Spec{...}, ...]

  Host apps register their rollups here. `samen_core`'s own test/demo rollup is
  registered in config so the framework, erasure, and oracle all see it.
  """
  @spec specs(keyword()) :: [Spec.t()]
  def specs(opts \\ []) do
    raw =
      case Keyword.get(opts, :specs) do
        nil -> Application.get_env(:samen_core, :rollups, [])
        list -> list
      end

    # Build (and fail-closed validate) a `%Spec{}` from each registry entry.
    # Entries may be plain maps (from config) or already-built structs (tests).
    Enum.map(raw, &Spec.from_config/1)
  end

  @doc "Look up a registered rollup spec by name, or `nil`."
  @spec spec(atom(), keyword()) :: Spec.t() | nil
  def spec(name, opts \\ []) when is_atom(name) do
    Enum.find(specs(opts), fn %Spec{name: n} -> n == name end)
  end

  # ---------------------------------------------------------------------------
  # Refresh framework (the scheduled rebuild — RollupRefreshWorker calls this)
  # ---------------------------------------------------------------------------

  @doc """
  Rebuild ALL registered rollups from raw events. Called on the cron schedule by
  `Samen.Jobs.RollupRefreshWorker` (`*/10 * * * *`). Each rollup is truncated and
  recomputed from `aud_event` in one transaction.

  Returns `{:ok, %{name => rows_written}}`.
  """
  @spec rebuild_all(module(), keyword()) :: {:ok, %{atom() => non_neg_integer()}}
  def rebuild_all(repo, opts \\ []) when is_atom(repo) do
    results =
      Enum.reduce(specs(opts), %{}, fn %Spec{} = s, acc ->
        {:ok, n} = refresh(repo, s)
        Map.put(acc, s.name, n)
      end)

    {:ok, results}
  end

  @doc """
  Refresh (materialise) a single rollup from raw events. Truncate + recompute in
  one transaction. This is the dashboards' data source — the dashboard reads the
  rollup, never scans raw `aud_event`.
  """
  @spec refresh(module(), Spec.t()) :: {:ok, non_neg_integer()}
  def refresh(repo, %Spec{rebuild_sql: {delete_sql, insert_sql}} = _spec) when is_atom(repo) do
    {:ok, count} =
      repo.transaction(fn ->
        Ecto.Adapters.SQL.query!(repo, delete_sql, [])
        %{num_rows: n} = Ecto.Adapters.SQL.query!(repo, insert_sql, [])
        n
      end)

    {:ok, count}
  end

  # ---------------------------------------------------------------------------
  # Rebuild-or-exclude-on-erasure (the T2.3 policy — Samen.Erasure calls this)
  # ---------------------------------------------------------------------------

  @doc """
  **The erasure policy (T2.3 (b)).** For every registered rollup, erase `subject_id`
  by the correct arm and return a per-rollup report the erasure artifact records.

  For each rollup:

    * If the raw `aud_event` partitions covering the subject are **retained**
      (`raw_retained?/3` true), take the **REBUILD** arm: delete the subject's raw
      events, then recompute the rollup subject-free.

    * Otherwise (window **archived/detached**), take the **EXCLUDE/SUPPRESS** arm:
      flip `suppressed_column = true` on the subject's derived rows.

  MUST run inside the erasure transaction (the caller passes a repo already in a
  `repo.transaction`). Deleting raw events + rebuilding is idempotent (a second
  erasure deletes 0 more rows and rebuilds the same result).

  Returns `[%{"rollup" => name, "arm" => "rebuild"|"suppress", "rows_affected" => n}]`
  (string keys — this rides into the JSON `era_tiers` erasure-report column).
  """
  @spec erase_subject(String.t(), module(), keyword()) :: [map()]
  def erase_subject(subject_id, repo, opts \\ []) when is_binary(subject_id) and is_atom(repo) do
    Enum.map(specs(opts), fn %Spec{} = s ->
      erase_one(subject_id, repo, s, opts)
    end)
  end

  # ADR-018 arm selection, per source.
  #
  #   :domain     — ALWAYS rebuild. The domain rows ARE the raw; there is no
  #                 archived-window arm. A forced raw_retained?: false does NOT
  #                 divert a domain rollup to suppress (the erasure is a real
  #                 recompute, not a mask — ADR-018 §2).
  #   :aud_event  — REBUILD when raw retained, else SUPPRESS (unchanged behavior).
  defp erase_one(subject_id, repo, %Spec{source: :domain} = s, _opts) do
    domain_rebuild_arm(subject_id, repo, s)
  end

  defp erase_one(subject_id, repo, %Spec{source: :aud_event} = s, opts) do
    if raw_retained?(subject_id, repo, opts) do
      rebuild_arm(subject_id, repo, s)
    else
      suppress_arm(subject_id, repo, s)
    end
  end

  # DOMAIN REBUILD arm (ADR-018): delete the subject's rows from the DOMAIN table
  # (the spec's parameterized `subject_delete_sql`), then recompute the rollup
  # subject-free. After this the recomputed period sums no longer include the
  # subject's deltas — a real erasure across the domain ledger AND the derived
  # rollup at once. No trigger-disable needed: `mov` is append-only at the
  # Ash-action level (no destroy action), not a DB trigger, so the DELETE is the
  # sanctioned erasure path over a resource that exposes no mutation surface.
  defp domain_rebuild_arm(subject_id, repo, %Spec{subject_delete_sql: del_sql} = s) do
    %{num_rows: domain_rows_deleted} =
      Ecto.Adapters.SQL.query!(repo, del_sql, [subject_id])

    # Recompute the rollup from the now subject-free domain table.
    {:ok, _n} = refresh(repo, s)

    %{
      "rollup" => to_string(s.name),
      "arm" => "rebuild",
      "source" => "domain",
      "rows_affected" => domain_rows_deleted
    }
  end

  # REBUILD arm: delete the subject's raw events, recompute the rollup subject-free.
  # After this the derived row NO LONGER counts the subject — a real erasure, not a
  # mask. The pre-shred rollup (which counted the subject) is overwritten.
  defp rebuild_arm(subject_id, repo, %Spec{} = s) do
    # 1. Delete the subject's raw aud_event rows so the recompute excludes them.
    #    aud_event is append-only (trigger blocks UPDATE/DELETE by the app role),
    #    so erasure runs the DELETE as a privileged path: it disables the trigger
    #    for this session (SET LOCAL) — an erasure IS the sanctioned deletion path,
    #    the append-only guarantee protects against tampering, not lawful erasure.
    delete_subject_raw_events(subject_id, repo)

    # 2. Recompute the rollup from the now subject-free raw events.
    {:ok, _n} = refresh(repo, s)

    %{"rollup" => to_string(s.name), "arm" => "rebuild", "source" => "aud_event", "rows_affected" => 1}
  end

  # EXCLUDE/SUPPRESS arm: the raw window is archived/detached — cannot rebuild from
  # raw. Flip the suppressed flag on the subject's derived rows so dashboards honor
  # the erasure. The row survives (cohort stat not retroactively scrubbed) but is
  # flagged.
  defp suppress_arm(subject_id, repo, %Spec{} = s) do
    table = safe_ident!(s.table)
    subject_col = safe_ident!(s.subject_column)
    suppressed_col = safe_ident!(s.suppressed_column)

    # Compare on `::text` so the arm is robust to the physical type of the
    # subject column (UUID rollups, opaque-string rollups) and to the subject id's
    # representation. A subject id that does not exist in this rollup (e.g. a
    # non-UUID subject that was never rolled into a UUID-keyed rollup) simply
    # matches 0 rows — never a crash.
    sql =
      "UPDATE #{table} SET #{suppressed_col} = TRUE " <>
        "WHERE #{subject_col}::text = $1 AND (#{suppressed_col} IS DISTINCT FROM TRUE)"

    %{num_rows: n} = Ecto.Adapters.SQL.query!(repo, sql, [subject_id])

    %{"rollup" => to_string(s.name), "arm" => "suppress", "source" => "aud_event", "rows_affected" => n}
  end

  @doc """
  Are the raw `aud_event` rows covering `subject_id` still retained (so the rebuild
  arm is viable), or has the window been archived/detached (so the suppress arm
  applies)?

  The raw rows are retained iff the subject has rows in the *attached* `aud_event`
  partitions. Because `aud_event` is partitioned and detach removes a partition from
  the parent, a `SELECT ... FROM aud_event` only sees ATTACHED partitions — so a
  subject whose only events live in a detached partition returns 0 here → suppress
  arm. This is the mechanism that distinguishes the two arms.

  Override with `raw_retained?: bool` in opts (tests use this to force an arm
  deterministically without physically detaching a partition).
  """
  @spec raw_retained?(String.t(), module(), keyword()) :: boolean()
  def raw_retained?(subject_id, repo, opts \\ []) do
    case Keyword.fetch(opts, :raw_retained?) do
      {:ok, forced} when is_boolean(forced) ->
        forced

      :error ->
        %{rows: [[count]]} =
          Ecto.Adapters.SQL.query!(
            repo,
            "SELECT COUNT(*) FROM aud_event WHERE aud_subject_id = $1",
            [subject_id]
          )

        count > 0
    end
  end

  # ---------------------------------------------------------------------------
  # Raw-event deletion (the sanctioned erasure path through the append-only tier)
  # ---------------------------------------------------------------------------

  # Delete a subject's raw aud_event rows as part of an erasure. aud_event's
  # append-only trigger + role revocation protect against TAMPERING, not lawful
  # erasure. We temporarily disable the trigger for THIS transaction only
  # (session_replication_role = replica skips triggers) and re-enable at commit.
  # The role-revocation braces still apply, so this runs as the migration/owner
  # role in tests; in production the erasure worker runs under a role granted
  # DELETE on aud_event for exactly this path.
  defp delete_subject_raw_events(subject_id, repo) do
    # Disable triggers for this session so the append-only trigger does not block
    # the lawful erasure DELETE. Scoped to the transaction.
    Ecto.Adapters.SQL.query!(repo, "SET LOCAL session_replication_role = replica", [])

    %{num_rows: n} =
      Ecto.Adapters.SQL.query!(
        repo,
        "DELETE FROM aud_event WHERE aud_subject_id = $1",
        [subject_id]
      )

    # Restore trigger firing for the rest of the transaction (defence in depth:
    # any further writes in this tx see the append-only guarantee again).
    Ecto.Adapters.SQL.query!(repo, "SET LOCAL session_replication_role = origin", [])

    n
  end

  # A physical identifier must be a plain snake_case token. Hard gate (identifiers
  # come from the developer-controlled registry, never end-user input).
  defp safe_ident!(name) do
    str = to_string(name)

    if Regex.match?(~r/\A[a-z_][a-z0-9_]*\z/, str) do
      str
    else
      raise ArgumentError,
            "unsafe SQL identifier in rollup spec: #{inspect(str)} " <>
              "(identifiers must match /^[a-z_][a-z0-9_]*$/)"
    end
  end
end
