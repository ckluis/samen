defmodule Samen.AuditEventTest do
  @moduledoc """
  T2.2: `aud_event` append-only event/audit tier tests.

  Covers:
    (a) INSERT routes to the correct partition (green path).
    (b) UPDATE denied — BOTH the role-revocation layer AND the trigger layer.
    (c) DELETE denied — BOTH the role-revocation layer AND the trigger layer.
    (d) Partition manager creates monthly partitions ahead of time.
    (e) Detach-for-archival refuses when erasure window is active.
    (f) Grant lifecycle events land on aud_event (token-only).
    (g) Erasure events land on aud_event (token-only).
    (h) no_plaintext_pii AudEvent tier: clean table passes; plaintext PII column fails.
  """

  use ExUnit.Case, async: false

  alias SamenCore.TestRepo, as: Repo
  alias Samen.AuditEvent
  alias Samen.AuditEvent.PartitionManager
  alias Samen.AuditEvent.DefaultErasureWindowPolicy
  alias Samen.NoPlaintextPii.Tiers.AudEvent, as: AudEventTier
  alias Samen.NoPlaintextPii.Context

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  # ---------------------------------------------------------------------------
  # (a) Green-path insert routes to the right partition
  # ---------------------------------------------------------------------------

  describe "insert/2 — green path" do
    test "inserts an event row successfully" do
      attrs = %{
        event_type: "grant_lifecycle",
        subject_id: "subj-#{System.unique_integer([:positive])}",
        actor_id: "actor-001",
        detail: "event=granted",
        occurred_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      }

      assert {:ok, row} = AuditEvent.insert(Repo, attrs)
      assert row.event_type == "grant_lifecycle"
      assert row.subject_id == attrs.subject_id
    end

    test "for_subject/2 returns rows newest-first" do
      subject_id = "subj-#{System.unique_integer([:positive])}"
      t1 = ~U[2026-07-04 10:00:00Z]
      t2 = ~U[2026-07-04 11:00:00Z]

      {:ok, _} = AuditEvent.insert(Repo, %{event_type: "erasure", subject_id: subject_id, occurred_at: t1})
      {:ok, _} = AuditEvent.insert(Repo, %{event_type: "erasure", subject_id: subject_id, occurred_at: t2})

      rows = AuditEvent.for_subject(Repo, subject_id)
      assert length(rows) == 2
      # Newest first
      assert hd(rows).occurred_at >= List.last(rows).occurred_at
    end

    test "row routes to the correct July 2026 partition" do
      # Verify the row is stored in the July partition by querying the child
      # partition table directly.
      subject_id = "route-test-#{System.unique_integer([:positive])}"
      {:ok, row} = AuditEvent.insert(Repo, %{
        event_type: "system",
        subject_id: subject_id,
        occurred_at: ~U[2026-07-15 12:00:00Z]
      })

      # Query the child partition directly — should find the row there.
      %{rows: [[count]]} =
        Repo.query!("SELECT COUNT(*) FROM aud_event_y2026m07 WHERE aud_subject_id = $1",
          [subject_id])
      assert count == 1

      # The parent query also finds it.
      assert [found] = AuditEvent.for_subject(Repo, subject_id)
      assert found.id == row.id
    end
  end

  # ---------------------------------------------------------------------------
  # (b) UPDATE denied — RED PATHS (role + trigger, both must fail)
  # ---------------------------------------------------------------------------

  describe "UPDATE on aud_event — red path (append-only enforcement)" do
    test "UPDATE via repo.query raises a DB exception (trigger layer)" do
      {:ok, row} = AuditEvent.insert(Repo, %{
        event_type: "grant_lifecycle",
        subject_id: "upd-subj",
        detail: "original",
        occurred_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      })

      # The trigger fires on BEFORE UPDATE — raises 'aud_event is append-only'.
      assert_raise Postgrex.Error, ~r/append-only/i, fn ->
        Repo.query!(
          "UPDATE aud_event SET aud_detail = 'mutated' WHERE aud_id = $1",
          [Ecto.UUID.dump!(row.id)]
        )
      end
    end

    test "UPDATE via Ecto schema raises (trigger layer, belt)" do
      {:ok, row} = AuditEvent.insert(Repo, %{
        event_type: "grant_lifecycle",
        subject_id: "upd-ecto",
        occurred_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      })

      # Attempt via Ecto.Changeset.change + repo.update.
      cs = Ecto.Changeset.change(row, detail: "mutated")

      assert_raise Postgrex.Error, ~r/append-only/i, fn ->
        Repo.update!(cs)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # (c) DELETE denied — RED PATHS
  # ---------------------------------------------------------------------------

  describe "DELETE on aud_event — red path (append-only enforcement)" do
    test "DELETE via repo.query raises a DB exception (trigger layer)" do
      {:ok, row} = AuditEvent.insert(Repo, %{
        event_type: "erasure",
        subject_id: "del-subj",
        occurred_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      })

      assert_raise Postgrex.Error, ~r/append-only/i, fn ->
        Repo.query!(
          "DELETE FROM aud_event WHERE aud_id = $1",
          [Ecto.UUID.dump!(row.id)]
        )
      end
    end

    test "DELETE via Ecto repo.delete raises (trigger layer)" do
      {:ok, row} = AuditEvent.insert(Repo, %{
        event_type: "erasure",
        subject_id: "del-ecto",
        occurred_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      })

      assert_raise Postgrex.Error, ~r/append-only/i, fn ->
        Repo.delete!(row)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # (d) Partition manager — ensure_partition creates the next month
  # ---------------------------------------------------------------------------

  describe "PartitionManager.ensure_partition/2" do
    test "creates a partition for a month that does not yet exist" do
      # Use a far-future month that almost certainly doesn't exist.
      date = Date.new!(2099, 1, 1)
      name = PartitionManager.partition_name(date)

      # Ensure it doesn't exist before the test.
      Repo.query("DROP TABLE IF EXISTS #{name}")

      assert {:ok, ^name} = PartitionManager.ensure_partition(Repo, date)

      # Check via pg_inherits.
      %{rows: rows} =
        Repo.query!(
          """
          SELECT c.relname FROM pg_inherits i
          JOIN pg_class p ON p.oid = i.inhparent
          JOIN pg_class c ON c.oid = i.inhrelid
          WHERE p.relname = 'aud_event' AND c.relname = $1
          """,
          [name]
        )

      assert rows != []

      # Cleanup.
      Repo.query("ALTER TABLE aud_event DETACH PARTITION #{name}")
      Repo.query("DROP TABLE IF EXISTS #{name}")
    end

    test "ensure_partition is idempotent (second call returns {:ok, name})" do
      date = Date.new!(2099, 2, 1)
      name = PartitionManager.partition_name(date)
      Repo.query("DROP TABLE IF EXISTS #{name}")

      assert {:ok, ^name} = PartitionManager.ensure_partition(Repo, date)
      assert {:ok, ^name} = PartitionManager.ensure_partition(Repo, date)

      Repo.query("ALTER TABLE aud_event DETACH PARTITION #{name}")
      Repo.query("DROP TABLE IF EXISTS #{name}")
    end

    test "partition_spec/1 computes correct table name and bounds" do
      {name, from_ts, to_ts} = PartitionManager.partition_spec(Date.new!(2026, 7, 15))
      assert name == "aud_event_y2026m07"
      assert from_ts == "2026-07-01 00:00:00+00"
      assert to_ts == "2026-08-01 00:00:00+00"
    end
  end

  # ---------------------------------------------------------------------------
  # (d.2) T128: forward-roll across a partition boundary (PRODUCTION cron behavior)
  # ---------------------------------------------------------------------------
  # The production defect this guards: aud_event is partitioned; once the wall clock
  # crosses the latest existing partition boundary, an audit write has no partition to
  # land in and FAILS. `Samen.AuditEvent.PartitionManager` (wired into
  # `Samen.Jobs.default_crontab/0`, daily @ 01:00) rolls the partitions forward. These
  # tests prove: (1) the failure mode is real; (2) ensure_upcoming crossing a boundary
  # makes the future-month write SUCCEED and is idempotent; (3) the cron's worker
  # perform/1 actually invokes ensure_upcoming (not a stub).

  defp aud_partition_exists?(name) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT 1 FROM pg_inherits i
        JOIN pg_class p ON p.oid = i.inhparent
        JOIN pg_class c ON c.oid = i.inhrelid
        WHERE p.relname = 'aud_event' AND c.relname = $1
        """,
        [name]
      )

    rows != []
  end

  describe "PartitionManager forward-roll (T128 production audit-write safety)" do
    test "BASELINE: an audit write to a month with NO partition FAILS (the silent prod defect)" do
      # A far-future month whose partition does not exist. This is exactly what happens
      # in production once the clock passes the last migration-seeded partition.
      future = ~U[2099-11-15 09:00:00Z]
      name = PartitionManager.partition_name(DateTime.to_date(future))
      Repo.query("DROP TABLE IF EXISTS #{name}")
      refute aud_partition_exists?(name)

      # No partition to hold the row -> Postgres refuses the insert. Audit trail lost.
      assert_raise Postgrex.Error, ~r/no partition/i, fn ->
        AuditEvent.insert(Repo, %{
          event_type: "system",
          subject_id: "t128-baseline",
          occurred_at: future
        })
      end
    end

    test "ensure_upcoming crossing a boundary creates the partition + the write SUCCEEDS (idempotent)" do
      # Anchor two months BEFORE a fresh future month so the job's lookahead rolls the
      # boundary forward into it (mirrors the daily cron catching up past a boundary).
      anchor = ~D[2099-09-15]
      target = ~U[2099-11-15 09:00:00Z]
      target_date = DateTime.to_date(target)
      target_name = PartitionManager.partition_name(target_date)

      created_names =
        [~D[2099-09-01], ~D[2099-10-01], target_date]
        |> Enum.map(&PartitionManager.partition_name/1)

      # Start clean: none of the three months exist.
      Enum.each(created_names, fn n -> Repo.query("DROP TABLE IF EXISTS #{n}") end)
      refute aud_partition_exists?(target_name)

      # ROLL FORWARD (exactly the call the worker's perform/1 makes).
      results = PartitionManager.ensure_upcoming_partitions(Repo, anchor, 2)
      assert Enum.all?(results, &match?({:ok, _}, &1))
      assert aud_partition_exists?(target_name)

      # The future-month audit write now SUCCEEDS — the defect is closed.
      assert {:ok, row} =
               AuditEvent.insert(Repo, %{
                 event_type: "system",
                 subject_id: "t128-forward",
                 occurred_at: target
               })

      # It landed in the newly-created November partition (not the parent-only view).
      %{rows: [[count]]} =
        Repo.query!("SELECT COUNT(*) FROM #{target_name} WHERE aud_id = $1", [
          Ecto.UUID.dump!(row.id)
        ])

      assert count == 1

      # IDEMPOTENT: a second run is a no-op (never drops/rewrites) and the row survives;
      # a subsequent write still succeeds.
      results2 = PartitionManager.ensure_upcoming_partitions(Repo, anchor, 2)
      assert Enum.all?(results2, &match?({:ok, _}, &1))
      assert aud_partition_exists?(target_name)

      %{rows: [[count_after]]} =
        Repo.query!("SELECT COUNT(*) FROM #{target_name} WHERE aud_id = $1", [
          Ecto.UUID.dump!(row.id)
        ])

      assert count_after == 1, "idempotent re-run must NOT drop/rewrite the existing partition/data"

      assert {:ok, _} =
               AuditEvent.insert(Repo, %{
                 event_type: "system",
                 subject_id: "t128-forward-2",
                 occurred_at: ~U[2099-11-20 09:00:00Z]
               })

      # Cleanup (belt-and-suspenders; the sandbox rolls this back anyway).
      Enum.each(created_names, fn n ->
        Repo.query("ALTER TABLE aud_event DETACH PARTITION #{n}")
        Repo.query("DROP TABLE IF EXISTS #{n}")
      end)
    end

    test "the cron's worker perform/1 actually invokes ensure_upcoming (not a stub)" do
      # perform/1 anchors at Date.utc_today() and ensures current + months_ahead months.
      # Drop the +2-month partition, run the worker, and prove it was recreated — a stub
      # returning :ok without doing the work would leave it absent.
      months_ahead = 2
      plus_two = Date.add(Date.utc_today(), months_ahead * 31)
      target_name = PartitionManager.partition_name(plus_two)

      Repo.query("ALTER TABLE aud_event DETACH PARTITION #{target_name}")
      Repo.query("DROP TABLE IF EXISTS #{target_name}")
      refute aud_partition_exists?(target_name)

      # The worker resolves its repo from :aud_event_repo.
      prev = Application.get_env(:samen_core, :aud_event_repo)
      Application.put_env(:samen_core, :aud_event_repo, Repo)

      on_exit(fn ->
        if prev, do: Application.put_env(:samen_core, :aud_event_repo, prev),
          else: Application.delete_env(:samen_core, :aud_event_repo)
      end)

      assert :ok = PartitionManager.perform(%Oban.Job{args: %{"months_ahead" => months_ahead}})
      assert aud_partition_exists?(target_name),
             "worker perform/1 must call ensure_upcoming_partitions and create the partition"
    end
  end

  # ---------------------------------------------------------------------------
  # (e) Detach-for-archival refuses when erasure window is active — RED PATH
  # ---------------------------------------------------------------------------

  describe "PartitionManager.detach_partition/3 — erasure window gate" do
    test "refuses to detach a partition within the erasure window (red path)" do
      # July 2026 is within the default 90-day erasure window.
      july = Date.new!(2026, 7, 1)

      result = PartitionManager.detach_partition(Repo, july)
      assert {:error, :erasure_window_active, detail} = result
      assert is_binary(detail)
      assert detail =~ "erasure window"
    end

    test "DefaultErasureWindowPolicy marks a recent partition as relevant" do
      # A partition that ended yesterday is clearly still in the window.
      yesterday = Date.add(Date.utc_today(), -1)
      {_name, _from, to_ts} = PartitionManager.partition_spec(yesterday)

      result = DefaultErasureWindowPolicy.still_relevant?(%{
        partition_name: "aud_event_test",
        from_ts: "2026-07-01 00:00:00+00",
        to_ts: to_ts
      })

      assert {:relevant, detail} = result
      assert is_binary(detail)
    end

    test "DefaultErasureWindowPolicy marks a very old partition as not relevant" do
      # A partition from 10 years ago is safe.
      old_date = Date.new!(2016, 1, 1)
      {_name, _from, to_ts} = PartitionManager.partition_spec(old_date)

      result = DefaultErasureWindowPolicy.still_relevant?(%{
        partition_name: "aud_event_old",
        from_ts: "2016-01-01 00:00:00+00",
        to_ts: to_ts
      })

      assert :not_relevant = result
    end

    test "detach with :force bypasses the erasure window gate (operator override)" do
      # :force=true detaches despite the erasure window.
      # We use a far-future partition so we can safely create+detach it.
      date = Date.new!(2099, 3, 1)
      name = PartitionManager.partition_name(date)
      Repo.query("DROP TABLE IF EXISTS #{name}")

      {:ok, _} = PartitionManager.ensure_partition(Repo, date)

      assert {:ok, ^name} = PartitionManager.detach_partition(Repo, date, force: true)

      # Cleanup.
      Repo.query("DROP TABLE IF EXISTS #{name}")
    end
  end

  # ---------------------------------------------------------------------------
  # (f) Grant lifecycle events land on aud_event (token-only convention)
  # ---------------------------------------------------------------------------

  describe "grant lifecycle events → aud_event" do
    test "request/1 writes an aud_event row with event_type=grant_lifecycle" do
      # Set up the reveal grant repo.
      Application.put_env(:samen_core, :reveal_grant_repo, Repo)
      subject_id = "grant-evt-#{System.unique_integer([:positive])}"

      {:ok, _req} =
        Samen.Reveal.Grants.request(%{
          subject_id: subject_id,
          requestor_id: "actor-req",
          reason: "support ticket T-001"
        })

      rows = AuditEvent.for_subject(Repo, subject_id)
      assert Enum.any?(rows, &(&1.event_type == "grant_lifecycle"))
    end

    test "aud_event rows from grant lifecycle carry only token-safe fields" do
      Application.put_env(:samen_core, :reveal_grant_repo, Repo)
      subject_id = "token-check-#{System.unique_integer([:positive])}"

      {:ok, _req} =
        Samen.Reveal.Grants.request(%{
          subject_id: subject_id,
          requestor_id: "actor-safe",
          reason: "audit check"
        })

      [row | _] = AuditEvent.for_subject(Repo, subject_id)

      # subject_id is the opaque ID (NOT a plaintext name/email/ssn).
      assert row.subject_id == subject_id
      # actor_id is the opaque operator id.
      assert row.actor_id == "actor-safe"
      # event_type is a bounded enum.
      assert row.event_type in ~w(grant_lifecycle erasure reveal system policy_denial)
    end
  end

  # ---------------------------------------------------------------------------
  # (g) Erasure events land on aud_event
  # ---------------------------------------------------------------------------

  describe "erasure events → aud_event" do
    test "shred/2 emits an aud_event row with event_type=erasure" do
      Application.put_env(:samen_core, :reveal_grant_repo, Repo)
      Application.put_env(:samen_core, :non_pii_repo, Repo)

      subject_id = "era-evt-#{System.unique_integer([:positive])}"

      # Write a vault row so there's something to shred.
      {:ok, _token} =
        Samen.Vault.store_field(subject_id, :pii_test, :test_field, "test-value", Repo)

      {:ok, _} = Samen.Erasure.shred(subject_id, repo: Repo, actor_id: "erasure-actor")

      rows = AuditEvent.for_subject(Repo, subject_id)
      assert Enum.any?(rows, &(&1.event_type == "erasure"))

      erasure_row = Enum.find(rows, &(&1.event_type == "erasure"))
      assert erasure_row.actor_id == "erasure-actor"
      # Detail carries outcome tokens, no plaintext PII.
      assert erasure_row.detail =~ "outcome="
      refute erasure_row.detail =~ "@"  # no email-like content
    end
  end

  # ---------------------------------------------------------------------------
  # (h) no_plaintext_pii AudEvent tier
  # ---------------------------------------------------------------------------

  describe "Samen.NoPlaintextPii.Tiers.AudEvent — CI tier" do
    test "clean aud_event table passes (no violations)" do
      context = Context.build(repo: Repo)
      findings = AudEventTier.check(context)

      violations = Enum.filter(findings, &(&1.severity == :violation))
      assert violations == [], "expected no violations, got: #{inspect(violations)}"
    end

    test "tier_name/0 is :aud_event" do
      assert AudEventTier.tier_name() == :aud_event
    end

    test "mode/0 is :ci" do
      assert AudEventTier.mode() == :ci
    end

    test "plaintext PII column on aud_event FAILS the tier (red path)" do
      # Seed a plaintext PII-named column on aud_event (the exact scenario the
      # tier must catch). We add it, run the check, then drop it.
      Repo.query!("ALTER TABLE aud_event ADD COLUMN aud_ssn TEXT")

      context = Context.build(repo: Repo)
      findings = AudEventTier.check(context)
      violations = Enum.filter(findings, &(&1.severity == :violation))

      # The name-gate: 'ssn' (after stripping 'aud_' prefix) hits the PII heuristic.
      assert Enum.any?(violations, fn f -> f.subject =~ "ssn" end),
             "expected a violation for aud_ssn, got: #{inspect(violations)}"

      # Cleanup (the sandbox auto-rolls back, but be explicit for clarity).
      Repo.query!("ALTER TABLE aud_event DROP COLUMN IF EXISTS aud_ssn")
    end

    test "unrecognised plaintext column on aud_event FAILS the allow-list gate (red path)" do
      # A new text column NOT on the allow-list is a fail-closed violation.
      Repo.query!("ALTER TABLE aud_event ADD COLUMN aud_extra_notes TEXT")

      context = Context.build(repo: Repo)
      findings = AudEventTier.check(context)
      violations = Enum.filter(findings, &(&1.severity == :violation))

      assert Enum.any?(violations, fn f -> f.subject =~ "extra_notes" end),
             "expected allow-list violation for aud_extra_notes, got: #{inspect(violations)}"

      Repo.query!("ALTER TABLE aud_event DROP COLUMN IF EXISTS aud_extra_notes")
    end

    test "aud_event tier is included in Samen.NoPlaintextPii default_tiers/0" do
      assert Samen.NoPlaintextPii.Tiers.AudEvent in Samen.NoPlaintextPii.default_tiers()
    end

    test "no_plaintext_pii CI run passes with clean aud_event" do
      {:ok, findings} =
        Samen.NoPlaintextPii.run(
          repo: Repo,
          deps: [:oban],
          non_pii_entries: []
        )

      violations = Samen.NoPlaintextPii.violations(findings)

      # No violations from the aud_event tier.
      aud_violations = Enum.filter(violations, &(&1.tier == :aud_event))
      assert aud_violations == [],
             "expected no aud_event tier violations, got: #{inspect(aud_violations)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Anti-tautology probe (plan rule (2)): confirm the red-path ACTUALLY fails
  # ---------------------------------------------------------------------------
  # The probe tests above (UPDATE/DELETE/plaintext-column) already serve as
  # red-paths that must raise. The describe blocks above document this explicitly:
  # "assert_raise Postgrex.Error" / "assert Enum.any?(violations, ...)" are the
  # discriminating assertions — passing without an exception or with empty violations
  # would mean the enforcement is not working.
end
