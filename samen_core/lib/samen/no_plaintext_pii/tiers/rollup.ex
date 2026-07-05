defmodule Samen.NoPlaintextPii.Tiers.Rollup do
  @moduledoc """
  CI-mode tier: **every registered rollup table carries only token / bounded-ID /
  count / enum / timestamp columns — never a plaintext PII type** (T2.3 (c); doc
  §runs oracle "rollups … exposes ONLY pii_-token / fld_field-tokenized /
  bounded-ID columns — never a plaintext PII type").

  A rollup is a derived summary over the raw append-only `aud_event` tier
  (`Samen.Rollup.Spec`). Because dashboards read the rollup directly, a plaintext
  PII column on a rollup table would leak subject content into every dashboard —
  and, worse, would survive a crypto-shred (key-shred does not reach a plaintext
  aggregate cell). So the token-only-downstream invariant applies to rollups
  exactly as it does to `aud_event`.

  ## What the scan asserts

  For every rollup registered in `Samen.Rollup.specs/0`:

    1. **Name gate** — a column whose name (after stripping the 3-letter abbrev
       prefix) matches the `Samen.PiiClassify` PII-identifier heuristic (`ssn`,
       `dob`, `email`, `phone`, …) on a plaintext physical type is a violation.

    2. **Allow-list gate (fail closed)** — every physical column NOT on the rollup
       spec's `bounded_columns` allow-list is a violation on a plaintext physical
       type, UNLESS registered as a `non_pii!` exemption. A new unrecognised text
       column on a rollup is a leak until removed, tokenised, or reviewed.

    3. **Registry-vs-physical parity (fail closed)** — a registered rollup whose
       physical table is ABSENT is a violation (a registered rollup with no table
       means the framework/erasure/oracle would operate on nothing — fail closed,
       do not silently pass).

  Non-plaintext physical types (uuid, int, bool, date-as-bucket, timestamptz) are
  safe by shape and skipped. NOTE: a `date` UDT is treated as a plaintext PII type
  by the shared classifier (a raw DOB is a `date`) — but a rollup's `rol_day`
  bucket is a legitimate bounded dimension, so it must be on the `bounded_columns`
  allow-list to pass (which it is). The allow-list is what distinguishes a bucket
  dimension from a leaked DOB.

  ## Simulation seam

  Matviews and CDC-mirrored rollups are the same class of surface; this tier scans
  the Postgres rollup TABLES registered in the config. A ClickHouse-mirrored rollup
  (Phase 6 H4) becomes a `cdc_mirror` tier — the registry is already the seam.
  """

  @behaviour Samen.NoPlaintextPii.Tier

  alias Samen.NoPlaintextPii.{Context, Finding}
  alias Samen.PiiClassify
  alias Samen.Rollup

  @tier :rollup

  # Physical types that CAN carry raw plaintext PII by shape.
  @plaintext_udts ~w(varchar text bpchar date)

  @impl true
  def tier_name, do: @tier

  @impl true
  def mode, do: :ci

  @impl true
  def describe,
    do: "registered rollup tables carry only token/bounded-ID/count columns (T2.3)"

  @impl true
  def check(%Context{repo: nil}) do
    [
      Finding.violation(
        @tier,
        "<repo>",
        "no repo configured — cannot scan rollup tables (fail closed). " <>
          "Configure :verify_repo / :non_pii_repo / :reveal_grant_repo."
      )
    ]
  end

  def check(%Context{} = context) do
    Enum.flat_map(Rollup.specs(), fn spec -> check_rollup(spec, context) end)
  end

  # ---------------------------------------------------------------------------

  defp check_rollup(%Rollup.Spec{table: table, bounded_columns: allow}, context) do
    case columns(context.repo, table) do
      {:ok, []} ->
        # Registered rollup with NO physical table — fail closed. A rollup in the
        # registry that has no backing table is a misconfiguration the framework,
        # erasure, and oracle would all silently no-op on; that is a violation.
        [
          Finding.violation(
            @tier,
            table,
            "registered rollup table '#{table}' does not exist in the schema — fail closed. " <>
              "A rollup in Samen.Rollup.specs/0 must have its backing table migrated, " <>
              "or the framework/erasure/oracle operate on nothing."
          )
        ]

      {:ok, cols} ->
        Enum.flat_map(cols, fn {name, udt} ->
          check_column(table, name, udt, allow, context)
        end)

      {:error, reason} ->
        [
          Finding.violation(
            @tier,
            table,
            "could not introspect rollup '#{table}' columns (#{inspect(reason)}) — fail closed."
          )
        ]
    end
  end

  defp check_column(table, name, udt, allow, context) do
    subject = "#{table}.#{name}"
    plaintext_type? = udt in @plaintext_udts

    cond do
      not plaintext_type? ->
        []

      Context.non_pii_exempt?(context, table, name) ->
        [
          Finding.exempt(
            @tier,
            subject,
            "registered non_pii! (plaintext-at-rest by design; erased by row-level redaction)"
          )
        ]

      PiiClassify.pii_name?(strip_prefix(name)) ->
        [
          Finding.violation(
            @tier,
            subject,
            "plaintext (#{udt}) column on rollup '#{table}' whose name matches a PII " <>
              "identifier pattern. A rollup is a derived aggregate dashboards read directly " <>
              "AND it survives crypto-shred — it must carry only tokens/bounded-IDs/counts, " <>
              "never plaintext PII. Remove it, tokenise it, or register a non_pii! override."
          )
        ]

      name not in allow ->
        [
          Finding.violation(
            @tier,
            subject,
            "unrecognised plaintext (#{udt}) column on rollup '#{table}' (not on the spec's " <>
              "bounded_columns allow-list). A new text column on a rollup is a leak until it " <>
              "is removed, tokenised, or registered as a review-gated non_pii! override " <>
              "(fail closed)."
          )
        ]

      true ->
        []
    end
  end

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
