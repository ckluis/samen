defmodule Samen.Web.RevealApprovalsSurfaceTest do
  @moduledoc """
  PP-13 — the framework tenant reveal-APPROVER surface (`Samen.Web.Settings.RevealApprovalsLive`),
  mounted by the SAME `samen_settings_routes` macro as the other settings pages (its OWN
  LiveView — NOT `SecurityLive`, which stays read-only by RP-ST-4). Zero authored approver
  LiveViews per vertical.

  This host wires no `Samen.Approvals` engine, so the pending queue reads honest-empty here
  (the same posture SecurityLive's reveal ledger takes without `aud_chain`); the POPULATED
  approve → deny → unmask lifecycle + the masking proof are exercised on driftwood
  (`reveal_approver_live_test.exs`). Here we pin the route/mount, the role-gated render shell,
  the operator-plane read-only posture, and no vault-token leak.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Router
  alias Samen.WebTest.Operator.Membership
  alias Samen.WebTest.Operator.User

  defp seed!(org_id, role) do
    user =
      User
      |> Ash.Changeset.for_create(:create, %{
        org_id: org_id,
        handle: "approver",
        full_name: %Samen.Type.FullName{first: "Approver", last: "Person"},
        emails: [%{address: "approver@example.test"}]
      })
      |> Ash.create!(authorize?: false)

    _membership =
      Membership
      |> Ash.Changeset.for_create(:create, %{org_id: org_id, user_id: user.id, role: role})
      |> Ash.create!(authorize?: false)

    user
  end

  describe "route table + mount (framework-first)" do
    test "the settings macro mounts the reveal-approver surface at ≈0 authored LOC" do
      routes = Router.__routes__(:settings, "/settings")
      assert {"/settings/reveal-approvals", Samen.Web.Settings.RevealApprovalsLive} in routes
    end
  end

  describe "render shell + role gate" do
    test "an ADMIN sees the pending-requests panel (and no read-only role note)" do
      org_id = Ash.UUID.generate()
      user = seed!(org_id, :admin)

      html = render_live(Samen.Web.Settings.RevealApprovalsLive, build_mount(:settings), [org_id, user.id])

      assert html =~ "settings-reveal-approvals"
      assert html =~ ~s(id="reveal-approvals-table")
      # No engine wired on this host → honest empty queue.
      assert html =~ ~s(id="reveal-approvals-empty")
      # Admin can decide → the "read-only, admin required" note is absent.
      refute html =~ ~s(id="reveal-approvals-role-note")
      refute html =~ "vt_"
    end

    test "RED: a non-admin MEMBER gets a read-only view (admin role required to decide)" do
      org_id = Ash.UUID.generate()
      user = seed!(org_id, :member)

      html = render_live(Samen.Web.Settings.RevealApprovalsLive, build_mount(:settings), [org_id, user.id])

      # The member sees the honest read-only note — deciding requires an admin role.
      assert html =~ ~s(id="reveal-approvals-role-note")
      refute html =~ "vt_"
    end

    test "OPERATOR plane is read-only — an honest tenant-plane-only note, no decide affordance" do
      org_id = Ash.UUID.generate()
      user = seed!(org_id, :admin)

      html =
        render_live(
          Samen.Web.Settings.RevealApprovalsLive,
          build_mount(:settings, plane: :operator, target_org_id: org_id),
          [org_id, user.id]
        )

      assert html =~ ~s(id="reveal-approvals-operator-note")
      refute html =~ "vt_"
    end
  end
end
