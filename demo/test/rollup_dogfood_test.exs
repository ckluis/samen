defmodule Demo.RollupDogfoodTest do
  @moduledoc """
  T2.3 demo dogfood: the demo app runs the rollup framework end-to-end, exercises
  rebuild-or-exclude-on-erasure through `Samen.Erasure.shred/2`, and passes the
  `no_plaintext_pii` Rollup oracle tier on the real demo `rol_daily_event_count`
  table.

  RED PATH (dogfood): a rollup computed PRE-shred must not resurrect the erased
  subject after shred (rebuild arm) — the same guarantee the kernel suite proves,
  demonstrated against the demo's own repo + config-registered rollup.

  SUPPRESS arm uses the documented simulation seam (`raw_retained?: false`) since
  this environment has no detached partition.
  """
  use ExUnit.Case, async: false

  alias Demo.Repo
  alias Samen.Rollup
  alias Samen.AuditEvent
  alias Samen.Erasure
  alias Samen.Vault
  alias Samen.NoPlaintextPii

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    Samen.Kms.FileBacked.simulate_outage(false)
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
    :ok
  end

  defp seed_events(subject_id, org_id, n) do
    for i <- 1..n do
      {:ok, _} =
        AuditEvent.insert(Repo, %{
          event_type: "system",
          subject_id: subject_id,
          correlation_id: org_id,
          detail: "evt-#{i}",
          occurred_at: DateTime.new!(~D[2026-07-04], ~T[12:00:00.000000], "Etc/UTC")
        })
    end
  end

  defp rollup_row(subject_id) do
    %{rows: rows} =
      Repo.query!(
        "SELECT rol_event_count, rol_suppressed FROM rol_daily_event_count WHERE rol_subject_id::text = $1",
        [subject_id]
      )

    case rows do
      [[count, suppressed]] -> %{count: count, suppressed: suppressed}
      [] -> nil
    end
  end

  test "the demo registers the daily_event_count rollup" do
    assert Enum.any?(Rollup.specs(), &(&1.name == :daily_event_count))
  end

  test "rebuild_all materialises the rollup; dashboards read the summary" do
    subject_id = Ecto.UUID.generate()
    seed_events(subject_id, Ecto.UUID.generate(), 4)

    {:ok, results} = Rollup.rebuild_all(Repo)
    assert results[:daily_event_count] >= 1
    assert %{count: 4, suppressed: false} = rollup_row(subject_id)
  end

  test "RED PATH: pre-shred rollup does not resurrect the subject (rebuild arm)" do
    subject_id = Ecto.UUID.generate()
    {:ok, _} = Vault.store_field(subject_id, :pii_email, :emails, "gone@demo.test", Repo)
    seed_events(subject_id, Ecto.UUID.generate(), 5)

    {:ok, _} = Rollup.rebuild_all(Repo)
    assert %{count: 5} = rollup_row(subject_id)

    assert {:ok, %{report: report}} = Erasure.shred(subject_id, repo: Repo)

    assert rollup_row(subject_id) == nil,
           "erased subject must not survive in the demo rollup after shred"

    entry = Enum.find(report.tiers["rollups"], &(&1["rollup"] == "daily_event_count"))
    assert entry["arm"] == "rebuild"
  end

  test "SUPPRESS arm (simulated archived window) flags the derived row" do
    subject_id = Ecto.UUID.generate()
    {:ok, _} = Vault.store_field(subject_id, :pii_email, :emails, "arch@demo.test", Repo)
    seed_events(subject_id, Ecto.UUID.generate(), 3)
    {:ok, _} = Rollup.rebuild_all(Repo)

    assert {:ok, %{report: report}} = Erasure.shred(subject_id, repo: Repo, raw_retained?: false)

    assert %{count: 3, suppressed: true} = rollup_row(subject_id)
    entry = Enum.find(report.tiers["rollups"], &(&1["rollup"] == "daily_event_count"))
    assert entry["arm"] == "suppress"
  end

  test "the demo rollup table passes the no_plaintext_pii Rollup oracle tier" do
    resources = [Demo.Crm.Org, Demo.Crm.Membership, Demo.Crm.Contact]

    {:ok, findings} = NoPlaintextPii.run(resources: resources, repo: Repo, deps: [])
    violations = NoPlaintextPii.violations(findings)

    assert violations == [],
           "demo rollup must pass the oracle tier: #{inspect(violations)}"
  end
end
