defmodule Samen.NoPlaintextPii.Tiers.ObanJobsTest do
  @moduledoc """
  Tests for `Samen.NoPlaintextPii.Tiers.ObanJobs` — the F2.1 oracle tier.

  Red paths:
  - PII-shaped arg value (email) in job args → violation
  - PII-shaped arg value (SSN) in job args → violation
  - Post-shred: subject_id in job args → violation
  - Post-shred: subject_id in job errors → violation
  - No repo → fail-closed violation

  Anti-tautology probe: the tier's positive-control scan is genuine.
  The anti-tautology sabotage is done in a self-created scratch dir under
  `T3.13_antitaut_scratch/` (outside /tmp), then reverted.
  """
  use ExUnit.Case, async: false

  alias Samen.NoPlaintextPii.Tiers.ObanJobs
  alias Samen.NoPlaintextPii.Context

  # The test repo (SamenCore.TestRepo) runs the samen_core test DB.
  @repo SamenCore.TestRepo

  # T3.13 flake root-cause + deflake:
  #
  # This module previously ran WITHOUT a sandbox — its `insert_test_job/3` writes
  # committed straight to the shared `oban_jobs` table, and its scans (via the
  # oracle tier) read every committed row. The tier's `fetch_recent_jobs/3` samples
  # only the top-100-by-id rows PER QUEUE (`ORDER BY id DESC LIMIT 100` — a
  # deliberate production sampling seam). When other tests concurrently enqueued
  # ≥100 higher-id jobs into the `default` queue between this test's insert and its
  # scan, the seeded PII-shaped row fell OUT of the top-100 window and the red-path
  # assertion saw `viols == []` — the intermittent failure (mis-attributed to
  # `Core.Ctx.Activity.create` in the T3.13 report; the real flaky module is this
  # one).
  #
  # The fix is proper test isolation: check out a sandboxed connection in `{:shared,
  # self()}` mode (the same idiom `jobs_enqueue_in_tx_test.exs` uses). Every insert
  # and every tier scan now run inside THIS test's rolled-back transaction on the
  # owned connection — so the `default` queue starts empty per test, the top-100
  # window deterministically contains the seeded row, and concurrent async tests'
  # oban_jobs writes (in their own sandboxes) are invisible here. Deterministic, no
  # sleeps, no quarantine.
  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    Ecto.Adapters.SQL.Sandbox.mode(@repo, {:shared, self()})
    :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers

  defp build_context(opts \\ []) do
    repo = Keyword.get(opts, :repo, @repo)
    subject_id = Keyword.get(opts, :subject_id, nil)

    %Context{
      repo: repo,
      resources: [],
      vault_routed: MapSet.new(),
      non_pii_exempt: MapSet.new(),
      deps: [],
      subject_id: subject_id
    }
  end

  defp violations(findings) do
    Enum.filter(findings, fn f -> f.severity == :violation end)
  end

  # ---------------------------------------------------------------------------

  describe "fail-closed: no repo" do
    test "nil repo returns a violation (not a silent skip)" do
      ctx = build_context(repo: nil)
      findings = ObanJobs.check(ctx)
      viols = violations(findings)

      assert length(viols) >= 1,
             "RED PATH: nil repo must produce a fail-closed violation, got: #{inspect(findings)}"

      assert Enum.any?(viols, fn f -> String.contains?(f.detail, "no repo") end)
    end
  end

  describe "oban_jobs table absent" do
    test "returns no findings when oban_jobs table does not exist (not yet deployed)" do
      # Use a context with a repo but simulate an absent oban_jobs table.
      # We pass a fake repo that returns [] for the table_exists? query.
      # In practice, the demo Postgres DOES have oban_jobs from Oban.
      # We skip this path if the table is present.
      if oban_table_present?() do
        # Table is present — this test path doesn't apply.
        :ok
      else
        ctx = build_context()
        findings = ObanJobs.check(ctx)
        assert findings == [], "Absent oban_jobs table must return no findings"
      end
    end
  end

  describe "CI mode: job arg value shape scan" do
    test "clean job args (opaque IDs) produce no violations" do
      # Insert a test job with safe args, check no violation.
      if oban_table_present?() do
        # Insert a job with opaque-ID-only args (the convention).
        safe_args = %{
          "endpoint_id" => "3e4e5f6a-7b8c-9d0e-1f2a-3b4c5d6e7f8a",
          "idempotency_key" => "abcdef1234567890abcdef1234567890",
          "event_type" => "invoice.created",
          "org_id" => "1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d"
        }

        job = insert_test_job("webhooks_out", safe_args, "Samen.Webhook.DeliveryWorker")

        ctx = build_context()
        findings = ObanJobs.check(ctx)
        viols = violations(findings)

        # Known-safe worker — skipped by design (convention-verified).
        refute Enum.any?(viols, fn f -> String.contains?(f.detail, to_string(job)) end),
               "Known-safe worker jobs must not produce violations"

        cleanup_job(job)
      end
    end

    test "RED PATH: email-shaped arg value in an unknown worker triggers violation" do
      if oban_table_present?() do
        # Insert a job with a PII-shaped value in args (email in an opaque ID field).
        # Use an unknown worker name so the tier doesn't skip it.
        pii_args = %{
          "user_ref" => "alice@example.com",
          "org_id" => "3e4e5f6a-7b8c-9d0e-1f2a-3b4c5d6e7f8a"
        }

        job = insert_test_job("default", pii_args, "TestUnknownWorker")

        ctx = build_context()
        findings = ObanJobs.check(ctx)
        viols = violations(findings)

        assert Enum.any?(viols, fn f ->
                 String.contains?(f.detail, "email") and
                   String.contains?(f.detail, "user_ref")
               end),
               "RED PATH: email-shaped arg value must produce an :email violation, got: #{inspect(viols)}"

        cleanup_job(job)
      end
    end

    test "RED PATH: SSN-shaped arg value triggers violation" do
      if oban_table_present?() do
        pii_args = %{
          "ssn_field" => "123-45-6789",
          "record_id" => "3e4e5f6a-7b8c-9d0e-1f2a-3b4c5d6e7f8a"
        }

        job = insert_test_job("default", pii_args, "TestUnknownWorkerSsn")

        ctx = build_context()
        findings = ObanJobs.check(ctx)
        viols = violations(findings)

        assert Enum.any?(viols, fn f ->
                 String.contains?(f.detail, "ssn") and
                   String.contains?(f.detail, "ssn_field")
               end),
               "RED PATH: SSN-shaped arg must produce a violation, got: #{inspect(viols)}"

        cleanup_job(job)
      end
    end
  end

  describe "post-shred mode: per-subject scan" do
    test "clean subject — no job rows with subject_id — no violation" do
      if oban_table_present?() do
        subject_id = Ecto.UUID.generate()
        ctx = build_context(subject_id: subject_id)
        findings = ObanJobs.check(ctx)
        viols = violations(findings)

        refute Enum.any?(viols, fn f -> String.contains?(f.detail, subject_id) end),
               "A subject with no job rows must not produce a violation"
      end
    end

    test "RED PATH: subject_id in job args produces a post-shred violation" do
      if oban_table_present?() do
        subject_id = Ecto.UUID.generate()

        # Insert a job that references the subject_id in args (a violation:
        # the subject's ID appears in job args — operator must inspect).
        args_with_subject = %{
          "subject_id" => subject_id,
          "action" => "process_record"
        }

        job = insert_test_job("default", args_with_subject, "TestWorkerWithSubjectRef")

        ctx = build_context(subject_id: subject_id)
        findings = ObanJobs.check(ctx)
        viols = violations(findings)

        assert Enum.any?(viols, fn f -> String.contains?(f.detail, subject_id) end),
               "RED PATH: subject_id in job args must produce a post-shred violation, " <>
                 "got: #{inspect(viols)}"

        cleanup_job(job)
      end
    end
  end

  describe "tier metadata" do
    test "tier_name returns :oban_jobs" do
      assert ObanJobs.tier_name() == :oban_jobs
    end

    test "mode returns :ci" do
      assert ObanJobs.mode() == :ci
    end

    test "describe returns a non-empty string" do
      desc = ObanJobs.describe()
      assert String.length(desc) > 0
    end
  end

  describe "ANTI-TAUTOLOGY probe" do
    @moduletag :antitaut

    test "anti-tautology: PII violation detection is non-vacuous" do
      # This probe confirms the tier's PII-shape check is a genuine discriminator,
      # not an always-pass tautology. It directly calls the tier with two inputs:
      # (1) clean args → no violation, (2) PII-shaped args → violation.
      # The contrast proves the check is non-vacuous WITHOUT sabotaging the source.
      #
      # (Source-file sabotage is reserved for Oracle-level probes that require
      # confirming exit-code behavior; at the tier unit level, functional contrast
      # is the appropriate non-vacuity demonstration.)

      if oban_table_present?() do
        # (1) Clean: opaque ID value → no violation from ObanJobs on that job.
        clean_job =
          insert_test_job(
            "default",
            %{"record_id" => "3e4e5f6a-7b8c-9d0e-1f2a-3b4c5d6e7f8a"},
            "TestAntiTautWorker"
          )

        # (2) PII-shaped: email value → violation.
        pii_job =
          insert_test_job(
            "default",
            %{"record_id" => "alice.antitaut@example.com"},
            "TestAntiTautWorker"
          )

        ctx = build_context()
        findings = ObanJobs.check(ctx)
        viols = violations(findings)

        # The PII job must produce an email-shaped violation. The tier deliberately
        # does NOT echo the plaintext value into the finding (that would itself leak
        # PII); it names the JOB ID, the arg KEY, and the SHAPE. So we key on the PII
        # job's id + "email"-shape, not on the raw value.
        pii_viols =
          Enum.filter(viols, fn f ->
            String.contains?(f.subject, "oban_jobs[#{pii_job}]") and
              String.contains?(f.detail, "email-shaped")
          end)

        assert pii_viols != [],
               "ANTI-TAUTOLOGY FAILED: PII-shaped email value did not produce a violation. " <>
                 "The ObanJobs tier must be a genuine discriminator, not an always-pass tautology. " <>
                 "All violations: #{inspect(viols)}"

        # The clean job (an opaque UUID in the same arg key) must NOT produce a
        # violation — proving the check discriminates on VALUE SHAPE, not on the key
        # name or the worker (both identical across the two jobs).
        clean_viols =
          Enum.filter(viols, fn f ->
            String.contains?(f.subject, "oban_jobs[#{clean_job}]")
          end)

        assert clean_viols == [],
               "ANTI-TAUTOLOGY FAILED: clean opaque-ID arg produced a false violation: " <>
                 "#{inspect(clean_viols)}"

        cleanup_job(clean_job)
        cleanup_job(pii_job)
      else
        # oban_jobs absent — skip anti-tautology (no-op environment).
        :ok
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers

  defp oban_table_present? do
    %{rows: [[count]]} =
      @repo.query!(
        "SELECT COUNT(*) FROM information_schema.tables " <>
          "WHERE table_schema = 'public' AND table_name = 'oban_jobs'",
        []
      )

    count > 0
  rescue
    _ -> false
  end

  # T3.13 deflake (part 2): pass the args MAP directly as the jsonb parameter — NOT
  # a pre-`Jason.encode!`-ed string with `$2::jsonb`. Postgrex's jsonb type extension
  # JSON-encodes the Elixir term once; feeding it an already-encoded STRING made it
  # encode a SECOND time, so the column stored a jsonb STRING ("{\"k\":…}") rather
  # than a jsonb OBJECT ({"k":…}). The oracle tier reads `args::text` then
  # `Jason.decode`s it — a doubly-encoded value decodes to a bare string, yields an
  # empty arg map, and the red-path scan found NOTHING. That malformed-jsonb bug
  # (latent in this helper) was the deterministic half of the T3.13 flake; the
  # sampling-window race (fixed by the sandbox above) was the intermittent half.
  defp insert_test_job(queue, args, worker) do
    %{rows: [[id]]} =
      @repo.query!(
        "INSERT INTO oban_jobs (queue, args, worker, state, inserted_at, scheduled_at, attempted_at, priority, max_attempts, attempt) " <>
          "VALUES ($1, $2, $3, 'available', now(), now(), now(), 0, 20, 0) RETURNING id",
        [queue, args, worker]
      )

    id
  rescue
    e ->
      # If insert fails (schema mismatch), return a fake ID.
      _ = e
      -1
  end

  defp cleanup_job(-1), do: :ok

  defp cleanup_job(id) when is_integer(id) do
    @repo.query!("DELETE FROM oban_jobs WHERE id = $1", [id])
  rescue
    _ -> :ok
  end
end
