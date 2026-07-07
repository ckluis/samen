defmodule SamenCore.TestRepo.Migrations.ImpersonationSessions do
  @moduledoc """
  The T4.1 masked-impersonation session table (doc §control "Running the business").

  One table, abbrev-prefixed per the self-qualifying-storage idiom:

    * `imp_impersonation_session` — an operator opens a short-TTL, single-org session
      with a REQUIRED reason-for-access. Carries `expires_at` (bounded minutes-scale
      default) and `closed_at` (the auto-expire worker / manual close flips this).

  ## Mirrors the T1.6 reveal-grant mechanics (deliberately)

  Like `rvg_reveal_grant`, `imp_impersonation_session`:
    * carries a bounded `expires_at`; the runtime denies once `now() > expires_at`,
      checked PER REQUEST (deny-on-read), independent of whether the auto-expire job
      ran (clause: deny on read, not on cleanup);
    * has NO update path that mutates `expires_at` (no renew-in-place) — re-access
      means a fresh `open/1`;
    * `imp_reason` is `NOT NULL` — the reason-for-access is REQUIRED at the DB level,
      backstopping the `open/1` application check.

  ## Not a reveal grant

  An impersonation session is NOT a reveal grant — it carries the target org boundary
  and a member-equivalent role, but no reveal capability. Every open/close/expiry
  writes a token-only `aud_event` row (T4.1 clause (d)); this table itself never stores
  plaintext PII (operator id, org id, reason metadata, timestamps — all bounded).
  """
  use Ecto.Migration

  def up do
    create table(:imp_impersonation_session, primary_key: false) do
      add(:imp_id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()"))
      # The operator-plane actor who opened the session (bounded id — never PII).
      add(:imp_operator_id, :string, null: false)
      # The ONE target tenant org the session is scoped to.
      add(:imp_org_id, :uuid, null: false)
      # Reason-for-access — REQUIRED (doc §control). NOT NULL backstops open/1.
      add(:imp_reason, :text, null: false)
      # Bounded minutes-scale window: runtime denies once now() > expires_at,
      # checked per request, even if the auto-expire job never runs.
      add(:imp_expires_at, :utc_datetime_usec, null: false)
      # The auto-expire worker / manual close flips this. A closed session denies.
      add(:imp_closed_at, :utc_datetime_usec)
      # Close cause: "manual" | "expired" — a bounded token, never subject content.
      add(:imp_close_cause, :text)
      timestamps(type: :utc_datetime_usec, inserted_at: :imp_inserted_at, updated_at: :imp_updated_at)
    end

    create(index(:imp_impersonation_session, [:imp_org_id]))
    create(index(:imp_impersonation_session, [:imp_operator_id]))
    create(index(:imp_impersonation_session, [:imp_expires_at]))
  end

  def down do
    drop(table(:imp_impersonation_session))
  end
end
