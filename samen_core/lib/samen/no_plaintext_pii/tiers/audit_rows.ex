defmodule Samen.NoPlaintextPii.Tiers.AuditRows do
  @moduledoc """
  CI-mode tier (b): **the projected audit-row surfaces expose only
  pii_-token / bounded-ID / enum / timestamp columns — never a plaintext PII
  column** (T1.8d clause (b); doc §runs oracle "aud_event … the token-only
  invariant").

  The projected surfaces that exist so far are the reveal-grant / erasure
  lifecycle rows T1.6/T1.7 write:

    * `rvl_reveal_audit`   — the append-only reveal-grant lifecycle log (G4).
    * `rvg_reveal_grant`   — the grant rows.
    * `rvq_reveal_request` — the reveal requests.
    * `era_erasure_report` — the erasure report artifact the oracle consumes.

  Every column on these tables must be a **bounded ID** (uuid / bounded string
  id), a **token**, an **enum** (a bounded status/event string), a **number**, a
  **timestamp**, or a **JSON tier-descriptor** (the `era_tiers` map, which itself
  carries only counts + token references). A column whose *name* or *value shape*
  looks like plaintext PII (an `ssn`, an `email`, a free-text `reason`/`detail`
  carrying subject content) is the leak this tier catches.

  ## How the scan decides

  Because these are plain Ecto tables (not Ash resources with a type registry),
  the tier scans the PHYSICAL columns via `information_schema` and applies TWO
  gates, both fail-safe:

    1. **Name gate** — a column whose name hits the `Samen.PiiClassify` PII
       identifier heuristic (`ssn`, `dob`, `email`, `phone`, `full_name`, …) on a
       plaintext (text/varchar/date) physical type is a violation. This is the
       seeded-plaintext-PII red path: `ALTER TABLE rvl_reveal_audit ADD ssn text`
       fails here.

    2. **Allow-list gate** — every column NOT on the audited-surface allow-list
       for its table (the known bounded-ID/token/enum/timestamp columns the
       T1.6/T1.7 schemas declare) is a violation on a plaintext physical type,
       UNLESS it is a registered `non_pii!` exemption (then it is listed, not
       failed). This is the fail-CLOSED half: a NEW unrecognised text column on an
       audit projection is a leak until it is either removed, tokenised, or
       reviewed as `non_pii!`. Absence of a name-hit is not evidence of safety.

  Both gates skip non-plaintext physical types (uuid, int, bool, timestamp, jsonb)
  — those cannot carry raw subject PII by shape.
  """

  @behaviour Samen.NoPlaintextPii.Tier

  alias Samen.NoPlaintextPii.{Context, Finding}
  alias Samen.PiiClassify

  @tier :audit_rows

  # The projected audit-row / lifecycle surfaces that exist so far (T1.6/T1.7).
  # Phase 2 adds aud_event / trace-sink tiers as their own tier modules.
  @audited_tables ~w(rvl_reveal_audit rvg_reveal_grant rvq_reveal_request era_erasure_report)

  # Per-table allow-list of columns that are known bounded IDs / tokens / enums /
  # numbers / timestamps / JSON tier descriptors. Anything on a table but NOT on
  # its allow-list is treated as a potential leak on a plaintext physical type.
  #
  # NOTE on `reason`/`detail`: these are OPERATOR-authored free text (why a reveal
  # was requested, a lifecycle detail line) — they carry the ACTOR's reason string,
  # not the SUBJECT's vaulted PII (the subject is referenced only by id/token). The
  # doc's masked-payload allow-list treats an operator reason as a bounded audit
  # field, so they are allow-listed. If a host app misuses `reason` to carry
  # subject content, the C3 pii_reads verifier (a vault value flowing into the
  # audit write) is the complementary catch.
  @allow_list %{
    "rvl_reveal_audit" =>
      ~w(rvl_id rvl_event rvl_subject_id rvl_actor_id rvl_request_id rvl_grant_id rvl_detail rvl_recorded_at),
    "rvg_reveal_grant" =>
      ~w(rvg_id rvg_request_id rvg_subject_id rvg_requestor_id rvg_granted_by rvg_reason
         rvg_resource rvg_action rvg_expires_at rvg_revoked_at rvg_inserted_at rvg_updated_at),
    "rvq_reveal_request" =>
      ~w(rvq_id rvq_subject_id rvq_requestor_id rvq_reason rvq_resource rvq_action
         rvq_status rvq_inserted_at rvq_updated_at),
    "era_erasure_report" =>
      ~w(era_id era_subject_id era_attestation_id era_outcome era_tiers
         era_vault_rows_sealed era_non_pii_rows_redacted era_recorded_at)
  }

  # Physical types that CAN carry raw plaintext PII by shape.
  @plaintext_udts ~w(varchar text bpchar date)

  @impl true
  def tier_name, do: @tier

  @impl true
  def mode, do: :ci

  @impl true
  def describe,
    do: "audit-row projections (reveal/erasure lifecycle) carry only bounded-ID/token/enum columns"

  @impl true
  def check(%Context{repo: nil}) do
    [
      Finding.violation(
        @tier,
        "<repo>",
        "no repo configured — cannot scan the audit-row projections (fail closed). " <>
          "Configure :verify_repo / :non_pii_repo / :reveal_grant_repo."
      )
    ]
  end

  def check(%Context{} = context) do
    Enum.flat_map(@audited_tables, fn table ->
      check_table(table, context)
    end)
  end

  # ---------------------------------------------------------------------------

  defp check_table(table, context) do
    case columns(context.repo, table) do
      {:ok, []} ->
        # Table absent from the schema (a projection that doesn't exist yet in
        # this app). Nothing to scan — not a violation (the tier only asserts over
        # surfaces that EXIST, per T1.8d).
        []

      {:ok, cols} ->
        allow = Map.get(@allow_list, table, [])
        Enum.flat_map(cols, fn {name, udt} -> check_column(table, name, udt, allow, context) end)

      {:error, reason} ->
        [
          Finding.violation(
            @tier,
            table,
            "could not introspect the audit-row projection (#{inspect(reason)}) — fail closed."
          )
        ]
    end
  end

  defp check_column(table, name, udt, allow, context) do
    subject = "#{table}.#{name}"
    plaintext_type? = udt in @plaintext_udts

    cond do
      # Non-plaintext physical type (uuid/int/bool/timestamp/jsonb): cannot carry
      # raw subject PII by shape — safe.
      not plaintext_type? ->
        []

      # A registered non_pii! exemption: plaintext-at-rest by design. List it,
      # do NOT fail (clause (d)).
      Context.non_pii_exempt?(context, table, name) ->
        [
          Finding.exempt(
            @tier,
            subject,
            "registered non_pii! (plaintext-at-rest by design; erased by row-level redaction)"
          )
        ]

      # Name gate: a plaintext column whose NAME hits the PII heuristic is a leak.
      PiiClassify.pii_name?(strip_prefix(name)) ->
        [
          Finding.violation(
            @tier,
            subject,
            "plaintext (#{udt}) column on an audit-row projection whose name matches a PII " <>
              "identifier pattern. Audit rows must reference the subject by id/token only, " <>
              "never carry plaintext PII. Remove it, tokenise it, or (if genuinely non-PII) " <>
              "register a review-gated non_pii! override."
          )
        ]

      # Allow-list gate (fail closed): a plaintext column NOT on the known
      # bounded-ID/token/enum allow-list is a potential leak.
      name not in allow ->
        [
          Finding.violation(
            @tier,
            subject,
            "unrecognised plaintext (#{udt}) column on an audit-row projection (not on the " <>
              "bounded-ID/token/enum allow-list). A new text column on an audit surface is a " <>
              "leak until it is removed, tokenised, or registered as a review-gated non_pii! " <>
              "override (fail closed)."
          )
        ]

      # On the allow-list, plaintext type, no PII name-hit: a known bounded field.
      true ->
        []
    end
  end

  # Strip the 3-letter abbrev prefix for the name heuristic so `rvl_ssn` matches
  # `ssn`. Falls back to the full name if it doesn't look prefixed.
  defp strip_prefix(name) do
    case String.split(name, "_", parts: 2) do
      [abbrev, rest] when byte_size(abbrev) == 3 -> rest
      _ -> name
    end
  end

  defp columns(nil, _table), do: {:error, :no_repo}

  defp columns(repo, table) do
    %{rows: rows} =
      repo.query!(
        "SELECT column_name, udt_name FROM information_schema.columns " <>
          "WHERE table_schema = 'public' AND table_name = $1 " <>
          "ORDER BY column_name",
        [table]
      )

    {:ok, Enum.map(rows, fn [c, u] -> {c, u} end)}
  rescue
    e -> {:error, e}
  end
end
