defmodule Samen.AuditEvent do
  @moduledoc """
  The `aud_event` append-only event/audit tier (T2.2; doc §data bullets).

  ## Schema

  `aud_event` is a PostgreSQL table PARTITIONED BY RANGE on `aud_occurred_at`
  (monthly RANGE partitions created ahead of time by `Samen.AuditEvent.PartitionManager`, plus an
  `aud_event_default` partition that catches a row whose time is in no month so the write never fails — and
  `insert/2` reports such a row loudly).
  A BRIN index on the time column gives sub-KB index overhead over huge append-only tables.

  ## Append-only enforcement (belt and braces)

  Two independent layers refuse mutations:

    1. **Role revocation** — `REVOKE UPDATE, DELETE ON aud_event FROM <app_role>` in the
       migration.  The app role literally cannot issue UPDATE/DELETE SQL.

    2. **Database trigger** — `aud_event_append_only_tg` raises an exception on every
       UPDATE or DELETE attempt.  Even a Postgres superuser who re-grants UPDATE to the role
       will be stopped at the trigger layer.

  ## Token-only invariant

  `aud_event` carries only:
    * bounded IDs (uuid, opaque string ids)
    * vault-FK tokens (`vt_*` prefixed strings)
    * enums (bounded string event categories)
    * timestamps
    * metadata JSON (counts, tier descriptors — no plaintext subject content)

  The `no_plaintext_pii` CI tier (`Samen.NoPlaintextPii.Tiers.AudEvent`) asserts this
  invariant via the same allow-list + PII-name-heuristic approach as the
  `AuditRows` tier.

  ## Partitioned-table catalog handling

  Because `aud_event` is a PARTITIONED TABLE, it has no physical rows itself — data
  lives in child partitions (`aud_event_y2026m07`, etc.).  The catalog must reference
  the *logical* parent table (`aud_event`), not the individual partitions (which share
  the same column layout and are implementation details of the storage, not distinct
  resources).  The `catalog_sync` call in the migration targets the parent table name;
  child partitions are created later by the partition manager and do NOT need catalog
  rows (they are transparent slices of the parent's schema).

  `information_schema.columns` returns columns for the PARENT table (not inherited from
  partition children), so the no_plaintext_pii `AudEvent` tier queries the parent and
  sees the correct column set.

  ## Usage — writing an event

  `Samen.AuditEvent.insert/2` is the one write path.  It takes a map of attrs carrying
  only token-safe fields (event type, subject_id as an opaque token/id, actor_id, etc.)
  and inserts via raw Ecto SQL so it works inside an existing `Ecto.Multi` or standalone.

      Samen.AuditEvent.insert(repo, %{
        aud_event_type:   "grant_lifecycle",
        aud_subject_id:   subject_id,   # opaque id — NOT plaintext PII
        aud_actor_id:     actor_id,
        aud_correlation:  request_id,
        aud_detail:       "event=granted ...",  # operator metadata, no subject PII
        aud_occurred_at:  DateTime.utc_now()
      })

  Called from `Samen.Reveal.Grants.write_audit/2` and `Samen.Erasure.seal_db_tiers/5`.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  # abbrev: "aud" — all columns carry the `aud_` prefix (self-qualifying storage idiom).
  @primary_key {:id, :binary_id, autogenerate: true, source: :aud_id}
  schema "aud_event" do
    # Bounded event category enum: "grant_lifecycle" | "erasure" | "reveal" |
    # "system" | "policy_denial".  Never a free-form subject-content string.
    field(:event_type, :string, source: :aud_event_type)

    # Opaque subject identifier (NOT plaintext PII — the subject's UUID or
    # the vault-FK token, never their name/email/SSN).
    field(:subject_id, :string, source: :aud_subject_id)

    # Who performed the action (operator-class actor id — opaque, not plaintext name).
    field(:actor_id, :string, source: :aud_actor_id)

    # Correlation id: request_id / grant_id / job_id (opaque UUID).
    field(:correlation_id, :binary_id, source: :aud_correlation_id)

    # Operator-authored metadata (why/outcome): carries actor-authored reason strings
    # and system outcome tokens ("granted", "denied", "shredded"), NOT subject PII.
    field(:detail, :string, source: :aud_detail)

    # The partition key: when this event occurred.  Determines which child partition
    # receives the row (Postgres routes by range).
    field(:occurred_at, :utc_datetime_usec, source: :aud_occurred_at)
  end

  # ---------------------------------------------------------------------------
  # Write path
  # ---------------------------------------------------------------------------

  @doc """
  Insert a single audit event row.  Works inside a repo transaction or standalone.

  `attrs` must carry only token-safe fields (see schema doc).  The `occurred_at`
  defaults to `DateTime.utc_now()` if not provided.

  Returns `{:ok, %AuditEvent{}}` or `{:error, changeset}`.
  """
  @spec insert(module(), map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def insert(repo, attrs) when is_atom(repo) and is_map(attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    claimed = Map.get(attrs, :occurred_at) || Map.get(attrs, "occurred_at") || now
    detail = Map.get(attrs, :detail) || Map.get(attrs, "detail")

    # The chokepoint: whoever calls (the Writer, which has already clamped for the chain's sake, or a direct
    # caller), a future `occurred_at` never becomes the partition key.
    {occurred_at, detail, clamped?} = clamp_future(claimed, detail)

    attrs = Map.put(attrs, :occurred_at, occurred_at)
    attrs = if clamped?, do: Map.put(attrs, :detail, detail), else: attrs

    cs =
      %__MODULE__{}
      |> Ecto.Changeset.cast(
        attrs,
        [:event_type, :subject_id, :actor_id, :correlation_id, :detail, :occurred_at]
      )
      |> Ecto.Changeset.validate_required([:event_type, :occurred_at])

    case repo.insert(cs) do
      {:ok, row} ->
        note_default_landing(repo, row)
        {:ok, row}

      other ->
        other
    end
  end

  @doc """
  The rule for a caller-supplied `occurred_at`, the PARTITION KEY (ARCH-9; ADR-002 amendment):
  `{occurred_at, detail, clamped?}`.

    * not a `DateTime` -> now;
    * in the past, any distance -> kept (a replay or deferred anchor carries the time the thing happened; older than
      every partition it lands in DEFAULT, reported);
    * further ahead than `:audit_future_skew_seconds` (default 300) -> CLAMPED to now, the claimed time appended to
      `detail` (`occurred_at_claimed=…`), the clamp reported (`audit_occurred_at_clamped`,
      `[:samen, :audit, :occurred_at, :clamped]`). Never rejected: a timestamp must not make an audited
      privileged action fail.

  Called by `insert/2` (every writer) and by `Samen.AuditChain.Writer` (which needs the clamped values to commit
  the same time and detail into the chain).
  """
  @spec clamp_future(term(), String.t() | nil) :: {DateTime.t(), String.t() | nil, boolean()}
  def clamp_future(occurred_at, detail) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    case occurred_at do
      %DateTime{} = dt ->
        dt = DateTime.truncate(dt, :microsecond)

        if DateTime.diff(dt, now, :second) > future_skew_seconds() do
          Samen.Observability.Failure.report(:write, :audit_occurred_at_clamped, nil, :future_occurred_at, [])
          :telemetry.execute([:samen, :audit, :occurred_at, :clamped], %{count: 1}, %{})
          {now, clamp_note(detail, dt), true}
        else
          {dt, detail, false}
        end

      _ ->
        {now, detail, false}
    end
  end

  defp clamp_note(detail, claimed) do
    note = "occurred_at_claimed=#{DateTime.to_iso8601(claimed)}"
    if is_binary(detail) and detail != "", do: detail <> " " <> note, else: note
  end

  defp future_skew_seconds, do: Application.get_env(:samen_core, :audit_future_skew_seconds, 300)

  # A row whose time is in no monthly partition lands in `aud_event_default` instead of failing the write (ARCH-9).
  # That is the safety net doing its job, and it must not be silent. The test compares the row's time with the
  # partition bounds KNOWN IN MEMORY (`PartitionManager.lands_in_default?/2`): no query per write while they are
  # fresh, and when they must be re-read the read is a SAVEPOINT, so a failing read cannot put the caller's
  # transaction into the aborted state (25P02) and lose the audited write. A read that fails is reported (the
  # landing then goes unclassified — loudly) and never undoes the insert.
  defp note_default_landing(repo, row) do
    case Samen.AuditEvent.PartitionManager.lands_in_default?(repo, row.occurred_at) do
      {:ok, true} -> Samen.AuditEvent.PartitionManager.report_default_landing("aud_event")
      {:ok, false} -> :ok
      {:error, reason} -> Samen.Observability.Failure.report(:audit_default_landing_probe, nil, reason)
    end

    :ok
  rescue
    e ->
      Samen.Observability.Failure.report(:audit_default_landing_probe, nil, e)
      :ok
  end

  # ---------------------------------------------------------------------------
  # Read helpers (for tests and the partition manager)
  # ---------------------------------------------------------------------------

  @doc """
  List all `aud_event` rows for a subject (ordered by `aud_occurred_at` desc).
  Used by tests and the destruction oracle (T2.9).
  """
  @spec for_subject(module(), String.t()) :: [t()]
  def for_subject(repo, subject_id) when is_atom(repo) and is_binary(subject_id) do
    import Ecto.Query, only: [from: 2]

    repo.all(
      from(a in __MODULE__,
        where: a.subject_id == ^subject_id,
        order_by: [desc: a.occurred_at]
      )
    )
  end
end
