defmodule Samen.Replay.Frame do
  @moduledoc """
  One captured frame of a `Samen.Replay.Session` (ADR-052 §2.2). `payload` is JSONB — the
  ENCODED, schema-validated output of `Samen.Replay.Sanitizer` (`Samen.Replay.FrameSchema`): a
  tree with no bare string in it, scannable by the `no_plaintext_pii` DB tiers and the
  destruction oracle like any other column.
  """
  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Replay.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "rpf"

  postgres do
    table("replay_frame")
    repo(Application.compile_env(:samen_core, :samen_replay_repo, SamenCore.TestRepo))
  end

  attributes do
    attribute(:session_id, :uuid, public?: true, allow_nil?: false)
    attribute(:seq, :integer, public?: true, allow_nil?: false)

    attribute(:kind, :atom,
      public?: true,
      allow_nil?: false,
      constraints: [
        one_of: [:mount, :params, :event, :component_event, :render, :info, :exit, :truncated]
      ]
    )

    # Milliseconds since the session opened.
    attribute(:at_ms, :integer, public?: true, allow_nil?: false)
    attribute(:payload, :map, public?: true, allow_nil?: false, default: %{})
  end

  # The player reads a stored row through these, never through the typed `kind` / `payload`
  # attributes: a row written past `RowGuard` (raw SQL) with a kind outside the closed set or a
  # payload that is not an object would fail the typed cast and take the WHOLE session read
  # with it. As text, every row loads; `Samen.Replay.Decoder` then degrades a bad one to a
  # single `:invalid` frame (ADR-052 §2.4.1).
  calculations do
    calculate(:stored_kind, :string, expr(fragment("(?)::text", kind)))
    calculate(:stored_payload, :string, expr(fragment("(?)::text", payload)))
  end

  identities do
    identity(:session_seq, [:session_id, :seq])
  end

  actions do
    defaults([:read, :destroy])

    create :record do
      description("Persist one frame (kernel-only: Samen.Replay.Store).")
      accept([:org_id, :session_id, :seq, :kind, :at_ms, :payload])

      # The last line (ADR-052 §2.2.1 gate fix): every write, whoever makes it and whether or
      # not it is authorized, passes the replay row guard.
      validate({Samen.Replay.RowGuard, row: :frame})
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if(Samen.Policy.OrgScope)
    end

    policy action_type([:create, :destroy]) do
      forbid_if(always())
    end
  end
end
