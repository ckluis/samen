defmodule Samen.Impersonation.Session do
  @moduledoc """
  A short-TTL, single-org impersonation session (T4.1; doc §control lead: "The seam
  is impersonation: an operator opens a tenant and sees its real UI, but the session
  carries no reveal grant, so personal data renders •••• by default").

  This is the operator-plane analogue of `Samen.Reveal.RevealGrant` (T1.6) — the same
  time-boxed mechanics, deliberately mirrored and reused where clean:

    * `operator_id`  — the DISTINCT operator-plane actor who opened the session. An
      operator actor is NOT a tenant member (`Samen.OperatorPlane.Actor`); it has its
      own RBAC. This id is a bounded operator id — never plaintext PII.
    * `org_id`       — the ONE target tenant org the session is scoped to. An
      impersonation session is single-org by construction (doc "the separate,
      single-org impersonation path"). The impersonation scope carries THIS org_id as
      the tenant boundary, so the tenant's own org-scope policy applies unchanged.
    * `reason`       — REQUIRED reason-for-access (doc §control: an approved grant is a
      row carrying `subject_id, granted_by, and reason`; impersonation mirrors the
      reason requirement). A session with no reason is refused (`open/1` validates it,
      the DB `NOT NULL` backstops it).
    * `expires_at`   — the bounded window (minutes-scale default). Policy denies the
      moment `now() > expires_at`, checked PER REQUEST (`active?/2`), even if the row
      is never cleaned up — an expired session fails closed exactly like no session
      (mirrors T1.6 clause (c), deny-on-read not deny-on-cleanup).
    * `closed_at`    — set by the same-tx Oban auto-expire worker at `expires_at`, or
      by a manual `close/2`. A closed session denies.

  ## No renew-in-place (mirrors T1.6 clause (e))

  There is NO function anywhere in `Samen.Impersonation.Sessions` that mutates a
  session's `expires_at`. Re-access after the window means a fresh `open/1` (a fresh
  reason). `attempt_extend/2` exists ONLY so the red-path test can prove that
  extending a session's window is refused.

  ## Masked by default — the session carries NO reveal grant

  Crucially, an impersonation session is NOT a reveal grant. The scope it produces
  (`Samen.Impersonation.Scope.for_session/1`) carries the target `org_id` and a
  member-equivalent role, but no reveal capability — so every vaulted field the
  impersonating operator reads renders `%Masked{}` (`••••`) through every egress
  (LiveView / JSON / CSV / log), by construction. Unmasking a subject is the SEPARATE
  second-party reveal path (T1.6), which the operator would have to open on top.

  Plain Ecto schema (not a full Ash resource), mirroring the `Samen.Reveal.RevealGrant`
  and `Samen.Vault.VaultRow` decision: this is kernel infrastructure consulted by the
  impersonation runtime, not a tenant-facing domain resource. It is abbrev-prefixed
  (`imp_*`) per the self-qualifying-storage idiom.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true, source: :imp_id}
  schema "imp_impersonation_session" do
    field(:operator_id, :string, source: :imp_operator_id)
    field(:org_id, :binary_id, source: :imp_org_id)
    field(:reason, :string, source: :imp_reason)
    field(:expires_at, :utc_datetime_usec, source: :imp_expires_at)
    field(:closed_at, :utc_datetime_usec, source: :imp_closed_at)

    # Close cause: "manual" | "expired" — a bounded token, never subject content.
    field(:close_cause, :string, source: :imp_close_cause)

    # Explicit (not `timestamps/1`) so LOGICAL names stay `inserted_at`/`updated_at`
    # while STORAGE is abbrev-prefixed (`imp_*`). `open/1` sets them explicitly.
    field(:inserted_at, :utc_datetime_usec, source: :imp_inserted_at)
    field(:updated_at, :utc_datetime_usec, source: :imp_updated_at)
  end
end
