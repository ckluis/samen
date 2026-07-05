defmodule Samen.NoPlaintextPii.Tiers.AudEvent do
  @moduledoc """
  CI-mode tier: **the `aud_event` append-only event/audit table carries only
  bounded-ID / token / enum / timestamp columns — never a plaintext PII column**
  (T2.2 (d); doc §runs oracle "aud_event … the token-only invariant").

  `aud_event` is the Samen event/audit tier added in Phase 2.  Like the T1.6/T1.7
  surfaces scanned by `AuditRows`, it must hold only opaque ids, vault-FK tokens,
  bounded enum strings, timestamps, and operator-authored metadata.  A plaintext PII
  column on `aud_event` would defeat the token-only-downstream invariant.

  ## Scope

  This tier scans the PARENT partitioned table (`aud_event`).  Child partitions
  (e.g. `aud_event_y2026m07`) inherit the parent's column layout and are NOT scanned
  separately — `information_schema.columns` returns the parent's columns for the
  parent table name, which is the correct set.  If a child partition somehow
  diverged in schema it would not be caught here; that is acceptable because
  `ALTER TABLE` on a partition would also affect the parent, and partition column
  divergence is not possible in standard Postgres.

  ## What the scan asserts

  1. **Name gate** — a column whose name (after stripping the `aud_` prefix)
     matches the `Samen.PiiClassify` PII-identifier heuristic (`ssn`, `dob`,
     `email`, `phone`, …) on a plaintext physical type is a violation.

  2. **Allow-list gate (fail closed)** — every column NOT on the known
     bounded-ID/token/enum allow-list for `aud_event` is a violation on a
     plaintext physical type, UNLESS registered as a `non_pii!` exemption.
     A new unrecognised text column is a leak until it is removed, tokenised,
     or registered as a review-gated `non_pii!` override.

  ## Allow-list

  The allow-listed columns are exactly the ones the `Samen.AuditEvent` schema
  declares — all are opaque IDs, bounded enums, or timestamps:

    * `aud_id`             — UUID (opaque row id)
    * `aud_event_type`     — bounded enum ("grant_lifecycle" | "erasure" | …)
    * `aud_subject_id`     — opaque subject UUID / token (NOT the subject's name)
    * `aud_actor_id`       — opaque operator actor id
    * `aud_correlation_id` — UUID correlation ref (request_id / grant_id / job_id)
    * `aud_detail`         — operator-authored lifecycle metadata; carries actor-
                             authored reason strings and system outcome tokens
                             ("granted", "denied", "shredded"), NOT subject PII.
                             Allow-listed as bounded audit field (same treatment as
                             `rvl_detail` / `rvg_reason` in `AuditRows`).
    * `aud_occurred_at`    — partition key timestamp

  ## If `aud_event` table is absent

  If the `aud_event` table does not exist in this app's schema (a host that
  has not yet run the T2.2 migration), this tier returns NO finding — it only
  asserts over surfaces that EXIST, per T1.8d.  An absent table is not a
  violation; it is simply not yet deployed.  This is distinct from the
  `:audit_rows` tier behaviour, where all four tables are expected to exist.
  """

  @behaviour Samen.NoPlaintextPii.Tier

  alias Samen.NoPlaintextPii.{Context, Finding}
  alias Samen.PiiClassify

  @tier :aud_event
  @table "aud_event"

  # Allow-listed columns on aud_event — all bounded IDs / enums / timestamps.
  @allow_list ~w(
    aud_id
    aud_event_type
    aud_subject_id
    aud_actor_id
    aud_correlation_id
    aud_detail
    aud_occurred_at
  )

  # Physical types that CAN carry raw plaintext PII by shape.
  @plaintext_udts ~w(varchar text bpchar date)

  @impl true
  def tier_name, do: @tier

  @impl true
  def mode, do: :ci

  @impl true
  def describe,
    do: "aud_event append-only tier carries only bounded-ID/token/enum columns (T2.2)"

  @impl true
  def check(%Context{repo: nil}) do
    [
      Finding.violation(
        @tier,
        "<repo>",
        "no repo configured — cannot scan aud_event (fail closed). " <>
          "Configure :verify_repo / :non_pii_repo / :reveal_grant_repo."
      )
    ]
  end

  def check(%Context{} = context) do
    case columns(context.repo, @table) do
      {:ok, []} ->
        # Table absent from the schema — not yet deployed.  No finding (the tier
        # only asserts over surfaces that EXIST, per T1.8d).
        []

      {:ok, cols} ->
        Enum.flat_map(cols, fn {name, udt} ->
          check_column(@table, name, udt, @allow_list, context)
        end)

      {:error, reason} ->
        [
          Finding.violation(
            @tier,
            @table,
            "could not introspect aud_event columns (#{inspect(reason)}) — fail closed."
          )
        ]
    end
  end

  # ---------------------------------------------------------------------------

  defp check_column(table, name, udt, allow, context) do
    subject = "#{table}.#{name}"
    plaintext_type? = udt in @plaintext_udts

    cond do
      # Non-plaintext physical type: cannot carry raw subject PII — safe.
      not plaintext_type? ->
        []

      # Registered non_pii! exemption: listed, not failed.
      Context.non_pii_exempt?(context, table, name) ->
        [
          Finding.exempt(
            @tier,
            subject,
            "registered non_pii! (plaintext-at-rest by design; erased by row-level redaction)"
          )
        ]

      # Name gate: PII-named plaintext column on the audit tier.
      PiiClassify.pii_name?(strip_prefix(name)) ->
        [
          Finding.violation(
            @tier,
            subject,
            "plaintext (#{udt}) column on aud_event whose name matches a PII identifier " <>
              "pattern. The append-only audit tier must carry only opaque ids and tokens, " <>
              "never plaintext PII. Remove it, tokenise it, or register a non_pii! override."
          )
        ]

      # Allow-list gate (fail closed): unrecognised plaintext column.
      name not in allow ->
        [
          Finding.violation(
            @tier,
            subject,
            "unrecognised plaintext (#{udt}) column on aud_event (not on the bounded-ID/" <>
              "token/enum allow-list). A new text column on the audit tier is a leak until " <>
              "it is removed, tokenised, or registered as a review-gated non_pii! override " <>
              "(fail closed)."
          )
        ]

      # On the allow-list, plaintext type, no PII name-hit: a known bounded field.
      true ->
        []
    end
  end

  # Strip the 3-letter `aud_` prefix for the name heuristic.
  defp strip_prefix(name) do
    case String.split(name, "_", parts: 2) do
      [abbrev, rest] when byte_size(abbrev) == 3 -> rest
      _ -> name
    end
  end

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
