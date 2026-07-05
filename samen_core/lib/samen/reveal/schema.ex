defmodule Samen.Reveal.RevealRequest do
  @moduledoc """
  A request to reveal a subject's vaulted PII (T1.6 clause (a); doc D6).

  A requestor (operator-class actor) files a `RevealRequest` naming the
  `subject_id`, a `reason`, and optionally the `resource`/`action` the reveal is
  scoped to. A request on its own grants NOTHING — it must be approved by a
  DISTINCT party (`Samen.Reveal.Grants.approve/2`), which writes a
  `Samen.Reveal.RevealGrant`.

  Plain Ecto schema (not a full Ash resource), mirroring the `Samen.Vault.VaultRow`
  decision: the grant model is kernel infrastructure consulted by the
  `Samen.Reveal.Grant` seam, not a tenant-facing domain resource. It is still
  abbrev-prefixed (`rvq_*`) per the self-qualifying-storage idiom.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true, source: :rvq_id}
  schema "rvq_reveal_request" do
    field(:subject_id, :string, source: :rvq_subject_id)
    field(:requestor_id, :string, source: :rvq_requestor_id)
    field(:reason, :string, source: :rvq_reason)
    field(:resource, :string, source: :rvq_resource)
    field(:action, :string, source: :rvq_action)
    field(:status, :string, source: :rvq_status, default: "pending")

    # Explicit (not `timestamps/1`) so the LOGICAL field names stay
    # `inserted_at`/`updated_at` while STORAGE is abbrev-prefixed (`rvq_*`).
    # Set explicitly by the changesets in `Samen.Reveal.Grants`.
    field(:inserted_at, :utc_datetime_usec, source: :rvq_inserted_at)
    field(:updated_at, :utc_datetime_usec, source: :rvq_updated_at)
  end
end

defmodule Samen.Reveal.RevealGrant do
  @moduledoc """
  A time-boxed grant to reveal a subject's vaulted PII (T1.6 clause (a); doc D6).

  Written ONLY by `Samen.Reveal.Grants.approve/2` after a DISTINCT party approves
  a `Samen.Reveal.RevealRequest`. Carries:

    * `requestor_id` — copied from the request (who asked).
    * `granted_by`   — the DISTINCT approver. The DB CHECK
      `rvg_granted_by <> rvg_requestor_id` makes self-approval impossible at the
      database level (clause (b)).
    * `expires_at`   — the bounded window. The `:reveal` policy denies the moment
      `now() > expires_at`, even if the row is never cleaned up (clause (c) —
      deny on read, not on cleanup).
    * `revoked_at`   — set by the same-tx Oban auto-revoke job at `expires_at`
      (clause (d)), or on a manual revoke. A revoked grant denies.

  There is NO action anywhere in `Samen.Reveal.Grants` that mutates `expires_at`
  (clause (e), no renew-in-place). Re-access requires a fresh request + approval.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true, source: :rvg_id}
  schema "rvg_reveal_grant" do
    field(:request_id, :binary_id, source: :rvg_request_id)
    field(:subject_id, :string, source: :rvg_subject_id)
    field(:requestor_id, :string, source: :rvg_requestor_id)
    field(:granted_by, :string, source: :rvg_granted_by)
    field(:reason, :string, source: :rvg_reason)
    field(:resource, :string, source: :rvg_resource)
    field(:action, :string, source: :rvg_action)
    field(:expires_at, :utc_datetime_usec, source: :rvg_expires_at)
    field(:revoked_at, :utc_datetime_usec, source: :rvg_revoked_at)

    # Explicit (not `timestamps/1`) so LOGICAL names stay `inserted_at`/
    # `updated_at` while STORAGE is abbrev-prefixed (`rvg_*`). `approve/2` sets
    # them explicitly.
    field(:inserted_at, :utc_datetime_usec, source: :rvg_inserted_at)
    field(:updated_at, :utc_datetime_usec, source: :rvg_updated_at)
  end
end

defmodule Samen.Reveal.RevealAudit do
  @moduledoc """
  An append-only reveal-grant lifecycle event row (T1.6 clause (f); doc G4).

  One row per lifecycle event: `requested`, `granted`, `revoked`, `expired`,
  `denied`. Plain rows now; the tamper-evident HASH CHAIN over these rows is
  Phase 4 (G4) — this schema deliberately leaves room for the chain columns
  (`prev_hash`/`hash`) to be added there without reshaping.

  Written inside the same transaction as the state change it records where that
  matters (grant write ⇒ `granted` row), so a rolled-back grant leaves no
  orphan audit row.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true, source: :rvl_id}
  schema "rvl_reveal_audit" do
    field(:event, :string, source: :rvl_event)
    field(:subject_id, :string, source: :rvl_subject_id)
    field(:actor_id, :string, source: :rvl_actor_id)
    field(:request_id, :binary_id, source: :rvl_request_id)
    field(:grant_id, :binary_id, source: :rvl_grant_id)
    field(:detail, :string, source: :rvl_detail)
    field(:recorded_at, :utc_datetime_usec, source: :rvl_recorded_at)
  end
end
