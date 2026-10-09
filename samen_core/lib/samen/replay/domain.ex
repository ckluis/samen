defmodule Samen.Replay.Domain do
  @moduledoc """
  The Ash domain hosting the replay storage resources (`Samen.Replay.Session`,
  `Samen.Replay.Frame`; ADR-052 §2.2 rule 4). Framework-owned kernel infrastructure — the
  `Samen.AI.Domain` precedent: a host that serves tenant LiveViews mounts it by adding
  `Samen.Replay.Domain` to its `:ash_domains` and pointing `:samen_replay_repo` at its repo
  (compile-time), plus the two-line `Samen.Replay.Migration` delegate.
  """
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(Samen.Replay.Session)
    resource(Samen.Replay.Frame)
  end
end
