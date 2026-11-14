defmodule Samen.HonestKernelReadsTest do
  @moduledoc """
  The kernel's honest-reads conversions (security slice): a probe, read or audit write that FAILED is never
  reported as "absent", "empty", "clear" or "done". Each case fails a real call with a real
  `DBConnection.ConnectionError` (`Samen.FaultRepo`), asserts the honest tagged answer, and pairs it with a
  positive control through the same module so the assertion cannot be a tautology.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Samen.AuditChain.Writer
  alias Samen.FaultRepo
  alias Samen.OperatorPlane.Suspension
  alias SamenCore.TestRepo, as: Repo

  setup do
    Samen.TestSandbox.shared!(Repo)
    on_exit(&FaultRepo.heal/0)
    {:ok, org: "org-#{System.unique_integer([:positive])}"}
  end

  defp attrs(org),
    do: %{org_id: org, event_type: "impersonation", subject_id: org, actor_id: "op-9", detail: "event=open"}

  describe "AuditChain.Writer — a failed aud_chain existence probe is not 'chain absent'" do
    test "RED: the probe fails -> the write fails (no silent chainless audit event), reported by name", %{org: org} do
      FaultRepo.fail([:probe])

      log =
        capture_log(fn ->
          assert {:error, :audit_chain_unavailable} = Writer.write(FaultRepo, attrs(org))
        end)

      assert log =~ "read=audit_chain_probe"
      assert log =~ "cause=DBConnection.ConnectionError"
    end

    test "POSITIVE CONTROL: the same repo with the probe healthy lands event + chain entry", %{org: org} do
      assert {:ok, %{aud_event: _, chain: %Samen.AuditChain.Entry{}}} = Writer.write(FaultRepo, attrs(org))
    end

    test "an ABSENT table is still the documented graceful skip (the probe answered 'no')", %{org: org} do
      defmodule AbsentRepo do
        def query!("SELECT to_regclass" <> _), do: %{rows: [[nil]]}
        def insert(cs, opts \\ []), do: SamenCore.TestRepo.insert(cs, opts)
        def in_transaction?, do: SamenCore.TestRepo.in_transaction?()
        def transaction(fun, opts \\ []), do: SamenCore.TestRepo.transaction(fun, opts)
        def rollback(v), do: SamenCore.TestRepo.rollback(v)
      end

      assert {:ok, %{chain: :skipped}} = Writer.write(AbsentRepo, attrs(org))
    end
  end

  describe "Suspension — a failed audit write or lookup is not 'suspended and audited' / 'nothing to clear'" do
    test "RED: suspend with the audit probe down fails to audit: the suspension STANDS and the audit is pending, never written as done",
         %{org: org} do
      op = "op-#{System.unique_integer([:positive])}"
      path = Path.join(System.tmp_dir!(), "hk_susp_#{System.unique_integer([:positive])}.local")
      on_exit(fn -> File.rm_rf!(path) end)
      FaultRepo.fail([:probe])

      capture_log(fn ->
        assert {:ok, %{audit: :pending}} =
                 Suspension.suspend(%{operator_id: op, reason: "r", org_id: org, repo: FaultRepo, local_audit_path: path})
      end)

      FaultRepo.heal()
      # suspending removes privilege: it stands, and the missing chain entry is parked locally for the reconciler
      assert {:ok, true} = Suspension.status(op, repo: Repo)
      assert Samen.BreakGlass.LocalAudit.count(path: path) == 1
    end

    test "POSITIVE CONTROL: with the audit healthy the suspension lands, is audited, and clears", %{org: org} do
      op = "op-#{System.unique_integer([:positive])}"
      assert {:ok, %{operator_id: ^op}} = Suspension.suspend(%{operator_id: op, reason: "r", org_id: org, repo: FaultRepo})
      assert {:ok, true} = Suspension.status(op, repo: Repo)
      # the audit entry actually landed on the org's chain (a non-UUID operator id used to make it raise, silently)
      assert {:ok, %{entries: 1}} = Samen.AuditChain.verify_chain(org, repo: Repo)
      assert {:ok, _} = Suspension.clear(op, %{repo: FaultRepo, org_id: org})
      assert {:ok, false} = Suspension.status(op, repo: Repo)
      assert {:ok, %{entries: 2}} = Samen.AuditChain.verify_chain(org, repo: Repo)
    end

    test "RED: clear with the lookup down is an error, not {:ok, :not_suspended}", %{org: org} do
      op = "op-#{System.unique_integer([:positive])}"
      assert {:ok, _} = Suspension.suspend(%{operator_id: op, reason: "r", org_id: org, repo: Repo})

      FaultRepo.fail([:one])

      log =
        capture_log(fn ->
          assert {:error, :unavailable} = Suspension.clear(op, %{repo: FaultRepo, org_id: org})
        end)

      assert log =~ "read=suspension_active_row"
      FaultRepo.heal()
      # still suspended: the failed clear did not pretend to clear
      assert {:ok, true} = Suspension.status(op, repo: Repo)
    end

    test "RED: clear with the audit probe down keeps the operator suspended (the clear is rolled back)", %{org: org} do
      op = "op-#{System.unique_integer([:positive])}"
      assert {:ok, _} = Suspension.suspend(%{operator_id: op, reason: "r", org_id: org, repo: Repo})

      FaultRepo.fail([:probe])

      capture_log(fn ->
        assert {:error, :audit_unavailable} = Suspension.clear(op, %{repo: FaultRepo, org_id: org})
      end)

      FaultRepo.heal()
      assert {:ok, true} = Suspension.status(op, repo: Repo)
    end
  end

  describe "Vault.scan_pitr_key_absent — a failed column probe does not prove the key absent" do
    test "RED: the key-column probe fails -> {:leaks, _} naming the failed probe (was {:ok, :key_absent})" do
      FaultRepo.fail([{:sql, "information_schema.columns"}])

      log =
        capture_log(fn ->
          assert {:leaks, [msg]} = Samen.Vault.scan_pitr_key_absent("subject-1", FaultRepo)
          assert msg =~ "probe FAILED"
        end)

      assert log =~ "read=vault_key_column_probe"
    end

    test "POSITIVE CONTROL: the same call with a healthy probe proves the key absent" do
      assert {:ok, :key_absent} = Samen.Vault.scan_pitr_key_absent("subject-1", FaultRepo)
    end
  end

  describe "NoPlaintextPii oban_jobs tier — an unreadable table or row set is a violation, not a clean scan" do
    alias Samen.NoPlaintextPii.Context
    alias Samen.NoPlaintextPii.Tiers.ObanJobs

    defp ctx(repo, subject_id \\ nil),
      do: %Context{repo: repo, resources: [], vault_routed: MapSet.new(), non_pii_exempt: MapSet.new(), deps: [], subject_id: subject_id}

    defp violations(findings), do: Enum.filter(findings, &(&1.severity == :violation))

    test "RED: the table-existence probe fails -> a violation (was `false` -> 'Oban not wired' -> pass)" do
      FaultRepo.fail([{:sql, "information_schema.tables"}])

      capture_log(fn ->
        assert [%{severity: :violation, detail: msg}] = ObanJobs.check(ctx(FaultRepo))
        assert msg =~ "could not determine whether oban_jobs exists"
      end)
    end

    test "RED: the recent-jobs scan fails -> a violation per queue (was [] -> clean)" do
      FaultRepo.fail([{:sql, "FROM oban_jobs WHERE queue"}])

      capture_log(fn ->
        viols = violations(ObanJobs.check(ctx(FaultRepo)))
        assert viols != []
        assert Enum.all?(viols, &(&1.detail =~ "could not read the recent jobs"))
      end)
    end

    test "RED: the post-shred subject scan fails -> a violation (was [] -> 'no job references the subject')" do
      FaultRepo.fail([{:sql, "args::text LIKE"}])

      capture_log(fn ->
        viols = violations(ObanJobs.check(ctx(FaultRepo, "subject-1")))
        assert Enum.any?(viols, &(&1.detail =~ "could not read the oban_jobs rows that reference subject subject-1"))
      end)
    end

    test "POSITIVE CONTROL: the same checks through the same module are clean when every probe answers" do
      assert violations(ObanJobs.check(ctx(FaultRepo))) == []
      assert violations(ObanJobs.check(ctx(FaultRepo, "subject-1"))) == []
    end
  end

  describe "NoPlaintextPii log_telemetry tier — an unlistable handler set is a violation, not 'no handlers'" do
    test "RED: listing the :telemetry handlers fails -> a live-handler violation" do
      Application.put_env(:samen_core, :telemetry_handler_lister, fn _prefix -> raise "telemetry table gone" end)
      on_exit(fn -> Application.delete_env(:samen_core, :telemetry_handler_lister) end)
      prev = Application.get_env(:samen_core, :opentelemetry_ecto)
      Application.put_env(:samen_core, :opentelemetry_ecto, db_statement: :disabled)
      on_exit(fn -> if prev, do: Application.put_env(:samen_core, :opentelemetry_ecto, prev), else: Application.delete_env(:samen_core, :opentelemetry_ecto) end)

      ctx = %Samen.NoPlaintextPii.Context{repo: Repo, resources: [], vault_routed: MapSet.new(), non_pii_exempt: MapSet.new(), deps: [:opentelemetry_ecto]}

      capture_log(fn ->
        findings = Samen.NoPlaintextPii.Tiers.LogTelemetry.check(ctx)
        assert [%{severity: :violation, subject: subject}] = Enum.filter(findings, &(&1.severity == :violation))
        assert subject =~ "live handlers"
      end)
    end

    test "POSITIVE CONTROL: with the real lister and a :disabled config there is no violation" do
      prev = Application.get_env(:samen_core, :opentelemetry_ecto)
      Application.put_env(:samen_core, :opentelemetry_ecto, db_statement: :disabled)
      on_exit(fn -> if prev, do: Application.put_env(:samen_core, :opentelemetry_ecto, prev), else: Application.delete_env(:samen_core, :opentelemetry_ecto) end)
      ctx = %Samen.NoPlaintextPii.Context{repo: Repo, resources: [], vault_routed: MapSet.new(), non_pii_exempt: MapSet.new(), deps: [:opentelemetry_ecto]}
      assert Enum.filter(Samen.NoPlaintextPii.Tiers.LogTelemetry.check(ctx), &(&1.severity == :violation)) == []
    end
  end

  describe "Erasure.Completeness — a module whose PII cannot be introspected fails the check, it does not drop out" do
    # Three stub "resources" (modules the Spark/Ash introspection can half-read), so EACH un-rescued function is
    # reached on its own: `discover(resources: [String])` raises from whichever runs first, so re-adding a rescue
    # to only one of the later functions would flip nothing.
    defmodule AttributesUnreadable do
      @moduledoc false
      def entities(_path), do: raise(ArgumentError, "attributes unreadable")
      def persisted(_key, default), do: default
    end

    defmodule PersistedUnreadable do
      @moduledoc false
      # attributes read fine (none), but `Ash.Resource.Info.attribute/2` cannot read the persisted lookup
      def entities(_path), do: []
    end

    defmodule PiiUnreadable do
      @moduledoc false
      # attributes and persisted lookups read fine; the PII declarations do not
      def entities([:pii]), do: raise(ArgumentError, "pii unreadable")
      def entities(_path), do: []
      def persisted(_key, default), do: default
    end

    defmodule NothingToErase do
      @moduledoc false
      def entities(_path), do: []
      def persisted(_key, default), do: default
    end

    test "RED: DerivedLinkable.discover over a module whose attributes cannot be read raises (was silently 'nothing to erase')" do
      assert_raise ArgumentError, fn -> Samen.DerivedLinkable.discover([AttributesUnreadable]) end
    end

    test "RED: Completeness attribute lookup over a module it cannot introspect raises (was nil -> 'no storage_key')" do
      assert_raise ArgumentError, fn -> Samen.Erasure.Completeness.discover(resources: [PersistedUnreadable]) end
    end

    test "RED: Completeness PII-field lookup over a module whose declarations cannot be read raises (was [] -> 'no transcript')" do
      assert_raise ArgumentError, fn -> Samen.Erasure.Completeness.discover(resources: [PiiUnreadable]) end
    end

    test "POSITIVE CONTROL: the same stubs, when readable, discover nothing and do not raise" do
      assert [] = Samen.DerivedLinkable.discover([NothingToErase])
      assert %{storage_key: [], custom_bag: [], transcript: []} = Samen.Erasure.Completeness.discover(resources: [NothingToErase])
    end

    test "POSITIVE CONTROL: discovery over real resources still answers" do
      assert %{storage_key: _, custom_bag: _, transcript: _} = Samen.Erasure.Completeness.discover()
    end
  end

  describe "BreakGlass.Reconciliation — an unreadable anchor count alarms, it does not read as zero residue" do
    test "the failure is reported by name (the count stays on the alarm side)" do
      path = Path.join(System.tmp_dir!(), "hk_recon_#{System.unique_integer([:positive])}.local")
      on_exit(fn -> File.rm_rf!(path) end)

      for n <- 1..2 do
        {:ok, _} =
          Samen.BreakGlass.LocalAudit.append(
            %{org_id: Ecto.UUID.generate(), subject_id: "s#{n}", actor_id: "a", reason: "r"},
            path: path
          )
      end

      # positive control: with the anchor table readable, none anchored -> both entries are unanchored
      assert Samen.BreakGlass.Reconciliation.unanchored_count(repo: Repo, path: path) == 2

      FaultRepo.fail([:one])

      log =
        capture_log(fn ->
          # local entries (2) minus anchored (unreadable -> 0): the alarm direction, exactly the local count
          assert Samen.BreakGlass.Reconciliation.unanchored_count(repo: FaultRepo, path: path) == 2
        end)

      assert log =~ "read=break_glass_anchored_count"
    end
  end

  describe "PII-declaration introspection — a module that cannot be introspected is not 'declares no PII'" do
    alias SamenCore.Support.AutomationFixture.Subject

    test "RED: SearchIndexGuard refuses to register a column of a module whose PII it cannot read (was :ok)" do
      assert catch_error(Samen.Scopes.Primitives.SearchIndexGuard.assert_no_pii_column(String, "length"))
      assert catch_error(Samen.Scopes.Primitives.SearchIndexGuard.get_pii_fields(String))
    end

    test "POSITIVE CONTROL: the guard still refuses a declared PII column and passes a non-PII one" do
      guard = Samen.Scopes.Primitives.SearchIndexGuard
      assert :email in guard.get_pii_fields(Subject)
      assert_raise ArgumentError, ~r/declared as a pii_attribute/, fn -> guard.assert_no_pii_column(Subject, "email") end
      assert :ok = guard.assert_no_pii_column(Subject, "id")
    end

    test "RED: PiiReads.Registry over a non-resource (or a non-domain) raises instead of building an empty registry" do
      assert catch_error(Samen.PiiReads.Registry.build(resources: [String]))
      assert catch_error(Samen.PiiReads.Registry.build(domains: [String]))
    end

    test "POSITIVE CONTROL: the registry over a real PII resource knows its PII attribute" do
      reg = Samen.PiiReads.Registry.build(resources: [Subject])
      assert Samen.PiiReads.Registry.pii_attribute?(reg, :email)
    end
  end

  describe "closed-silent security sites now report by name (value-free) while keeping their closed answer" do
    test "Fleet.Resolution.scope_of: a raising resolver is :none (no access) AND on record" do
      Application.put_env(:honest_probe_app, :fleet_resolution, {HonestProbe.Nope, :nope, []})
      on_exit(fn -> Application.delete_env(:honest_probe_app, :fleet_resolution) end)

      log = capture_log(fn -> assert :none = Samen.Fleet.Resolution.scope_of(:honest_probe_app, "principal-1") end)
      assert log =~ "read failed read=resolution_scope_of"
      assert log =~ "cause=UndefinedFunctionError"
      refute log =~ "principal-1"
    end

    test "Fleet.Authz.roles_for: a raising authority yields no roles AND is on record" do
      Application.put_env(:honest_probe_app, :fleet_authority, {HonestProbe.Nope, :nope, []})
      on_exit(fn -> Application.delete_env(:honest_probe_app, :fleet_authority) end)

      log = capture_log(fn -> assert %{} == Samen.Fleet.Authz.roles_for(:honest_probe_app, "principal-1") end)
      assert log =~ "read failed read=authz_roles_for"
    end
  end
end
