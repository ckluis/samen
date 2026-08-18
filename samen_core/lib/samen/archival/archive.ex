defmodule Samen.Archival.Archive do
  @moduledoc """
  The Samen audit + idempotence glue on the `:archive` soft destroy (ADR-040 §5.2). The
  soft-destroy itself — setting `archived_at` — is ash_archival's `SetupArchival` change
  (ADR-037 §5.3); this change adds only what ash_archival does not:

    * **audit** — emits a `record_archived` governance event (via `after_action`, inside the
      archive transaction) on the live → archived transition;
    * **idempotence** (§5.2, T36 c4) — re-archiving an already-archived record PRESERVES the
      original `archived_at` instant (ash_archival would otherwise stamp a fresh `now`) and
      writes **no** second audit event. It runs after ash_archival's `set_attribute` in the
      change pipeline, so the preserved value wins.

  ## PII posture (INV-1)

  `archived_at` is a non-PII timestamp; the archived row keeps its vaulted tokens, org scope,
  and per-plane masking (§5.1). Audit `detail` is id/enum-only and PiiReasonScan-gated.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_data(changeset, :archived_at) do
      %DateTime{} = existing ->
        # Already archived → idempotent no-op: preserve the original instant (override
        # ash_archival's fresh stamp), write no audit. `%Ash.NotLoaded{}`/nil fall through
        # to the archiving branch (a create-returned record hasn't selected archived_at).
        Ash.Changeset.force_change_attribute(changeset, :archived_at, existing)

      _ ->
        # live → archiving: ash_archival sets the timestamp; we audit once it commits.
        Ash.Changeset.after_action(changeset, fn cs, record ->
          Samen.Archival.Audit.write(cs, record, "record_archived")
          {:ok, record}
        end)
    end
  end
end
