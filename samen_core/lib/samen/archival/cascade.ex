defmodule Samen.Archival.Cascade do
  @moduledoc """
  The two writes every composition-cascade listener makes (ADR-040 §5.4; issue #96 D3 —
  the listeners of `Samen.Archival.Signals`).

    * `archive_at!/2` archives one member through its OWN `:archive` action, so the
      `record_archived` audit event and the idempotence guard (`Samen.Archival.Archive`) still
      run, at EXACTLY the parent's instant: a restore matches children by `archived_at`
      equality, so the instant is threaded explicitly, never re-read from the clock.
    * `restore_each/1` restores members through `Samen.Archival.restore/2`, halting on the
      first error (a `:restore_conflict`), which the listener returns so the parent's whole
      restore rolls back — never a partial cascade.

  Both run `authorize?: false`: a cascade is a structural consequence of the parent's write,
  which was itself authorized. Only a listener may reach them — its action is gated by a
  `signal_in/2` bypass.
  """

  @doc "Archives `member` through its `:archive` action at `instant`. Raises on failure."
  def archive_at!(member, %DateTime{} = instant) do
    member
    |> Ash.Changeset.for_destroy(:archive, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:archived_at, instant)
    |> Ash.destroy!(authorize?: false)
  end

  @doc "Restores each member in order: `:ok`, or the first `{:error, reason}`."
  def restore_each(members) do
    Enum.reduce_while(members, :ok, fn member, :ok ->
      case Samen.Archival.restore(member, authorize?: false) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end
