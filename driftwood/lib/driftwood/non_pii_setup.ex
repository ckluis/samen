defmodule Driftwood.NonPiiSetup do
  @moduledoc """
  Runtime registration of Driftwood's deliberate non-PII columns (design OR-2, §1.5).

  `drv_cdl_state` and `drv_cdl_expiry` are plain columns whose NAMES contain `cdl`,
  which is on `pii_classify`'s likely-PII token list — so the verifier FLAGS them and
  fails the build until they are cleared by a review-gated `non_pii!` with a DISTINCT
  second reviewer (fail-closed on self-review, the same distinct-party discipline as
  reveal grants). A US state code and a CDL EXPIRY DATE are not subject-identifying
  alone (the CDL NUMBER is the PII, and it lives vaulted in `pii_drv_cdl_number`).

  `drv_medical_card_expiry` does not hit the token list but is registered too, for a
  complete, auditor-legible non-PII inventory.

  Called from test setup and the seed task. Idempotent.
  """

  # Each entry: {table, column, redaction, reason}. `redaction` is the value written
  # over the plaintext on a driver-erasure request (design §5: plaintext-at-rest
  # non_pii columns are erased by row-level text redaction on a driver crypto-shred,
  # NOT key-shred. Both registered columns are TEXT-typed so the substrate's
  # text-redaction arm can overwrite the plaintext. `drv_medical_card_expiry` is a
  # :date column that pii_classify does NOT flag (its name has no PII token), so it
  # needs no clearance and is erased by row deletion with the driver.
  @columns [
    {"drv_driver", "drv_cdl_state", "[REDACTED_NON_PII]",
     "The CDL ISSUING STATE (a 2-letter US state code, e.g. 'TX'). Not subject-identifying " <>
       "alone — thousands of drivers share a state. The CDL NUMBER is the PII and is vaulted " <>
       "in pii_drv_cdl_number. Cleared under D9 mask-unknown-by-default with distinct-reviewer " <>
       "sign-off; the FMCSA dispatch gate reads it as a non-PII input (design §1.5/OR-2)."},
    {"drv_driver", "drv_cdl_expiry", "1970-01-01",
     "The CDL EXPIRY DATE, stored as ISO-8601 TEXT. A validity date, not a subject identifier — " <>
       "the dispatch gate needs CDL validity without CDL plaintext, which is why cdl_expiry is a " <>
       "separate non-PII column from the vaulted cdl_number (design §1.5/§4/OR-2). Distinct-reviewer " <>
       "cleared; on driver crypto-shred it is overwritten with the epoch sentinel 1970-01-01."}
  ]

  @doc "Register Driftwood's non-PII columns. Idempotent; returns :ok or {:error, reason}."
  def register_all do
    Enum.reduce_while(@columns, :ok, fn {table, column, redaction, reason}, _acc ->
      case Samen.NonPii.register(%{
             table_name: table,
             column_name: column,
             cleared_by: "T5.2-driftwood-scope-author",
             reviewed_by: "T5.2-gate-reviewer",
             reason: reason,
             subject_column: "drv_id",
             redaction: redaction
           }) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end
