defmodule Samen.Billing.Meter.ChokepointGuard do
  @moduledoc """
  The **no-ungoverned-usage-row** guard (T163; ADR-051 §2.1, R2): an
  `Ash.Resource.Change` on the `UsageEvent` ledger's `:record` action that REFUSES
  the create unless it came through `Samen.Billing.Meter.record/3`.

  Without it, the ledger's one create action would accept a direct `Ash.create`, a
  row with a hand-picked `idempotency_key` (or a random one), skipping the Meter's
  `source_ref` requirement and its derived key. That is the double-count the ledger
  exists to remove, re-opened by a caller who never heard of the Meter.

  Same mechanism as `Samen.Files.ChokepointGuard`: the Meter stamps
  `context.private` with a marker right before it creates. `context.private` is not
  reachable through action arguments or attributes, so an ordinary caller cannot
  forge it. The ledger has no update or destroy action, so create is the only write
  there is to guard.
  """
  use Ash.Resource.Change

  @marker_key :samen_billing_meter_chokepoint

  @doc false
  def marker_key, do: @marker_key

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &refuse_ungoverned_capture/1)
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  defp refuse_ungoverned_capture(changeset) do
    if get_in(changeset.context, [:private, @marker_key]) == true do
      changeset
    else
      Ash.Changeset.add_error(
        changeset,
        field: :idempotency_key,
        message:
          "ungoverned-usage-row (ADR-051 R2): a usage event can only be written through " <>
            "Samen.Billing.Meter.record/3, which derives the idempotency key from the " <>
            "caller's source_ref. A direct Ash.create is refused — the ledger is unchanged."
      )
    end
  end
end
