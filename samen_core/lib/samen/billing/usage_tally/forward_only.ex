defmodule Samen.Billing.UsageTally.ForwardOnly do
  @moduledoc """
  `:mark_reported` may only move `reported_quantity` FORWARD, and never past the
  tally's `quantity` (ADR-051 P2). Backwards would re-report usage the provider
  already has (a double bill under increment semantics); past `quantity` would
  claim usage was reported that was never captured.
  """
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    before = changeset.data.reported_quantity || 0
    quantity = changeset.data.quantity || 0
    reported = Ash.Changeset.get_attribute(changeset, :reported_quantity)

    cond do
      not is_integer(reported) ->
        {:error, field: :reported_quantity, message: "must be an integer"}

      reported < before ->
        {:error,
         field: :reported_quantity,
         message: "may only move forward (was #{before}, got #{reported}) — ADR-051 P2"}

      reported > quantity ->
        {:error,
         field: :reported_quantity,
         message: "may not exceed the tally's quantity (#{quantity}, got #{reported})"}

      true ->
        :ok
    end
  end
end
