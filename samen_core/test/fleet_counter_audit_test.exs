defmodule Samen.Fleet.CounterAuditTest do
  @moduledoc """
  T84 — P9 (atomic `key_version`/`fleet_revision` counters) + P10 (§4.6a mode-A
  directive audit/attention mitigations), against the REAL `flt_*` tables
  (`SamenCore.Support.FleetFixture`).
  """
  use ExUnit.Case, async: false

  alias Samen.Fleet.{AdminActor, Attention, Registry}
  alias SamenCore.TestRepo

  @ns SamenCore.Support.FleetFixture
  @admin AdminActor.new("operator-1")

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})
    Attention.reset()
    :ok
  end

  defp register do
    {:ok, %{app: app}} =
      Registry.register_app(
        @ns,
        %{slug: "cnt-#{System.unique_integer([:positive])}", display_name: "Counter Co"},
        @admin
      )

    app
  end

  # ==========================================================================
  # P9 — atomic counters (advisory-locked read-max-then-insert)
  # ==========================================================================

  describe "P9 — key_version is atomic + monotonic under repeated issue/rotate" do
    test "each re-issue mints a STRICTLY increasing, unique key_version" do
      app = register()
      # register_app already minted key_version 1; rotate mints 2, 3, 4 …
      versions =
        for _ <- 1..4 do
          {:ok, %{credential: c}} = Registry.rotate_probe_credential(@ns, app.id, @admin)
          c.key_version
        end

      # strictly increasing and unique — no double-issue.
      assert versions == Enum.sort(versions)
      assert length(Enum.uniq(versions)) == length(versions)
      assert Enum.min(versions) >= 2
    end
  end

  describe "P9 — fleet_revision is atomic + monotonic" do
    test "each publish mints a STRICTLY increasing, unique fleet_revision" do
      revs =
        for i <- 1..4 do
          {:ok, d} =
            Registry.record_directive(@ns, %{target: %{app_id: "app-#{i}"}, payload: %{kill: true}}, @admin)

          d.fleet_revision
        end

      assert revs == Enum.sort(revs)
      assert length(Enum.uniq(revs)) == length(revs)
    end
  end

  # ==========================================================================
  # P10 — mode-A directive audit + forged-push attention (§4.6a)
  # ==========================================================================

  describe "P10 — every directive push is audited per app with the publishing identity" do
    test "record_directive raises a :directive_published attention carrying who/revision/target" do
      {:ok, d} =
        Registry.record_directive(@ns, %{target: %{app_id: "acme"}, payload: %{kill: true}}, @admin)

      entry = Enum.find(Attention.list(:directive_published), &(&1.key == "acme"))
      assert entry, "a directive push must be audited per app"
      assert entry.detail.published_by == "operator-1"
      assert entry.detail.fleet_revision == d.fleet_revision
      assert entry.detail.target == %{app_id: "acme"}
    end

    test "a fleet-wide push (no app_id target) audits under the \"all\" key" do
      {:ok, _} = Registry.record_directive(@ns, %{target: %{audience: :all}, payload: %{kill: true}}, @admin)
      assert Enum.any?(Attention.list(:directive_published), &(&1.key == "all"))
    end
  end

  describe "P10 — a forged push (no matching cockpit row at that revision) raises attention: :incident" do
    test "a genuine revision verifies :ok and raises NO incident; a forged revision is :forged + :incident" do
      {:ok, d} = Registry.record_directive(@ns, %{target: %{app_id: "acme"}, payload: %{kill: true}}, @admin)

      # positive control — the real revision is genuine, no incident.
      assert :ok == Registry.verify_directive_provenance(@ns, "acme", d.fleet_revision, @admin)
      refute Enum.any?(Attention.list(:incident), &(&1.detail[:fleet_revision] == d.fleet_revision))

      # a revision that was never published cockpit-side is a forged arrival — visible, not silent.
      forged_rev = d.fleet_revision + 9999
      assert {:error, :forged} == Registry.verify_directive_provenance(@ns, "acme", forged_rev, @admin)

      incident = Enum.find(Attention.list(:incident), &(&1.key == "acme"))
      assert incident, "a forged push must raise a VISIBLE incident (§4.6a), not fail silently"
      assert incident.detail.fleet_revision == forged_rev
      assert incident.detail.reason == :directive_provenance_mismatch
    end
  end
end
