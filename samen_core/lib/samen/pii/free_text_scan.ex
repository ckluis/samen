defmodule Samen.Pii.FreeTextScan do
  @moduledoc """
  The **tenant free-text write chokepoint** (F3 Unit 6 carry) — a parameterized
  `Ash.Resource.Change` that refuses a create/update setting a named TENANT free-text
  column to a value that is *itself* a bare email/SSN/phone shape.

  ## The residue this narrows

  A tenant-authored `:string`/`:text` column that is NOT vault-routed (a benignly named
  `notes` / comment / freeform field) sits OUTSIDE the vault's crypto-shred guarantee
  (`docs/free-text-pii-residue.md`, ADR-015 §5): nothing stops a tenant from typing a
  third party's email/SSN/phone into it, and a subject erasure can never reach it. The
  same `Samen.PiiReasonScan` / `Samen.PiiValueShape` machinery that guards
  OPERATOR-authored reasons is extended HERE to the tenant free-text write boundary as a
  fail-closed belt atop ADR-015's compile-time default-deny.

  ## Where it is enforced — the WRITE PATH

  A `before_action` on the framework create/update, attached by a blueprint with the
  columns to guard:

      change({Samen.Pii.FreeTextScan, fields: [:notes]})

  Enforcing it on the Ash write path (not a LiveView) means the guard holds for ANY
  caller — a hand-crafted POST, an API path, a generator-scaffolded form. It runs before
  any row lands, so a rejected write leaves the DB unchanged (fail-closed).

  ## The rule (same blind spot as PiiReasonScan, by design)

  For each configured field that the changeset SETS to a binary, run
  `Samen.PiiReasonScan.check/2`. A value that is a bare email/SSN/phone is REFUSED
  (`Ash.Changeset.add_error/2` → the action returns `{:error, ...}`, DB unchanged). The
  space-separated-name shape is deliberately NOT gated (ordinary prose has spaces and
  would false-positive constantly) — names remain a human-convention residue, documented
  in `docs/free-text-pii-residue.md`. This is a heuristic, not a taint proof: it catches
  the obvious mistake of pasting a bare PII value, nothing more.

  A field left untouched, or set to nil/blank, is not a write and passes.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    fields = Keyword.get(opts, :fields, [])

    Ash.Changeset.before_action(changeset, fn cs ->
      Enum.reduce(fields, cs, fn field, acc ->
        scan_field(acc, field)
      end)
    end)
  end

  defp scan_field(changeset, field) do
    case Ash.Changeset.fetch_change(changeset, field) do
      {:ok, value} when is_binary(value) ->
        case Samen.PiiReasonScan.check(value, "tenant free-text (#{field})") do
          :ok ->
            changeset

          {:error, {:pii_shaped_reason, shape}} ->
            Ash.Changeset.add_error(changeset,
              field: field,
              message:
                "pii-shaped free-text (F3 Unit 6): the #{field} value is a bare " <>
                  "#{shape} — a tenant free-text column is OUTSIDE the vault's " <>
                  "crypto-shred guarantee, so a bare PII value is refused at the " <>
                  "write path (the DB is unchanged). See docs/free-text-pii-residue.md."
            )
        end

      _ ->
        changeset
    end
  end
end
