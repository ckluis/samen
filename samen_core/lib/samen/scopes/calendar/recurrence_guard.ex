defmodule Samen.Scopes.Calendar.RecurrenceGuard do
  @moduledoc """
  Write-time validation for `Event.recurrence` (F2) — fail-honest at the
  changeset boundary rather than deferring the error to the first ICS export
  or recurrence expansion that touches the row. Delegates entirely to
  `Samen.Scopes.Calendar.Recurrence.cast_rule/1` (the single source of truth
  for what a legal rule shape is) — nothing is re-derived here.
  """
  use Ash.Resource.Validation

  alias Samen.Scopes.Calendar.Recurrence

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.fetch_argument_or_change(changeset, :recurrence) do
      {:ok, value} -> check(value)
      :error -> :ok
    end
  end

  defp check(nil), do: :ok

  defp check(value) do
    case Recurrence.cast_rule(value) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, field: :recurrence, message: "invalid recurrence rule: #{inspect(reason)}"}
    end
  end
end
