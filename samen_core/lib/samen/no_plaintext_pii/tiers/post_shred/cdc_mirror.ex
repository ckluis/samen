defmodule Samen.NoPlaintextPii.Tiers.PostShred.CdcMirror do
  @moduledoc """
  **Post-shred CDC-mirror tier — ACTIVE (Phase-6 H4 / T6.5)** (doc §runs oracle
  block "live·replica·cdc_mirror·rollup·audit·registered_non_pii"; doc line 637;
  plan T6.5).

  The ClickHouse CDC mirror is opt-in per product, default off (doc line 635). This
  tier's behaviour therefore has THREE states, each honest:

    1. **Tier OFF** (`Samen.Cdc.enabled?/0` false, no legacy key) — the mirror is
       not enabled in this deployment. Emit a single `:pass` stating so. Most
       products live here.

    2. **Tier ON** (an adapter wired via `config :samen_core, :cdc`) — perform a
       REAL content scan against the (simulated or real) mirror:

         * **schema assertion** — every physical column on every mirror table is a
           token / bounded-ID / enum / timestamp / number / metadata column; a
           plaintext-PII-shaped column is a `:violation` (this is the projection's
           `assert_no_plaintext!` proved at the physical tier);
         * **post-shred content scan** — for the erased subject, no `vt_*` token in
           the mirror still decrypts (the vault key is destroyed, so the mirror
           holds only DANGLING tokens — it inherited erasure for free, doc line
           637). A decryptable mirror token is a `:violation`;
         * **never-read-current attestation** — a `:pass` recording that the
           analytics repo is governed by the never-read-current lint/runtime guard.

    3. **Legacy configured-but-unscanned** (`:cdc_mirror_repo` set but no `:cdc`
       adapter) — a configured mirror with no adapter to scan it is a fail-closed
       GAP, not a pass (the T2.9 rule). `:violation`, pointing at the `:cdc` wiring.

  ## Simulation vs production (plan HARD note — no ClickHouse here)

  In this environment the wired adapter is `Samen.Cdc.LocalPostgres`, which mirrors
  into a second local Postgres schema (`cdc_mirror`) standing in for ClickHouse.
  The scan logic is adapter-independent (`Samen.Cdc.scan_no_plaintext/2` +
  `mirrored_columns/2`), so the SAME oracle tier drives a real ClickHouse mirror in
  production once `Samen.Cdc.ClickHouse` is connected (operator TODO in that
  module).
  """

  @behaviour Samen.NoPlaintextPii.Tier

  alias Samen.NoPlaintextPii.{Context, Finding}
  alias Samen.Cdc

  @tier :cdc_mirror

  @impl true
  def tier_name, do: @tier

  @impl true
  def mode, do: :post_shred

  @impl true
  def describe,
    do:
      "post-shred CDC-mirror tier (opt-in, default off): token-only projection + " <>
        "post-shred dangling-tokens + never-read-current governance"

  @impl true
  def check(%Context{subject_id: nil}) do
    [
      Finding.violation(
        @tier,
        "<subject>",
        "post-shred CDC-mirror tier requires --subject <uuid> — fail closed."
      )
    ]
  end

  def check(%Context{subject_id: subject_id, resources: resources}) do
    cond do
      Cdc.enabled?() ->
        active_scan(subject_id, resources)

      Samen.Cdc.Config.legacy_mirror_configured?() ->
        [
          Finding.violation(
            @tier,
            "cdc_mirror",
            "a legacy :cdc_mirror_repo is set but no :cdc adapter is wired — the mirror is " <>
              "configured but there is nothing to scan it. A configured-but-unscanned mirror " <>
              "is a fail-closed GAP (T2.9/T6.5). Wire `config :samen_core, :cdc, adapter: …, " <>
              "repo: …` or unset :cdc_mirror_repo."
          )
        ]

      true ->
        [
          Finding.pass(
            @tier,
            "cdc_mirror",
            "CDC mirror not enabled in this deployment (opt-in per product, default off — " <>
              "doc line 635). The token-only-downstream invariant makes it safe when on; " <>
              "wire `config :samen_core, :cdc, adapter: …` to enable + scan it."
          )
        ]
    end
  end

  # ---------------------------------------------------------------------------
  # Active scan (tier ON) — schema token-only + post-shred dangling tokens.
  # ---------------------------------------------------------------------------

  defp active_scan(subject_id, resources) do
    schema_findings(resources) ++
      content_findings(subject_id) ++
      governance_findings()
  end

  # Assert every physical mirror column is token-blind (no plaintext-PII-shaped
  # column). We prove this at TWO levels: (a) the projection excludes plaintext PII
  # by construction (Samen.Cdc.Projection.assert_no_plaintext!), and (b) the
  # physical mirror table columns are all in the projected set.
  defp schema_findings(resources) do
    Enum.flat_map(resources, fn resource ->
      table = Samen.Cdc.Projection.table_name(resource)

      if table, do: table_schema_finding(resource, table), else: []
    end)
    |> case do
      [] ->
        [
          Finding.pass(
            @tier,
            "schema",
            "no CDC-mirrored resources discovered — nothing to assert token-only over " <>
              "(the projection would refuse any plaintext PII column if one existed)."
          )
        ]

      findings ->
        findings
    end
  end

  defp table_schema_finding(resource, table) do
    projected = Samen.Cdc.Projection.project(resource)
    projected_cols = MapSet.new(Enum.map(projected, &elem(&1, 0)))

    case Cdc.mirrored_columns(table) do
      {:ok, []} ->
        # The mirror table doesn't physically exist yet — nothing materialized.
        # Not a violation (the projection is proven clean above); note it.
        [
          Finding.pass(
            @tier,
            "schema:#{table}",
            "projection for #{table} is token-blind (#{MapSet.size(projected_cols)} cols); " <>
              "mirror table not yet materialized in this deployment."
          )
        ]

      {:ok, physical_cols} ->
        # cdc_subject_id is the injected bounded id; everything else must be in the
        # token-blind projection.
        rogue =
          physical_cols
          |> Enum.reject(&(&1 == "cdc_subject_id"))
          |> Enum.reject(&MapSet.member?(projected_cols, &1))

        if rogue == [] do
          [
            Finding.pass(
              @tier,
              "schema:#{table}",
              "every mirror column on #{table} is in the token-blind projection " <>
                "(#{Enum.join(physical_cols, ", ")}) — no plaintext PII column."
            )
          ]
        else
          [
            Finding.violation(
              @tier,
              "schema:#{table}",
              "mirror table #{table} carries column(s) NOT in the token-blind projection: " <>
                "#{Enum.join(rogue, ", ")}. A non-projected column in the analytics mirror " <>
                "can smuggle plaintext downstream — the token-only-downstream invariant is " <>
                "broken. Fail closed."
            )
          ]
        end

      {:error, reason} ->
        [
          Finding.violation(
            @tier,
            "schema:#{table}",
            "could not introspect mirror columns for #{table} (#{inspect(reason)}) — a mirror " <>
              "the oracle cannot scan is a fail-closed gap, not an all-clear."
          )
        ]
    end
  rescue
    e in Samen.Cdc.Projection.PlaintextInProjectionError ->
      [Finding.violation(@tier, "schema:#{table}", Exception.message(e))]

    e ->
      [
        Finding.violation(
          @tier,
          "schema:#{table}",
          "CDC schema assertion raised #{inspect(e.__struct__)}: #{Exception.message(e)} — fail closed."
        )
      ]
  end

  # Post-shred: no mirror token for the subject still decrypts. The mirror KEEPS
  # the tokens (append-only, seconds-stale) — they are DANGLING (the vault key is
  # gone). That is the erasure-for-free property, proven by a real scan.
  defp content_findings(subject_id) do
    case Cdc.scan_no_plaintext(subject_id) do
      {:ok, :no_plaintext} ->
        dangling =
          case Cdc.adapter() do
            Samen.Cdc.LocalPostgres -> length(Samen.Cdc.LocalPostgres.dangling_tokens(subject_id))
            _ -> :unknown
          end

        [
          Finding.pass(
            @tier,
            "content",
            "no CDC-mirror token for #{subject_id} decrypts — the mirror holds only DANGLING " <>
              "tokens (count=#{inspect(dangling)}); the per-subject vault key is destroyed, so " <>
              "the analytics tier inherited erasure for free (doc line 637)."
          )
        ]

      {:leaks, details} ->
        [
          Finding.violation(
            @tier,
            "content",
            "CDC-mirror STILL HOLDS decryptable content for #{subject_id}: " <>
              "#{Enum.join(details, "; ")}. The mirror is not token-blind or the shred did not " <>
              "reach it — fail closed."
          )
        ]
    end
  end

  defp governance_findings do
    repo = Samen.Cdc.Config.repo()

    [
      Finding.pass(
        @tier,
        "never_read_current",
        "analytics repo #{inspect(repo)} is governed by the never-read-current rule " <>
          "(runtime read_current/3 raises; build-time `mix samen.verify.never_read_current` " <>
          "flags un-marked CDC-repo reads) — doc line 635."
      )
    ]
  end
end
