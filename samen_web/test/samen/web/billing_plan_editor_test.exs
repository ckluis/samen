defmodule Samen.Web.BillingPlanEditorTest do
  @moduledoc """
  F7 unit 3 (G13) — the Billing plan + entitlement EDITOR (`Samen.Web.Billing.PlansLive`
  + the `Samen.Web.Billing.Reads` write side). Plans/Prices/Entitlements are non-PII
  Tier-0 config rows, so there is NO masking test; the load-bearing guarantee is the
  ADMIN GATE plus a FAIL-CLOSED feature-key allowlist.

    * **Governed writes (admin gate)** — the editor's `create_plan/3` / `update_plan/4`
      / `grant_entitlement/3` go through Ash with the caller's `scope`; the kernel's
      `RoleAtLeast :admin` policy holds THROUGH the surface. GREEN: an admin write scope
      (`Reads.write_scope/2`) succeeds. RED: a plain member scope (`Mount.scope/2`) is
      REFUSED — with the admin positive control (anti-tautology). The editor CANNOT
      bypass the gate: it never passes `authorize?: false`, never hand-rolls an insert.

    * **Fail-closed feature validation** — the Plan `features` attribute is a plain
      `:map` (Ash does NOT guard its keys); the editor's allowlist (`Reads.feature_keys/0`)
      is the load-bearing web seam. An unknown/forbidden feature key is REFUSED and
      NOTHING is written (create AND update). The per-subscription Entitlement `feature`
      is likewise validated (belt over the resource's `one_of` suspenders).
      Refutability proven by scripts/sabotages/26-f7-plan-editor-admin-gate-bypass.patch.

    * **Mounted editor surface** — the LiveView offers real Edit + Entitlements
      affordances and the feature-checkbox map editor; a toggle persists through the
      sanctioned update.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Billing.PlansLive
  alias Samen.Web.Billing.Reads
  alias Samen.Web.Mount

  # -- harness -------------------------------------------------------------------

  defp mount_socket(org_id, plane_opts \\ []) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, build_mount(:billing, plane_opts))
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> Phoenix.Component.assign(:return_to, nil)
    |> PlansLive.load(org_id)
  end

  defp html(socket), do: render_html(PlansLive, socket.assigns)

  defp event(socket, name, params) do
    {:noreply, socket} = PlansLive.handle_event(name, params, socket)
    socket
  end

  defp admin_scope(mount, org_id), do: Reads.write_scope(mount, org_id)
  defp member_scope(mount, org_id), do: Mount.scope(mount, org_id)

  defp plan_count(org_id) do
    Samen.WebTest.Billing.Plan
    |> Ash.Query.ensure_selected([:org_id])
    |> Ash.read!(authorize?: false)
    |> Enum.count(&(&1.org_id == org_id))
  end

  defp ent_count(org_id) do
    Samen.WebTest.Billing.Entitlement
    |> Ash.Query.ensure_selected([:org_id])
    |> Ash.read!(authorize?: false)
    |> Enum.count(&(&1.org_id == org_id))
  end

  # ===========================================================================
  # Governed writes — the admin gate holds THROUGH the editor (green + red)
  # ===========================================================================

  test "GREEN: an ADMIN write scope creates a plan through the editor read/write layer" do
    org_id = Ash.UUID.generate()
    mount = build_mount(:billing)

    assert {:ok, plan} =
             Reads.create_plan(mount, admin_scope(mount, org_id), %{
               "org_id" => org_id,
               "name" => "pro",
               "label" => "Pro",
               "interval" => "monthly",
               "features" => %{"api_access" => true, "advanced_reporting" => true}
             })

    assert plan.name == "pro"
    assert Map.has_key?(plan.features, "api_access") or Map.has_key?(plan.features, :api_access)
    assert plan_count(org_id) == 1
  end

  test "RED: a MEMBER scope is REFUSED create_plan (admin gate holds); admin positive control succeeds" do
    org_id = Ash.UUID.generate()
    mount = build_mount(:billing)
    attrs = %{"org_id" => org_id, "name" => "pro", "interval" => "monthly"}

    # RED — the RoleAtLeast :admin gate refuses the non-admin caller.
    assert {:error, _reason} = Reads.create_plan(mount, member_scope(mount, org_id), attrs)
    assert plan_count(org_id) == 0

    # Positive control (anti-tautology): the SAME op succeeds for the admin scope.
    assert {:ok, _plan} = Reads.create_plan(mount, admin_scope(mount, org_id), attrs)
    assert plan_count(org_id) == 1
  end

  test "GREEN: an ADMIN scope edits a plan's fields + features map through update_plan" do
    org_id = Ash.UUID.generate()
    mount = build_mount(:billing)
    {:ok, plan} = Reads.create_plan(mount, admin_scope(mount, org_id), %{"org_id" => org_id, "name" => "basic"})

    assert {:ok, updated} =
             Reads.update_plan(mount, admin_scope(mount, org_id), plan.id, %{
               "label" => "Basic Tier",
               "features" => %{"sso" => true}
             })

    assert updated.label == "Basic Tier"
    features = Map.new(updated.features, fn {k, v} -> {to_string(k), v} end)
    assert features == %{"sso" => true}
  end

  test "RED: a MEMBER scope is REFUSED update_plan; admin positive control succeeds" do
    org_id = Ash.UUID.generate()
    mount = build_mount(:billing)
    {:ok, plan} = Reads.create_plan(mount, admin_scope(mount, org_id), %{"org_id" => org_id, "name" => "basic"})

    assert {:error, _reason} = Reads.update_plan(mount, member_scope(mount, org_id), plan.id, %{"label" => "Hijacked"})
    raw = Ash.get!(Samen.WebTest.Billing.Plan, plan.id, authorize?: false)
    refute raw.label == "Hijacked"

    assert {:ok, _} = Reads.update_plan(mount, admin_scope(mount, org_id), plan.id, %{"label" => "Legit"})
    raw = Ash.get!(Samen.WebTest.Billing.Plan, plan.id, authorize?: false)
    assert raw.label == "Legit"
  end

  # ===========================================================================
  # Fail-closed feature-key validation (the load-bearing NEW web seam)
  # ===========================================================================

  test "FAIL-CLOSED: an unknown feature key in a plan's features map is REFUSED on create (nothing written)" do
    org_id = Ash.UUID.generate()
    mount = build_mount(:billing)

    # Admin scope — this is the FEATURE gate, not the role gate.
    assert {:error, {:invalid_feature, "totally_bogus"}} =
             Reads.create_plan(mount, admin_scope(mount, org_id), %{
               "org_id" => org_id,
               "name" => "sneaky",
               "features" => %{"totally_bogus" => true}
             })

    assert plan_count(org_id) == 0
  end

  test "FAIL-CLOSED: an unknown feature key is REFUSED on update (plan left untouched)" do
    org_id = Ash.UUID.generate()
    mount = build_mount(:billing)
    {:ok, plan} = Reads.create_plan(mount, admin_scope(mount, org_id), %{"org_id" => org_id, "name" => "clean"})

    assert {:error, {:invalid_feature, "arbitrary_key"}} =
             Reads.update_plan(mount, admin_scope(mount, org_id), plan.id, %{"features" => %{"arbitrary_key" => true}})

    raw = Ash.get!(Samen.WebTest.Billing.Plan, plan.id, authorize?: false)
    assert raw.features in [nil, %{}]
  end

  test "a VALID feature key from the allowlist is accepted (positive control for the gate)" do
    org_id = Ash.UUID.generate()
    mount = build_mount(:billing)

    assert {:ok, _plan} =
             Reads.create_plan(mount, admin_scope(mount, org_id), %{
               "org_id" => org_id,
               "name" => "ok",
               "features" => %{"audit_log" => true}
             })

    assert plan_count(org_id) == 1
  end

  # ===========================================================================
  # Entitlements — grant / revoke through the admin-gated sanctioned actions
  # ===========================================================================

  test "GREEN: an ADMIN grants a bounded entitlement on a subscription; revoke flips granted" do
    %{org_id: org_id, billing: %{subscription: sub}} = Seeds.seed_all()
    mount = build_mount(:billing)

    assert {:ok, ent} =
             Reads.grant_entitlement(mount, admin_scope(mount, org_id), %{
               "org_id" => org_id,
               "subscription_id" => sub.id,
               "feature" => "advanced_reporting"
             })

    assert ent.feature == :advanced_reporting
    assert ent.granted

    granted =
      Reads.entitlements(mount, member_scope(mount, org_id))
      |> Enum.find(&(&1.subscription_id == sub.id and &1.feature == :advanced_reporting))

    assert granted.granted

    # Revoke flips the SAME row (idempotent per subscription+feature) — sanctioned update.
    assert {:ok, revoked} =
             Reads.revoke_entitlement(mount, admin_scope(mount, org_id), %{
               "subscription_id" => sub.id,
               "feature" => "advanced_reporting"
             })

    refute revoked.granted
  end

  test "RED: a MEMBER scope is REFUSED grant_entitlement; admin positive control succeeds" do
    %{org_id: org_id, billing: %{subscription: sub}} = Seeds.seed_all()
    mount = build_mount(:billing)
    before = ent_count(org_id)

    attrs = %{"org_id" => org_id, "subscription_id" => sub.id, "feature" => "sso"}

    assert {:error, _reason} = Reads.grant_entitlement(mount, member_scope(mount, org_id), attrs)
    assert ent_count(org_id) == before

    assert {:ok, _ent} = Reads.grant_entitlement(mount, admin_scope(mount, org_id), attrs)
    assert ent_count(org_id) == before + 1
  end

  test "FAIL-CLOSED: grant_entitlement with an out-of-set feature is REFUSED (no row written)" do
    %{org_id: org_id, billing: %{subscription: sub}} = Seeds.seed_all()
    mount = build_mount(:billing)
    before = ent_count(org_id)

    assert {:error, {:invalid_feature, "not_a_feature"}} =
             Reads.grant_entitlement(mount, admin_scope(mount, org_id), %{
               "org_id" => org_id,
               "subscription_id" => sub.id,
               "feature" => "not_a_feature"
             })

    assert ent_count(org_id) == before
  end

  # ===========================================================================
  # Mounted editor surface — real affordances + the feature-map checkbox editor
  # ===========================================================================

  test "the editor offers Edit + Entitlements affordances; the edit modal renders the feature-map checkboxes" do
    %{org_id: org_id} = Seeds.seed_all()
    socket = mount_socket(org_id)

    rendered = html(socket)
    assert rendered =~ ~s(phx-click="edit_plan")
    assert rendered =~ ~s(id="manage-entitlements")

    # Open the edit modal on the seeded plan.
    plan = Enum.find(socket.assigns.page.items, &(&1.name == "growth"))
    socket = event(socket, "edit_plan", %{"id" => plan.id})
    rendered = html(socket)
    assert rendered =~ ~s(id="edit-plan-form")
    assert rendered =~ ~s(phx-click="toggle_feature")
    assert rendered =~ ~s(data-feature="api_access")
  end

  test "toggling a feature checkbox persists the bounded key into the plan's features map" do
    %{org_id: org_id} = Seeds.seed_all()
    socket = mount_socket(org_id)
    plan = Enum.find(socket.assigns.page.items, &(&1.name == "growth"))

    socket = event(socket, "toggle_feature", %{"id" => plan.id, "feature" => "priority_support"})

    raw = Ash.get!(Samen.WebTest.Billing.Plan, plan.id, authorize?: false)
    features = Map.new(raw.features || %{}, fn {k, v} -> {to_string(k), v} end)
    assert features["priority_support"] == true

    # The modal stays open on the edited plan.
    assert socket.assigns.show_edit
    assert socket.assigns.edit_plan_id == plan.id
  end

  test "OPERATOR plane: no editor write affordance in the DOM" do
    %{org_id: org_id} = Seeds.seed_all()
    socket = mount_socket(org_id, plane: :operator, target_org_id: org_id)

    rendered = html(socket)
    refute rendered =~ ~s(phx-click="edit_plan")
    refute rendered =~ ~s(id="manage-entitlements")
    refute rendered =~ ~s(phx-click="toggle_feature")
  end
end
