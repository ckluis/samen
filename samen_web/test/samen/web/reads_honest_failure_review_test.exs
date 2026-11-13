defmodule Samen.Web.ReadsHonestFailureReviewTest do
  @moduledoc """
  Review follow-ups to `ReadsHonestFailureP2Test`: a REAL data-layer failure (a table that is gone,
  not the `inject_read_faults` seam) must reach the screen as outage copy and never as denial copy;
  a real denial must keep its denial copy; and client-chosen malformed ids are "not found", not an
  error log and not an outage.

  Postgres DDL is transactional, so renaming a table inside the sandbox transaction is a faithful
  and self-undoing outage.
  """
  use Samen.WebTest.DataCase, async: false

  import ExUnit.CaptureLog

  alias Samen.Web.Mount

  setup do
    seeded = Seeds.seed_all()
    %{org_id: seeded.org_id, person_id: seeded.crm.person.id}
  end

  defp break_table!(resource) do
    table = AshPostgres.DataLayer.Info.table(resource)
    Ecto.Adapters.SQL.query!(Samen.WebTest.Repo, "ALTER TABLE #{table} RENAME TO zz_gone_#{table}")
  end

  defp admin_scope(org_id, role \\ :admin),
    do: %Samen.Scope{actor: %{id: Ash.UUID.generate(), org_id: org_id, role: role, kind: :tenant, plane: :tenant, verified?: true}}

  # ===========================================================================
  # N1 — a malformed client id is "not found"
  # ===========================================================================

  describe "N1 — malformed ids" do
    alias Samen.Web.Notifications.Reads
    alias Samen.Web.ObjectRef

    test "mark_read with a non-UUID id is :not_found, logs nothing; a real id still marks read", %{org_id: org_id} do
      mount = build_mount(:notifications)
      scope = Mount.scope(mount, org_id)

      {:ok, notification} =
        Samen.Notifications.Engine.notify(
          %{org_id: org_id, recipient_id: Ash.UUID.generate(), event_type: "crm.person.flagged", channel: :in_app, rendered_body: "n1"},
          notification_module: Samen.WebTest.Primitives.Notification,
          preference_module: Samen.WebTest.Primitives.NotificationPreference,
          repo: Samen.WebTest.Repo
        )

      log =
        capture_log(fn ->
          assert {:error, :not_found} = Reads.mark_read(mount, scope, "not-a-uuid")
          assert {:error, :not_found} = Reads.mark_read(mount, scope, "")
        end)

      assert log == ""

      # POSITIVE CONTROL: the same call with the real id works (so the :not_found above is the cast).
      assert :ok = Reads.mark_read(mount, scope, notification.id)
    end

    test "ObjectRef.resolve with a non-UUID id is :not_found (an inert chip), never :unavailable or an error log",
         %{org_id: org_id, person_id: person_id} do
      mount = build_mount(:crm)
      scope = Mount.scope(mount, org_id)

      log =
        capture_log(fn ->
          assert {:error, :not_found} = ObjectRef.resolve(mount, scope, %ObjectRef{key: "crm.person", id: "not-a-uuid", raw: "x"})
        end)

      assert log == ""

      # POSITIVE CONTROL: a real id resolves; a genuine failure is still :unavailable.
      ref = %ObjectRef{key: "crm.person", id: person_id, raw: "x"}
      assert {:ok, _card} = ObjectRef.resolve(mount, scope, ref)
      inject_read_faults([:object_ref_load])
      {result, _log} = with_log(fn -> ObjectRef.resolve(mount, scope, ref) end)
      assert result == {:error, :unavailable}
    end
  end

  # ===========================================================================
  # N2 / S1 — flags: denial copy for a denial, outage copy for an outage
  # ===========================================================================

  describe "N2 — flags write copy" do
    alias Samen.Web.Flags.Reads
    alias Samen.WebTest.Primitives.FeatureFlag

    defp seed_flag!(org_id) do
      FeatureFlag
      |> Ash.Changeset.for_create(:create, %{org_id: org_id, name: "review.flag", enabled: true, rollout_pct: 100}, authorize?: false)
      |> Ash.create!()
    end

    test "a member (not admin) toggling a flag is a DENIAL: denial copy, flag unchanged" do
      org_id = Ash.UUID.generate()
      flag = seed_flag!(org_id)
      mount = build_mount(:flags)

      assert {:error, copy} = Reads.toggle_flag(mount, admin_scope(org_id, :member), flag.id)
      assert copy =~ "don't have permission"
      refute copy =~ "couldn't save"
      assert Ash.get!(FeatureFlag, flag.id, authorize?: false).enabled

      # POSITIVE CONTROL: the admin's identical call goes through.
      assert {:ok, _} = Reads.toggle_flag(mount, admin_scope(org_id, :admin), flag.id)
      refute Ash.get!(FeatureFlag, flag.id, authorize?: false).enabled
    end

    test "a REAL outage (the table is gone) is outage copy, never denial copy" do
      org_id = Ash.UUID.generate()
      flag = seed_flag!(org_id)
      mount = build_mount(:flags)
      break_table!(FeatureFlag)

      {result, log} = with_log(fn -> Reads.toggle_flag(mount, admin_scope(org_id), flag.id) end)
      assert {:error, copy} = result
      assert copy =~ "couldn't save this flag change right now"
      refute copy =~ "permission"
      assert log =~ "failed"
      refute log =~ "zz_gone"
    end
  end
end
