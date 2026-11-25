defmodule Samen.Scopes.Calendar.EndsAfterStarts do
  @moduledoc """
  Write-time validation for `Event`: `ends_at` may not precede `starts_at` (equal instants and no end at
  all are allowed). Runs on create and update.

  An update that changes only one of the two is compared against the STORED other (the record in hand).
  When that stored value is not loaded the check cannot run, and the write is refused rather than passed:
  an unreadable comparison is an error, never a pass. An update that touches neither instant is not
  re-checked (a row stored out of order can still have its title edited).
  """
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    if Ash.Changeset.changing_attribute?(changeset, :starts_at) or
         Ash.Changeset.changing_attribute?(changeset, :ends_at) do
      compare(
        Ash.Changeset.get_attribute(changeset, :starts_at),
        Ash.Changeset.get_attribute(changeset, :ends_at)
      )
    else
      :ok
    end
  end

  defp compare(%Ash.NotLoaded{}, _), do: unreadable()
  defp compare(_, %Ash.NotLoaded{}), do: unreadable()
  defp compare(_starts, nil), do: :ok
  defp compare(nil, _ends), do: :ok

  defp compare(starts, ends) do
    if DateTime.compare(ends, starts) == :lt,
      do: {:error, field: :ends_at, message: "must not be before starts_at"},
      else: :ok
  end

  defp unreadable, do: {:error, field: :ends_at, message: "cannot be checked against starts_at: the stored value is not loaded"}
end
