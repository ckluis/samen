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
  alias Samen.Archival
  alias Samen.Retention
  alias Samen.Retention.Spec
  alias Samen.Vault

  alias SamenCore.Support.Crm.Company
  alias SamenCore.Support.Archivable.{Person, Widget}

  @repo Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Samen.Kms.FileBacked.simulate_outage(false)
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)

    on_exit(fn ->
      Application.delete_env(:samen_core, :retention_specs)
      Samen.Kms.FileBacked.simulate_outage(false)
    end)

    :ok
  end

  @now ~U[2026-07-20 12:00:00Z]

  # ── ADR-040 §5.6 helpers (E6 retention integration) ─────────────────────────

  defp tenant_scope(org_id) do
    %Samen.Scope{
      actor: %{id: "u:#{org_id}", org_id: org_id, role: :member, kind: :tenant, plane: :tenant}
    }
  end

  defp new_widget(scope, org, code) do
    Widget
    |> Ash.Changeset.for_create(:create, %{org_id: org, code: code, name: "W-#{code}"}, scope: scope)
    |> Ash.create!()
  end

  defp new_person(scope, org, first, last, email) do
    attrs =
      Map.merge(
        %{org_id: org, job_title: "Ops"},
        Samen.Factory.person(first, last, email: email)
      )

    Samen.Factory.create!(Person, attrs, scope)
  end

  defp archived_widgets(scope), do: Widget |> Ash.Query.for_read(:archived) |> Ash.read!(scope: scope)
  defp archived_people(scope), do: Person |> Ash.Query.for_read(:archived) |> Ash.read!(scope: scope)

  # Force `<table>.<col>` to `age_days` before `now` — simulates an archive that
  # happened long ago (the retention clock), mirroring `company_aged!`'s pattern for
  # `inserted_at` but on the E6 `archived_at` column (usec precision, T124).
  defp backdate!(table, id_col, col, id, age_days, now) do
    ts = DateTime.add(now, -age_days * 24 * 60 * 60, :second) |> DateTime.truncate(:microsecond)
    Repo.query!("UPDATE #{table} SET #{col} = $1 WHERE #{id_col} = $2", [ts, Ecto.UUID.dump!(id)])
  end

  defp widget_row_exists?(id) do
    %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM arv_widget WHERE arv_id = $1", [Ecto.UUID.dump!(id)])
    n > 0
  end

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

  # ── ADR-040 §5.6 — E6 retention integration + archived-count sweep (T37g) ────

  describe "archived-inclusive sweep path (§5.6)" do
    test "past-TTL archived row is swept + truly removed; in-TTL retained; live row untouched" do
      org = Ash.UUID.generate()
      scope = tenant_scope(org)

      stale = new_widget(scope, org, "ret-stale")
      fresh = new_widget(scope, org, "ret-fresh")
      never_archived = new_widget(scope, org, "ret-live")

      {:ok, _} = Archival.archive(stale, scope: scope)
      {:ok, _} = Archival.archive(fresh, scope: scope)
      # never_archived stays live: archived_at is NULL.

      # `stale` archived 400 days ago (past a 365-day window); `fresh` archived "now"
      # (within it).
      backdate!("arv_widget", "arv_id", "arv_archived_at", stale.id, 400, @now)

      spec = %Spec{
        resource: Widget,
        ttl_seconds: 365 * 24 * 60 * 60,
        action: :delete,
        timestamp_field: :archived_at
      }

      report = Retention.sweep([spec], now: @now)
      assert report.swept == 1

      # The over-TTL archived row is truly GONE — not merely hidden by the default
      # filter, not re-archived by a bare `Ash.destroy!` (which would be a no-op on
      # an already-archived row): gone even from the physical table.
      refute widget_row_exists?(stale.id)

      # The in-TTL archived row is RETAINED — still visible via :archived (trash).
      assert Enum.any?(archived_widgets(scope), &(&1.id == fresh.id))

      # A LIVE row (never archived) is untouched regardless of the same TTL — its
      # archived_at is NULL and never matches `<=` the cutoff (fail-safe by SQL
      # semantics, proven directly rather than assumed).
      assert Enum.any?(Widget |> Ash.read!(scope: scope), &(&1.id == never_archived.id))
    end

    test ":shred also reads archived-inclusive; past-TTL subject shredded, in-TTL untouched, both rows remain" do
      org = Ash.UUID.generate()
      scope = tenant_scope(org)

      old_person = new_person(scope, org, "Grace", "Hopper", "grace.hopper@sample.invalid")
      fresh_person = new_person(scope, org, "Ada", "Lovelace", "ada.lovelace@sample.invalid")

      {:ok, _} = Archival.archive(old_person, scope: scope)
      {:ok, _} = Archival.archive(fresh_person, scope: scope)

      backdate!("avf_person", "avf_id", "avf_archived_at", old_person.id, 400, @now)

      spec = %Spec{
        resource: Person,
        ttl_seconds: 365 * 24 * 60 * 60,
        action: :shred,
        timestamp_field: :archived_at,
        subject_field: :id
      }

      report = Retention.sweep([spec], now: @now, repo: @repo)
      assert report.swept == 1

      assert Samen.Erasure.erased?(old_person.id, repo: @repo)
      refute Samen.Erasure.erased?(fresh_person.id, repo: @repo)

      # :shred key-destroys, it does not delete the row (§5.1 unchanged) — both
      # rows remain visible via :archived; the archived-count is unaffected by shred.
      archived_ids = archived_people(scope) |> Enum.map(& &1.id)
      assert old_person.id in archived_ids
      assert fresh_person.id in archived_ids
      assert report.archived == 2
    end
  end

  describe "archived-count sweep report (§5.6, T37 c2)" do
    test "archived (remaining) and swept (purged) are distinct numbers; archived matches an independent :archived read" do
      org = Ash.UUID.generate()
      scope = tenant_scope(org)

      a = new_widget(scope, org, "cnt-a")
      b = new_widget(scope, org, "cnt-b")
      c = new_widget(scope, org, "cnt-c")

      {:ok, _} = Archival.archive(a, scope: scope)
      {:ok, _} = Archival.archive(b, scope: scope)
      {:ok, _} = Archival.archive(c, scope: scope)

      # a, b past a 30-day window (swept); c stays at "now" (retained).
      backdate!("arv_widget", "arv_id", "arv_archived_at", a.id, 60, @now)
      backdate!("arv_widget", "arv_id", "arv_archived_at", b.id, 60, @now)

      spec = %Spec{
        resource: Widget,
        ttl_seconds: 30 * 24 * 60 * 60,
        action: :delete,
        timestamp_field: :archived_at
      }

      report = Retention.sweep([spec], now: @now)

      assert report.swept == 2
      assert report.archived == 1
      refute report.swept == report.archived

      assert [%{resource: Widget, action: :delete, swept: 2, archived: 1}] = report.by_spec

      # Independent cross-check: a freshly-issued :archived read (not the same
      # internal call path `Retention.archived_count/2` uses) agrees with the report.
      independent_count = Widget |> Ash.Query.for_read(:archived) |> Ash.count!(scope: scope)
      assert independent_count == 1
    end

    test "archived_count/2 is decrypt-independent (INV-1) under a KMS outage; 0 for non-archivable" do
      org = Ash.UUID.generate()
      scope = tenant_scope(org)

      person = new_person(scope, org, "Ada", "Lovelace", "ada.lovelace@sample.invalid")
      {:ok, _} = Archival.archive(person, scope: scope)

      Samen.Kms.FileBacked.simulate_outage(true)

      assert Retention.archived_count(Person, authorize?: false) == 1

      # A non-archivable resource always reports 0 — nothing can be archived.
      assert Retention.archived_count(Company, authorize?: false) == 0
    end
  end

  describe "archivable_specs/2 — a catalog walk, not a hand list (§5.6)" do
    test "one spec per archivable resource in the domain, all riding timestamp_field: :archived_at" do
      specs = Retention.archivable_specs(SamenCore.Support.Archivable)

      archivable_resources =
        SamenCore.Support.Archivable
        |> Samen.Catalog.resource_modules()
        |> Enum.filter(&Samen.Info.archivable?/1)
        |> MapSet.new()

      spec_resources = specs |> Enum.map(& &1.resource) |> MapSet.new()

      assert spec_resources == archivable_resources
      assert MapSet.member?(archivable_resources, Widget)
      assert MapSet.member?(archivable_resources, Person)
      assert Enum.all?(specs, &(&1.timestamp_field == :archived_at))
      assert Enum.all?(specs, &(&1.action == :delete))
      assert Enum.all?(specs, &(&1.ttl_seconds == Retention.default_ttl_seconds().archived))
    end

    test "ttl_seconds/action are host-tunable; a domain with nothing archivable yields no specs" do
      specs =
        Retention.archivable_specs(SamenCore.Support.Archivable,
          ttl_seconds: 30 * 24 * 60 * 60,
          action: :shred
        )

      assert length(specs) == 2
      assert Enum.all?(specs, &(&1.ttl_seconds == 30 * 24 * 60 * 60))
      assert Enum.all?(specs, &(&1.action == :shred))

      # SamenCore.Support.Crm mounts only non-archivable resources (Company/Contact) —
      # proves the walk finds nothing rather than defaulting to some hand list.
      assert Retention.archivable_specs(SamenCore.Support.Crm) == []
    end
  end
end
