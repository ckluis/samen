defmodule Samen.AuditEvent do
  @moduledoc """
  The `aud_event` append-only event/audit tier (T2.2; doc §data bullets).

  ## Schema

  `aud_event` is a PostgreSQL table PARTITIONED BY RANGE on `aud_occurred_at`
  (monthly RANGE partitions created ahead of time by `Samen.AuditEvent.PartitionManager`).
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
    occurred_at = Map.get(attrs, :occurred_at) || Map.get(attrs, "occurred_at") || now

    cs =
      %__MODULE__{}
      |> Ecto.Changeset.cast(
        Map.put(attrs, :occurred_at, occurred_at),
        [:event_type, :subject_id, :actor_id, :correlation_id, :detail, :occurred_at]
      )
      |> Ecto.Changeset.validate_required([:event_type, :occurred_at])

    repo.insert(cs)
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
