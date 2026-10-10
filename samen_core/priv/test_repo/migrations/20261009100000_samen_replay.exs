defmodule SamenCore.TestRepo.Migrations.SamenReplay do
  @moduledoc """
  ADR-052 P2 — the replay capture tables (`replay_session`, `replay_frame`). The DDL and the
  catalog rows live once in `Samen.Replay.Migration`; every host delegates to it.
  """
  use Samen.Migration

  def up, do: Samen.Replay.Migration.up(__MODULE__)
  def down, do: Samen.Replay.Migration.down()
end
