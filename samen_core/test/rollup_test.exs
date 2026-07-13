defmodule Samen.RollupTest do
  @moduledoc """
  T2.3 — rollup framework + rebuild-or-exclude-on-erasure.

  Sections:
    (a) FRAMEWORK — `rebuild_all/1` materialises the rollup from raw `aud_event`;
        dashboards read the small rollup, never scan raw events.
    (b) THE ERASURE POLICY:
        RED PATH R1 — a rollup computed PRE-shred must NOT resurrect the subject
          after erasure (REBUILD arm: raw retained → recompute subject-free).
        RED PATH R2 — SUPPRESS arm: the archived/detached window is SIMULATED
          (raw_retained?: false); the subject's derived rows are flagged
          suppressed (the cohort stat survives, but the erasure is honored).
        Both arms are exercised through the real `Samen.Erasure.shred/2`
        orchestration (the policy is wired into the erasure tx + report artifact).
    (c) ORACLE TIER — `Samen.NoPlaintextPii.Tiers.Rollup` (CI mode): a clean
        rollup passes; a rollup with a plaintext PII-typed column FAILS the build.
    (d) REGISTRY — `Spec.from_config/1` fails closed on a malformed rollup entry.

  ## Simulation seams (documented)

    * There is no detached partition in this environment, so the archived-window
      suppress arm is exercised by forcing `raw_retained?: false`. The mechanism
      that would distinguish the arms in production (a detached partition is
      invisible to `SELECT ... FROM aud_event`) is documented in
      `Samen.Rollup.raw_retained?/3` and unit-tested here via the override.
  """

  use ExUnit.Case, async: false

  alias SamenCore.TestRepo, as: Repo
  alias Samen.Rollup
  alias Samen.Rollup.Spec
  alias Samen.AuditEvent
  alias Samen.Erasure
  alias Samen.Vault
  alias Samen.NoPlaintextPii
  alias Samen.NoPlaintextPii.Context
  alias Samen.NoPlaintextPii.Tiers.Rollup, as: RollupTier

  @table "rol_daily_event_count"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    Samen.Kms.FileBacked.simulate_outage(false)
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)

    on_exit(fn ->
      Samen.Kms.FileBacked.simulate_outage(false)
      Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
    end)

    :ok
  end

  # A UUID subject (rollups key on a bounded UUID subject id).
  defp uuid_subject, do: Ecto.UUID.generate()

  # Insert `n` raw aud_event rows for a subject on a given day (occurred_at).
  defp seed_events(subject_id, org_id, day, n) do
    for i <- 1..n do
      {:ok, _} =
        AuditEvent.insert(Repo, %{
          event_type: "system",
          subject_id: subject_id,
          correlation_id: org_id,
          detail: "evt-#{i}",
          occurred_at: DateTime.new!(day, ~T[12:00:00.000000], "Etc/UTC")
        })
    end

    :ok
  end

  # Read the rollup row (count + suppressed) for a subject, or nil.
  defp rollup_row(subject_id) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT rol_event_count, rol_suppressed FROM #{@table} WHERE rol_subject_id::text = $1",
        [subject_id]
      )

    case rows do
      [[count, suppressed]] -> %{count: count, suppressed: suppressed}
      [] -> nil
    end
  end

  # --- (b') :domain-source helpers (the synthetic movx_ledger / mrx rollup) ---

  defp seed_ledger(subject_id, org_id, kind, delta) do
    Ecto.Adapters.SQL.query!(
      Repo,
      "INSERT INTO movx_ledger (movx_org_id, movx_subject_id, movx_kind, movx_delta_cents) VALUES ($1, $2, $3, $4)",
      [Ecto.UUID.dump!(org_id), Ecto.UUID.dump!(subject_id), kind, delta]
    )

    :ok
  end

  defp mrx_delta(subject_id) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT COALESCE(SUM(mrx_delta_cents),0)::int FROM mrx_movement_rollup WHERE mrx_subject_id::text = $1",
        [subject_id]
      )

    [[sum]] = rows
    sum
  end

  # ======================================================================
  # (a) FRAMEWORK — rebuild_all materialises the rollup from raw events
  # ======================================================================

  describe "(a) refresh framework" do
    test "rebuild_all/1 materialises per-day/per-subject counts from raw aud_event" do
      subject_id = uuid_subject()
      org_id = Ecto.UUID.generate()
      seed_events(subject_id, org_id, ~D[2026-07-04], 3)

      {:ok, results} = Rollup.rebuild_all(Repo)
      assert results[:daily_event_count] >= 1

      # The dashboard reads the SMALL rollup, never scans raw events.
      assert %{count: 3, suppressed: false} = rollup_row(subject_id)
    end

    test "refresh is idempotent — recomputing twice yields the same count" do
      subject_id = uuid_subject()
      seed_events(subject_id, Ecto.UUID.generate(), ~D[2026-07-04], 5)

      {:ok, _} = Rollup.rebuild_all(Repo)
      first = rollup_row(subject_id)
      {:ok, _} = Rollup.rebuild_all(Repo)
      second = rollup_row(subject_id)

      assert first == second
      assert first.count == 5
    end
  end

  # ======================================================================
  # (b) THE ERASURE POLICY — rebuild arm
  # ======================================================================

  describe "(b) REBUILD arm — raw retained" do
    test "RED PATH R1: a pre-shred rollup must NOT resurrect the subject post-shred" do
      subject_id = uuid_subject()
      other_id = uuid_subject()
      org_id = Ecto.UUID.generate()

      # The subject needs a vault row so shred has something to seal (and so the
      # arm decision runs through the real erasure orchestration).
      {:ok, _} = Vault.store_field(subject_id, :pii_email, :emails, "erase@example.com", Repo)

      seed_events(subject_id, org_id, ~D[2026-07-04], 4)
      seed_events(other_id, org_id, ~D[2026-07-04], 2)

      # Compute the rollup PRE-shred — it counts the subject's 4 events.
      {:ok, _} = Rollup.rebuild_all(Repo)
      assert %{count: 4, suppressed: false} = rollup_row(subject_id)
      assert %{count: 2} = rollup_row(other_id)

      # Erase the subject. Raw is retained (events are in an attached partition),
      # so the REBUILD arm fires: raw events deleted, rollup recomputed subject-free.
      assert {:ok, %{report: report}} = Erasure.shred(subject_id)

      # The subject is GONE from the rollup — the pre-shred aggregate did NOT
      # resurrect them. (rebuild arm: the row is recomputed without the subject.)
      assert rollup_row(subject_id) == nil,
             "REBUILD arm must not leave the erased subject in the derived rollup"

      # And the OTHER subject's count is untouched — erasure is surgical.
      assert %{count: 2, suppressed: false} = rollup_row(other_id)

      # The report artifact records the rebuild arm for the oracle (T2.9).
      rollups = report.tiers["rollups"]
      assert is_list(rollups)
      entry = Enum.find(rollups, &(&1["rollup"] == "daily_event_count"))
      assert entry["arm"] == "rebuild"
    end

    test "raw events for the subject are physically deleted by the rebuild arm" do
      subject_id = uuid_subject()
      {:ok, _} = Vault.store_field(subject_id, :pii_email, :emails, "x@example.com", Repo)
      seed_events(subject_id, Ecto.UUID.generate(), ~D[2026-07-04], 3)

      assert length(AuditEvent.for_subject(Repo, subject_id)) >= 3

      {:ok, _} = Erasure.shred(subject_id)

      # The rebuild arm deletes the subject's raw aud_event rows so the recompute
      # excludes them — a real erasure, not a mask. (Erasure also writes ONE new
      # "erasure" audit-event row for the subject as part of sealing, so we assert
      # no pre-erasure "system" events survive rather than exactly zero rows.)
      remaining = AuditEvent.for_subject(Repo, subject_id)
      refute Enum.any?(remaining, &(&1.event_type == "system")),
             "the subject's pre-erasure raw events must be deleted by the rebuild arm"
    end
  end

  # ======================================================================
  # (b) THE ERASURE POLICY — suppress arm (archived window, SIMULATED)
  # ======================================================================

  describe "(b) SUPPRESS arm — window archived/detached (simulated)" do
    test "RED PATH R2: subject's derived row is flagged suppressed, not rebuilt" do
      subject_id = uuid_subject()
      {:ok, _} = Vault.store_field(subject_id, :pii_email, :emails, "arch@example.com", Repo)

      # Materialise a rollup row for the subject (as if from a now-archived window).
      seed_events(subject_id, Ecto.UUID.generate(), ~D[2026-07-04], 6)
      {:ok, _} = Rollup.rebuild_all(Repo)
      assert %{count: 6, suppressed: false} = rollup_row(subject_id)

      # SIMULATION SEAM: the raw window is archived/detached — force the suppress
      # arm (in production a detached partition makes raw_retained? false).
      assert {:ok, %{report: report}} =
               Erasure.shred(subject_id, raw_retained?: false)

      # The derived row SURVIVES (the cohort stat an operator may have exported is
      # not retroactively scrubbed — doc) but is FLAGGED suppressed so dashboards
      # honor the erasure. The subject is NOT resurrected as a live row.
      assert %{count: 6, suppressed: true} = rollup_row(subject_id),
             "SUPPRESS arm must flag the derived row, not leave it live"

      entry = Enum.find(report.tiers["rollups"], &(&1["rollup"] == "daily_event_count"))
      assert entry["arm"] == "suppress"
      assert entry["rows_affected"] == 1
    end

    test "suppress arm is idempotent — re-erasing flips 0 additional rows" do
      subject_id = uuid_subject()
      {:ok, _} = Vault.store_field(subject_id, :pii_email, :emails, "y@example.com", Repo)
      seed_events(subject_id, Ecto.UUID.generate(), ~D[2026-07-04], 2)
      {:ok, _} = Rollup.rebuild_all(Repo)

      first = Rollup.erase_subject(subject_id, Repo, raw_retained?: false)
      assert [%{"arm" => "suppress", "rows_affected" => 1}] = first

      second = Rollup.erase_subject(subject_id, Repo, raw_retained?: false)
      assert [%{"arm" => "suppress", "rows_affected" => 0}] = second
    end
  end

  # ======================================================================
  # (b) arm selection
  # ======================================================================

  describe "raw_retained?/3 — arm selection" do
    test "true when the subject has attached raw events; false when none" do
      subject_id = uuid_subject()
      refute Rollup.raw_retained?(subject_id, Repo)

      seed_events(subject_id, Ecto.UUID.generate(), ~D[2026-07-04], 1)
      assert Rollup.raw_retained?(subject_id, Repo)
    end

    test "override forces the arm deterministically" do
      subject_id = uuid_subject()
      seed_events(subject_id, Ecto.UUID.generate(), ~D[2026-07-04], 1)

      # Even with raw present, the override forces the suppress arm.
      refute Rollup.raw_retained?(subject_id, Repo, raw_retained?: false)
      assert Rollup.raw_retained?(subject_id, Repo, raw_retained?: true)
    end
  end

  # ======================================================================
  # (b') THE ERASURE POLICY — :domain source (ADR-018)
  # ======================================================================

  describe "(b') source: :domain — the ADR-018 domain-sourced REBUILD arm" do
    # A synthetic domain ledger (`movx_ledger`) + a movement-sum rollup
    # (`mrx_movement_rollup`) keyed on the subject id — the generalized shape the
    # revenue rollup uses, proven here in the kernel over a scratch table so the
    # :domain arm is exercised independently of the demo host wiring.
    setup do
      Ecto.Adapters.SQL.query!(
        Repo,
        "CREATE TABLE IF NOT EXISTS movx_ledger (" <>
          "movx_id UUID PRIMARY KEY DEFAULT gen_random_uuid(), " <>
          "movx_org_id UUID, movx_subject_id UUID NOT NULL, " <>
          "movx_kind TEXT NOT NULL, movx_delta_cents INTEGER NOT NULL DEFAULT 0)",
        []
      )

      Ecto.Adapters.SQL.query!(
        Repo,
        "CREATE TABLE IF NOT EXISTS mrx_movement_rollup (" <>
          "mrx_id UUID PRIMARY KEY DEFAULT gen_random_uuid(), " <>
          "mrx_org_id UUID, mrx_subject_id UUID, mrx_kind TEXT, " <>
          "mrx_delta_cents INTEGER NOT NULL DEFAULT 0, mrx_count INTEGER NOT NULL DEFAULT 0, " <>
          "mrx_suppressed BOOLEAN NOT NULL DEFAULT FALSE, " <>
          "mrx_refreshed_at TIMESTAMPTZ NOT NULL DEFAULT now())",
        []
      )

      on_exit(fn ->
        # The sandbox rolls back, but drop for hygiene under shared mode.
        :ok
      end)

      spec =
        Spec.from_config(%{
          name: :movement_rollup,
          source: :domain,
          table: "mrx_movement_rollup",
          subject_column: "mrx_subject_id",
          suppressed_column: "mrx_suppressed",
          subject_delete_sql: "DELETE FROM movx_ledger WHERE movx_subject_id::text = $1",
          # Independent oracle residue-scan target (B2-P1) — kept separate from
          # subject_delete_sql so a sabotaged delete hook cannot fool the scan.
          domain_table: "movx_ledger",
          domain_subject_column: "movx_subject_id",
          bounded_columns:
            ~w(mrx_id mrx_org_id mrx_subject_id mrx_kind mrx_delta_cents mrx_count mrx_suppressed mrx_refreshed_at),
          rebuild_sql:
            {"DELETE FROM mrx_movement_rollup",
             """
             INSERT INTO mrx_movement_rollup
               (mrx_org_id, mrx_subject_id, mrx_kind, mrx_delta_cents, mrx_count, mrx_suppressed, mrx_refreshed_at)
             SELECT movx_org_id, movx_subject_id, movx_kind,
                    SUM(movx_delta_cents)::int, COUNT(*)::int, FALSE, now()
             FROM movx_ledger
             GROUP BY movx_org_id, movx_subject_id, movx_kind
             """}
        })

      {:ok, spec: spec}
    end

    test "the domain spec builds fail-closed and refreshes from the domain table", %{spec: spec} do
      assert spec.source == :domain
      subject_id = uuid_subject()
      org_id = Ecto.UUID.generate()
      seed_ledger(subject_id, org_id, "new", 9_900)
      seed_ledger(subject_id, org_id, "expansion", 1_000)

      {:ok, n} = Rollup.refresh(Repo, spec)
      assert n >= 1
      # The rollup summarises the domain ledger, not aud_event.
      assert mrx_delta(subject_id) == 10_900
    end

    test "AC-G7-7: post-shred domain REBUILD recomputes subject-free", %{spec: spec} do
      subject_id = uuid_subject()
      other_id = uuid_subject()
      org_id = Ecto.UUID.generate()

      # The subject needs a vault row so the real shred orchestration runs.
      {:ok, _} = Vault.store_field(subject_id, :pii_email, :emails, "d@example.com", Repo)

      seed_ledger(subject_id, org_id, "new", 9_900)
      seed_ledger(subject_id, org_id, "expansion", 5_000)
      seed_ledger(other_id, org_id, "new", 2_000)

      {:ok, _} = Rollup.refresh(Repo, spec)
      # Pre-shred: the subject's movement deltas are in the rollup.
      assert mrx_delta(subject_id) == 14_900
      assert mrx_delta(other_id) == 2_000

      # Erase via the REAL orchestration, with ONLY the domain spec registered.
      assert {:ok, %{report: report}} = Erasure.shred(subject_id, specs: [spec])

      # The subject contributes 0 to the recomputed period sums — a real erasure
      # across the domain ledger AND the derived rollup at once.
      assert mrx_delta(subject_id) == 0,
             "the domain REBUILD arm must recompute the subject out of the rollup"

      # The domain ledger rows for the subject are physically gone.
      %{rows: [[cnt]]} =
        Ecto.Adapters.SQL.query!(
          Repo,
          "SELECT COUNT(*) FROM movx_ledger WHERE movx_subject_id::text = $1",
          [subject_id]
        )

      assert cnt == 0

      # The OTHER subject's deltas survive — erasure is surgical.
      assert mrx_delta(other_id) == 2_000

      # The report records the domain rebuild arm for the oracle (AC-G7-7 tier).
      entry = Enum.find(report.tiers["rollups"], &(&1["rollup"] == "movement_rollup"))
      assert entry["arm"] == "rebuild"
      assert entry["source"] == "domain"
      assert entry["rows_affected"] == 2
    end

    @tag :red_path
    test "ANTI-TAUTOLOGY: a sabotaged recompute that STILL counts the subject leaves a re-identifying delta",
         %{spec: spec} do
      subject_id = uuid_subject()
      org_id = Ecto.UUID.generate()
      {:ok, _} = Vault.store_field(subject_id, :pii_email, :emails, "s@example.com", Repo)
      seed_ledger(subject_id, org_id, "new", 9_900)

      # SABOTAGE: a domain spec whose subject_delete_sql deletes NOTHING (a broken
      # erasure hook — the classic "recompute still counts the subject" bug ADR-018
      # §5 / AC-G7-7 forbids). The recompute then re-derives the subject's delta.
      # (Keeps the $1 placeholder so the arm's parameter binding is unchanged — the
      # bug is a mis-scoped predicate that never matches the subject, not a dropped
      # parameter. `$1 IS NULL` is false for every real subject id, so nothing is
      # deleted — the subject's ledger rows survive the "erasure".)
      sabotaged = %{spec | subject_delete_sql: "DELETE FROM movx_ledger WHERE $1::text IS NULL"}

      {:ok, _} = Rollup.refresh(Repo, sabotaged)
      assert mrx_delta(subject_id) == 9_900

      {:ok, %{report: _}} = Erasure.shred(subject_id, specs: [sabotaged])

      # THE PROOF the arm is load-bearing: with a broken delete hook, the subject's
      # 9900 delta SURVIVES the shred — a re-identifying residue. This is what the
      # destruction oracle catches (AC-G7-7). The correct spec (prior test) drives it
      # to 0; the sabotaged spec leaves it non-zero → the guarantee is NOT tautological.
      assert mrx_delta(subject_id) == 9_900,
             "a sabotaged (no-op) delete hook must leave the re-identifying delta — proving the " <>
               "correct hook's subject-free recompute is load-bearing, not incidental"
    end
  end

  # ======================================================================
  # (c) ORACLE TIER — Tiers.Rollup CI mode
  # ======================================================================

  describe "(c) no_plaintext_pii Rollup tier (CI mode)" do
    test "the clean registered rollup passes (only token/bounded-ID/count columns)" do
      findings = RollupTier.check(Context.build(repo: Repo))
      violations = Enum.filter(findings, &(&1.severity == :violation))
      assert violations == [], "clean rollup must pass: #{inspect(violations)}"
    end

    test "the Rollup tier is in the default oracle roster" do
      assert RollupTier in NoPlaintextPii.default_tiers()
    end

    test "RED PATH: a rollup with a plaintext PII-typed column FAILS CI mode" do
      # A spec pointing at a rollup table that has a plaintext PII column not on
      # the allow-list. We create a scratch rollup table with an offending column.
      Ecto.Adapters.SQL.query!(
        Repo,
        "CREATE TABLE IF NOT EXISTS rol_bad_rollup (" <>
          "rol_id UUID PRIMARY KEY DEFAULT gen_random_uuid(), " <>
          "rol_subject_id UUID, rol_suppressed BOOLEAN DEFAULT FALSE, " <>
          "rol_ssn TEXT)",
        []
      )

      bad_spec = %Spec{
        name: :bad_rollup,
        table: "rol_bad_rollup",
        subject_column: "rol_subject_id",
        suppressed_column: "rol_suppressed",
        bounded_columns: ~w(rol_id rol_subject_id rol_suppressed),
        rebuild_sql: {"DELETE FROM rol_bad_rollup", "INSERT INTO rol_bad_rollup (rol_id) SELECT gen_random_uuid()"}
      }

      # Register ONLY the bad spec for this check (via config override).
      prior = Application.get_env(:samen_core, :rollups)
      Application.put_env(:samen_core, :rollups, [Map.from_struct(bad_spec)])

      try do
        findings = RollupTier.check(Context.build(repo: Repo))
        violations = Enum.filter(findings, &(&1.severity == :violation))

        assert Enum.any?(violations, fn v ->
                 v.subject == "rol_bad_rollup.rol_ssn"
               end),
               "a plaintext PII column on a rollup must be a CI-mode violation, got: #{inspect(violations)}"
      after
        Application.put_env(:samen_core, :rollups, prior)
        Ecto.Adapters.SQL.query!(Repo, "DROP TABLE IF EXISTS rol_bad_rollup", [])
      end
    end

    test "RED PATH: a registered rollup with NO backing table FAILS closed" do
      prior = Application.get_env(:samen_core, :rollups)

      ghost = %{
        name: :ghost,
        table: "rol_ghost_does_not_exist",
        subject_column: "rol_subject_id",
        suppressed_column: "rol_suppressed",
        bounded_columns: ~w(rol_subject_id rol_suppressed),
        rebuild_sql: {"DELETE FROM rol_ghost_does_not_exist", "SELECT 1"}
      }

      Application.put_env(:samen_core, :rollups, [ghost])

      try do
        findings = RollupTier.check(Context.build(repo: Repo))
        violations = Enum.filter(findings, &(&1.severity == :violation))
        assert Enum.any?(violations, &(&1.subject == "rol_ghost_does_not_exist"))
      after
        Application.put_env(:samen_core, :rollups, prior)
      end
    end

    test "no repo configured fails closed (cannot scan)" do
      # Force the nil-repo path (Context.build/1 would otherwise resolve the
      # configured default repo) to prove the tier fails closed with no repo.
      nil_ctx = %Context{
        repo: nil,
        resources: [],
        vault_routed: MapSet.new(),
        non_pii_exempt: MapSet.new(),
        deps: []
      }

      findings = RollupTier.check(nil_ctx)
      assert Enum.any?(findings, &(&1.severity == :violation))
    end
  end

  # ======================================================================
  # (d) REGISTRY — Spec.from_config/1 fail-closed validation
  # ======================================================================

  describe "(d) Spec.from_config/1 — fail closed on malformed entries" do
    test "the configured registry builds cleanly" do
      specs = Rollup.specs()
      assert Enum.any?(specs, &(&1.name == :daily_event_count))
      assert Enum.all?(specs, &match?(%Spec{}, &1))
    end

    test "a struct passes through unchanged" do
      %Spec{} = spec = hd(Rollup.specs())
      assert Spec.from_config(spec) == spec
    end

    test "missing key raises" do
      assert_raise ArgumentError, ~r/missing required key/, fn ->
        Spec.from_config(%{name: :x})
      end
    end

    test "subject_column must appear in bounded_columns" do
      assert_raise ArgumentError, ~r/must appear in :bounded_columns/, fn ->
        Spec.from_config(%{
          name: :bad,
          table: "rol_x",
          subject_column: "rol_missing",
          suppressed_column: "rol_suppressed",
          bounded_columns: ~w(rol_suppressed),
          rebuild_sql: {"DELETE FROM rol_x", "SELECT 1"}
        })
      end
    end

    test "source: :domain requires a non-empty subject_delete_sql (fail closed)" do
      assert_raise ArgumentError, ~r/source: :domain and MUST declare a non-empty/, fn ->
        Spec.from_config(%{
          name: :bad_domain,
          source: :domain,
          table: "mrx_x",
          subject_column: "mrx_subject_id",
          suppressed_column: "mrx_suppressed",
          bounded_columns: ~w(mrx_subject_id mrx_suppressed),
          rebuild_sql: {"DELETE FROM mrx_x", "SELECT 1"}
          # subject_delete_sql omitted → fail closed.
        })
      end
    end

    test "source: :aud_event must NOT declare a subject_delete_sql (fail closed)" do
      assert_raise ArgumentError, ~r/source: :aud_event and MUST NOT declare/, fn ->
        Spec.from_config(%{
          name: :bad_aud,
          table: "rol_x",
          subject_column: "rol_s",
          suppressed_column: "rol_sup",
          subject_delete_sql: "DELETE FROM whatever WHERE x = $1",
          bounded_columns: ~w(rol_s rol_sup),
          rebuild_sql: {"DELETE FROM rol_x", "SELECT 1"}
        })
      end
    end

    test "an unknown source is refused (fail closed)" do
      assert_raise ArgumentError, ~r/:source must be one of/, fn ->
        Spec.from_config(%{
          name: :bad_source,
          source: :clickhouse,
          table: "rol_x",
          subject_column: "rol_s",
          suppressed_column: "rol_sup",
          bounded_columns: ~w(rol_s rol_sup),
          rebuild_sql: {"DELETE FROM rol_x", "SELECT 1"}
        })
      end
    end

    test "a legacy config without :source defaults to :aud_event (behavior unchanged)" do
      spec =
        Spec.from_config(%{
          name: :legacy,
          table: "rol_x",
          subject_column: "rol_s",
          suppressed_column: "rol_sup",
          bounded_columns: ~w(rol_s rol_sup),
          rebuild_sql: {"DELETE FROM rol_x", "SELECT 1"}
        })

      assert spec.source == :aud_event
      assert spec.subject_delete_sql == nil
    end

    test "rebuild_sql must be a non-empty {delete, insert} pair" do
      assert_raise ArgumentError, ~r/:rebuild_sql must be/, fn ->
        Spec.from_config(%{
          name: :bad,
          table: "rol_x",
          subject_column: "rol_s",
          suppressed_column: "rol_sup",
          bounded_columns: ~w(rol_s rol_sup),
          rebuild_sql: "not a tuple"
        })
      end
    end
  end
end
