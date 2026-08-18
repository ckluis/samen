defmodule Samen.Scopes.SalesOps.AlreadyConverted do
  @moduledoc """
  Idempotence guard for `Lead.convert` (F7): refuses a SECOND conversion once
  `status == :converted`. Checked against `changeset.data` — the row's CURRENTLY
  PERSISTED state, never the in-flight change the `:convert` action's own
  `set_attribute(:status, :converted)` queues — so the very update that performs
  the FIRST conversion is never mistaken for a re-conversion attempt (an
  anti-tautology: this validation must pass on conversion #1 and fail on #2).

  Runs BEFORE `Samen.Scopes.SalesOps.ConvertLead`'s cross-resource work (Ash
  validations run before changes in the action pipeline), so a double-convert
  never creates a second orphan Person/Opportunity pair — the whole action is
  refused at the changeset boundary, DB untouched.
  """
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    if changeset.data.status == :converted do
      {:error, field: :status, message: "lead is already converted"}
    else
      :ok
    end
  end
end
