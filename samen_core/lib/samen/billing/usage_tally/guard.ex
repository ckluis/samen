defmodule Samen.Billing.UsageTally.Guard do
  @moduledoc """
  Refuses a `Usage` `:rebuild_tally` create that did not come through
  `Samen.Billing.UsageTally.rebuild/5` (ADR-051 §2.4: a tally is derived, never
  written). Same `context.private` marker mechanism as
  `Samen.Billing.Meter.ChokepointGuard` and `Samen.Files.ChokepointGuard`.
  """
  use Ash.Resource.Change

  @marker_key :samen_billing_usage_tally

  @doc false
  def marker_key, do: @marker_key

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      if get_in(changeset.context, [:private, @marker_key]) == true do
        changeset
      else
        Ash.Changeset.add_error(changeset,
          field: :quantity,
          message:
            "underived-usage-tally (ADR-051 §2.4): a Usage tally is recomputed from the " <>
              "UsageEvent ledger by Samen.Billing.UsageTally.rebuild/5 and is never written " <>
              "directly. Capture usage with Samen.Billing.Meter.record/3 instead."
        )
      end
    end)
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok
end
