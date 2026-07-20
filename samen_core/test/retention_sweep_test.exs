defmodule Samen.RetentionSweepTest do
  @moduledoc """
  F3.2 — per-scope retention / TTL sweep (`Samen.Retention`).

  The load-bearing guarantee: a row past its configured TTL IS swept; a row within
  TTL is NEVER touched; a spec with an invalid (non-positive) TTL is REFUSED rather
  than sweeping the whole table (fail-closed).

  Anti-tautology: every "swept" assertion is paired with a same-table "retained"
  positive control differing only in age — so "swept" is a real, refutable outcome
  and never an "empty the table" bug.
  """
  use ExUnit.Case, async: false

  require Ash.Query

  alias SamenCore.TestRepo, as: Repo
  alias Samen.Retention
  alias Samen.Retention.Spec
  alias Samen.Vault

  alias SamenCore.Support.Crm.Company

  @repo Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Samen.Kms.FileBacked.simulate_outage(false)
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
    on_exit(fn -> Application.delete_env(:samen_core, :retention_specs) end)
    :ok
  end

  @now ~U[2026-07-20 12:00:00Z]

  # Create a Company and force its inserted_at to `age_days` ago (the retention clock).
  defp company_aged!(name, age_days) do
    row =
      Company
      |> Ash.Changeset.for_create(:create, %{name: name, org_id: Ash.UUID.generate()})
      |> Ash.create!(authorize?: false)

    ts = DateTime.add(@now, -age_days * 24 * 60 * 60, :second) |> DateTime.truncate(:second)
    Repo.query!("UPDATE cpy_company SET cpy_inserted_at = $1 WHERE cpy_id = $2", [ts, Ecto.UUID.dump!(row.id)])
    row
  end

  defp exists?(id) do
    Company |> Ash.Query.filter(id == ^id) |> Ash.read!(authorize?: false) != []
  end

  describe ":delete sweep — the TTL wall" do
    test "a row OLDER than the TTL is swept; a fresher row is RETAINED (positive control)" do
      old = company_aged!("stale", 400)
      fresh = company_aged!("fresh", 10)

      # 365-day TTL: `old` (400d) is expired, `fresh` (10d) is not.
      spec = %Spec{resource: Company, ttl_seconds: 365 * 24 * 60 * 60, action: :delete}
      report = Retention.sweep([spec], now: @now)

      assert report.swept == 1
      refute exists?(old.id), "an over-TTL row must be swept"
      assert exists?(fresh.id), "an in-TTL row must be retained"
    end

    test "a row exactly AT the TTL edge is expired (<= cutoff)" do
      edge = company_aged!("edge", 30)
      spec = %Spec{resource: Company, ttl_seconds: 30 * 24 * 60 * 60, action: :delete}
      report = Retention.sweep([spec], now: @now)
      assert report.swept == 1
      refute exists?(edge.id)
    end

    test "with NOTHING expired the sweep touches nothing" do
      keep = company_aged!("keep", 5)
      spec = %Spec{resource: Company, ttl_seconds: 365 * 24 * 60 * 60, action: :delete}
      assert %{swept: 0} = Retention.sweep([spec], now: @now)
      assert exists?(keep.id)
    end
  end

  describe "fail-closed cutoff — an invalid TTL never sweeps the table" do
    test "a zero / nil / negative TTL is REFUSED (swept: 0, all rows retained)" do
      a = company_aged!("a", 1000)
      b = company_aged!("b", 2000)

      for bad <- [0, -1, nil, "365"] do
        report = Retention.sweep([%Spec{resource: Company, ttl_seconds: bad, action: :delete}], now: @now)
        assert report.swept == 0, "ttl=#{inspect(bad)} must sweep nothing"
      end

      # Both very-old rows survive — the guard, not the age, protected them.
      assert exists?(a.id)
      assert exists?(b.id)
    end

    test "cutoff/2 raises on a non-positive TTL (never computes a 'delete everything' wall)" do
      assert_raise FunctionClauseError, fn -> Retention.cutoff(0, @now) end
      assert Retention.cutoff(86_400, @now) == DateTime.add(@now, -86_400, :second)
    end
  end

  describe ":shred sweep — an expired subject-bearing row crypto-shreds its subject" do
    test "the subject on an over-TTL row is shredded via Samen.Erasure; a fresh subject survives" do
      shred_subject = "retention-subj-#{System.unique_integer([:positive])}"
      keep_subject = "retention-keep-#{System.unique_integer([:positive])}"
      {:ok, _} = Vault.store_field(shred_subject, :pii_email, :emails, "a@example.com", @repo)
      {:ok, _} = Vault.store_field(keep_subject, :pii_email, :emails, "b@example.com", @repo)

      # Model subject-bearing rows: the Company `name` carries the subject id (the
      # spec's `subject_field`). One is over TTL, one is fresh.
      _old = company_aged!(shred_subject, 400)
      _fresh = company_aged!(keep_subject, 5)

      spec = %Spec{
        resource: Company,
        ttl_seconds: 365 * 24 * 60 * 60,
        action: :shred,
        subject_field: :name
      }

      report = Retention.sweep([spec], now: @now, repo: @repo)
      assert report.swept == 1

      # The expired row's subject is crypto-shredded; the fresh row's subject is intact.
      assert Samen.Erasure.erased?(shred_subject, repo: @repo)
      refute Samen.Erasure.erased?(keep_subject, repo: @repo)
    end
  end

  describe "worker + crontab wiring" do
    test "SweepWorker reads app-config specs and returns :ok" do
      old = company_aged!("worker-stale", 400)
      Application.put_env(:samen_core, :retention_specs, [
        %{resource: Company, ttl_seconds: 365 * 24 * 60 * 60, action: :delete}
      ])

      assert :ok = Samen.Retention.SweepWorker.perform(%Oban.Job{id: 1, args: %{}})
      refute exists?(old.id)
    end

    test "an unconfigured host is a safe no-op (empty specs)" do
      Application.delete_env(:samen_core, :retention_specs)
      assert :ok = Samen.Retention.SweepWorker.perform(%Oban.Job{id: 2, args: %{}})
    end

    test "the retention sweep is on the default crontab" do
      workers = Enum.map(Samen.Jobs.default_crontab(), fn {_c, w} -> w end)
      assert Samen.Retention.SweepWorker in workers
    end
  end
end
