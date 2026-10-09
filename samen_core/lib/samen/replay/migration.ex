defmodule Samen.Replay.Migration do
  @moduledoc """
  The shared DDL + catalog rows for the replay storage tables (`replay_session`,
  `replay_frame`; ADR-052 §2.2 rule 4). Encoded once here (the
  `Samen.Delivery.DeliverabilityMigration` precedent) so every host's migration is a two-line
  delegate and the copies can never drift:

      defmodule MyApp.Repo.Migrations.SamenReplay do
        use Samen.Migration

        def up, do: Samen.Replay.Migration.up(__MODULE__)
        def down, do: Samen.Replay.Migration.down()
      end

  The resources are framework-owned Ash resources (`Samen.Replay.Session` / `Frame`,
  allocator-owned abbrevs `rps` / `rpf` under host `samen_core`), so the catalog rows are
  written by `Samen.Migration`'s `catalog_sync` in the SAME transaction as the DDL. Frames
  cascade with their session (`ON DELETE CASCADE`), so a session the retention sweep deletes
  takes its frames with it.
  """

  import Ecto.Migration

  @resources [Samen.Replay.Session, Samen.Replay.Frame]

  @doc "Create both tables, their indexes and catalog rows. `caller` is the migration module."
  @spec up(module()) :: :ok
  def up(caller) do
    create table(:replay_session, primary_key: false) do
      add(:rps_actor_ref, :text)
      add(:rps_view, :text, null: false)
      add(:rps_view_md5, :text)
      add(:rps_started_at, :utc_datetime_usec, null: false)
      add(:rps_ended_at, :utc_datetime_usec)
      add(:rps_exit_reason, :text)
      add(:rps_frame_count, :bigint, null: false, default: 0)
      add(:rps_byte_count, :bigint, null: false, default: 0)
      add(:rps_interaction_count, :bigint, null: false, default: 0)
      add(:rps_rejected_count, :bigint, null: false, default: 0)
      add(:rps_truncated, :boolean, null: false, default: false)
      add(:rps_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:rps_org_id, :uuid, null: false)
      add(:rps_inserted_at, :utc_datetime, null: false)
      add(:rps_updated_at, :utc_datetime, null: false)
    end

    create(index(:replay_session, [:rps_org_id], name: "replay_session_org_idx"))
    create(index(:replay_session, [:rps_inserted_at], name: "replay_session_inserted_idx"))

    create table(:replay_frame, primary_key: false) do
      add(
        :rpf_session_id,
        references(:replay_session, column: :rps_id, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:rpf_seq, :bigint, null: false)
      add(:rpf_kind, :text, null: false)
      add(:rpf_at_ms, :bigint, null: false)
      add(:rpf_payload, :map, null: false, default: %{})
      add(:rpf_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:rpf_org_id, :uuid, null: false)
      add(:rpf_inserted_at, :utc_datetime, null: false)
      add(:rpf_updated_at, :utc_datetime, null: false)
    end

    create(
      unique_index(:replay_frame, [:rpf_session_id, :rpf_seq],
        name: "replay_frame_session_seq_index"
      )
    )

    create(index(:replay_frame, [:rpf_org_id], name: "replay_frame_org_idx"))
    create(index(:replay_frame, [:rpf_inserted_at], name: "replay_frame_inserted_idx"))

    Samen.Migration.__catalog_sync__(caller, @resources, [])
    :ok
  end

  @doc "Drop both tables and their catalog rows."
  @spec down() :: :ok
  def down do
    Samen.Migration.__catalog_sync_down__(@resources, [])
    drop(table(:replay_frame))
    drop(table(:replay_session))
    :ok
  end
end
