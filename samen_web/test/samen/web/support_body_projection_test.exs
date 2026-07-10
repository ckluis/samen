defmodule Samen.Web.SupportBodyProjectionTest do
  @moduledoc """
  A3 WIRING (billing-support batch) — ticket bodies are FREEFORM text: verify they
  stay OUT of the CDC/aggregate projection under the A1 default-deny classifier
  (ADR-015) on the SAME mounted Support resources the write surfaces above target:

    * `Message.body` is VAULT-ROUTED (`pii_attribute :body, vault: :pii_body`) — its
      physical column mirrors as `:token` ONLY; no plaintext body column exists in
      the projection, and `assert_no_plaintext!` accepts it (a token is safe by
      construction).
    * `Ticket.subject` (the freeform, NON-vaulted ticket text) is DEFAULT-DENIED:
      with no vault route and no two-reviewer `non_pii!` clearance it classifies
      `:plaintext_pii`, is PROVABLY ABSENT from `Projection.project/1`, and an
      explicit mirror demand RAISES (fail-closed, AC-G3-1/2 on this host).
    * ANTI-TAUTOLOGY: a synthetic two-reviewer clearance flips the SAME subject
      column INTO the projection — proving the absence assertions discriminate on
      the clearance, not on a vacuous refusal (AC-G3-3 direction).

  Per-plane masking of the SAME body (tenant clear / operator ••••) is asserted in
  `support_render_test.exs` + `support_ticket_reply_test.exs` — this file proves the
  aggregate-plane half of the guarantee.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Cdc.Projection
  alias Samen.Cdc.Projection.PlaintextInProjectionError

  @message Samen.WebTest.Support.Message
  @ticket Samen.WebTest.Support.Ticket

  # Column names are derived from the resource, never hardcoded — the blueprint owns
  # the abbrev prefixes.
  defp source(resource, attr), do: resource |> Ash.Resource.Info.attribute(attr) |> Map.fetch!(:source) |> to_string()

  defp classified(resource, opts), do: resource |> Projection.classify_columns(opts) |> Map.new()

  defp projected_cols(resource, opts), do: resource |> Projection.project(opts) |> Enum.map(&elem(&1, 0))

  # A synthetic two-reviewer non_pii! entry (the classifier's :non_pii_entries test
  # seam — same shape as the kernel's cdc_default_deny_projection_test).
  defp cleared_entry(table, column) do
    %Samen.NonPii.Entry{
      table_name: table,
      column_name: column,
      cleared_by: "alice@example.com",
      reviewed_by: "bob@example.com",
      reason: "reviewed as non-PII operational text — two-reviewer sign-off",
      subject_column: "id"
    }
  end

  defp ticket_table, do: AshPostgres.DataLayer.Info.table(@ticket)

  test "Message.body mirrors as :token ONLY — the freeform ticket body never reaches the projection as plaintext" do
    body_col = source(@message, :body)
    cols = classified(@message, non_pii_entries: [])

    # The vault-routed storage column is a token, never plaintext.
    assert cols[body_col] == :token

    projected = @message |> Projection.project(non_pii_entries: []) |> Map.new()
    assert projected[body_col] == :token

    # An explicit mirror demand for the body column is ACCEPTED (token-blind rows
    # are the mirror contract) — and no column of the projection is plaintext PII.
    assert :ok == Projection.assert_no_plaintext!(@message, [body_col], non_pii_entries: [])
    refute :plaintext_pii in Map.values(projected)
  end

  test "Ticket.subject (freeform, un-vaulted) is DEFAULT-DENIED: :plaintext_pii, PROVABLY ABSENT, and a demand RAISES" do
    subject_col = source(@ticket, :subject)
    cols = classified(@ticket, non_pii_entries: [])

    assert cols[subject_col] == :plaintext_pii
    refute subject_col in projected_cols(@ticket, non_pii_entries: [])

    # RED PATH (fail-closed): explicitly demanding the subject column RAISES.
    assert_raise PlaintextInProjectionError, ~r/plaintext PII column/, fn ->
      Projection.assert_no_plaintext!(@ticket, [subject_col], non_pii_entries: [])
    end

    # The structural-safe columns are NOT over-refused (the AC-G3-5 guard): the
    # enum/timestamp/id columns still mirror.
    projected = projected_cols(@ticket, non_pii_entries: [])
    assert source(@ticket, :status) in projected
    assert source(@ticket, :priority) in projected
    assert source(@ticket, :org_id) in projected
  end

  test "ANTI-TAUTOLOGY: a two-reviewer non_pii! clearance flips the SAME subject column INTO the projection" do
    subject_col = source(@ticket, :subject)
    entries = [cleared_entry(ticket_table(), subject_col)]

    # With the clearance the column classifies safe and IS projected — proving the
    # previous test's refusal/absence discriminates on the clearance (non-vacuous).
    assert classified(@ticket, non_pii_entries: entries)[subject_col] != :plaintext_pii
    assert subject_col in projected_cols(@ticket, non_pii_entries: entries)
    assert :ok == Projection.assert_no_plaintext!(@ticket, [subject_col], non_pii_entries: entries)
  end
end
