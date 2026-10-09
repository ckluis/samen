defmodule Samen.Replay.Session do
  @moduledoc """
  One captured tenant LiveView session (ADR-052 §2.2). Token-only: the org id, the actor as
  the P1 HMAC pseudonym (`actor_ref`, unlinkable once the subject's key is shredded — never a
  principal id or a name), the view MODULE name and its MD5 (P3's code-drift marker), timing,
  a bounded exit enum and counters. The captured content lives in `Samen.Replay.Frame` rows.

  Kernel-only writes (`Samen.Replay.Store`); tenant reads are org-scoped through
  `Samen.Policy.OrgScope`. TTL: `Samen.Replay.retention_specs/1` (default 14 days, max 90).
  """
  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Replay.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "rps"

  postgres do
    table("replay_session")
    repo(Application.compile_env(:samen_core, :samen_replay_repo, SamenCore.TestRepo))
  end

  attributes do
    # `HMAC(psk_S, subject_id)` (`Samen.WideEvent.for_subject/2`) — a pseudonym, never the id.
    attribute(:actor_ref, :string, public?: true)
    # The LiveView module name — a code identifier.
    attribute(:view, :string, public?: true, allow_nil?: false)
    # Hex MD5 of the view module at capture time.
    attribute(:view_md5, :string, public?: true)
    attribute(:started_at, :utc_datetime_usec, public?: true, allow_nil?: false)
    attribute(:ended_at, :utc_datetime_usec, public?: true)

    attribute(:exit_reason, :atom,
      public?: true,
      constraints: [one_of: [:normal, :shutdown, :killed, :crash]]
    )

    attribute(:frame_count, :integer, public?: true, allow_nil?: false, default: 0)
    attribute(:byte_count, :integer, public?: true, allow_nil?: false, default: 0)
    attribute(:interaction_count, :integer, public?: true, allow_nil?: false, default: 0)
    # Frames the persist-time schema validator refused (never stored).
    attribute(:rejected_count, :integer, public?: true, allow_nil?: false, default: 0)
    attribute(:truncated, :boolean, public?: true, allow_nil?: false, default: false)
  end

  actions do
    defaults([:read, :destroy])

    create :record do
      description("Persist a finished capture session (kernel-only: Samen.Replay.Store).")

      accept([
        :org_id,
        :actor_ref,
        :view,
        :view_md5,
        :started_at,
        :ended_at,
        :exit_reason,
        :frame_count,
        :byte_count,
        :interaction_count,
        :rejected_count,
        :truncated
      ])

      # The last line (ADR-052 §2.2.1 gate fix): every write, whoever makes it and whether or
      # not it is authorized, passes the replay row guard.
      validate({Samen.Replay.RowGuard, row: :session})
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if(Samen.Policy.OrgScope)
    end

    # Kernel-only writes: the monitor's finalizer persists, the retention sweep deletes —
    # both run with `authorize?: false` under no tenant actor.
    policy action_type([:create, :destroy]) do
      forbid_if(always())
    end
  end
end
