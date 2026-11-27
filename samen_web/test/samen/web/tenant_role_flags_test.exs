defmodule Samen.Web.TenantRoleFlagsTest do
  @moduledoc """
  ADR-045 §4.4 residual (the `:member` default), the feature-flags settings page: it acts with the role the signed-in person's
  ACTIVE membership resolves to (`Samen.Web.TenantActor`), never `Plane.scope/2`'s fixed `:member`, and every write runs as
  that person.

  Driven with a REAL spine login (`POST /login`) and the REAL tenant gate (`Samen.WebTest.RoleHarness`); every refusal is
  paired with a positive control.

  Role choice: reading the flags is open to every active member; every flag write (enable or disable, ramp, add or remove a
  targeting rule) is an admin's. The kernel already says so (`FeatureFlag` writes are `RoleAtLeast :admin`); the page checks it
  itself and offers the controls to an admin only.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Flags.SettingsLive
  alias Samen.WebTest.Primitives.FeatureFlag
  alias Samen.WebTest.RoleHarness, as: H
  alias Samen.WebTest.SpineAccounts

  @path "/flags"

  setup do
    ctx = H.setup_accounts()

    flag =
      FeatureFlag
      |> Ash.Changeset.for_create(:create, %{org_id: ctx.org_id, name: "zebra.flag", enabled: true, rollout_pct: 100}, authorize?: false)
      |> Ash.create!()

    Map.put(ctx, :flag, flag)
  end

  defp html(socket), do: render_html(SettingsLive, socket.assigns)
  defp raw(flag), do: Ash.get!(FeatureFlag, flag.id, authorize?: false)

  test "the page acts with the RESOLVED role, not :member", ctx do
    for role <- [:viewer, :member, :admin, :owner] do
      socket = H.live_socket(H.log_in(Map.fetch!(ctx, role)), SettingsLive, @path, ctx.org_id)
      assert socket.assigns.actor_state == :ok
      assert socket.assigns.acting_scope.actor.role == role
      assert socket.assigns.acting_scope.actor.resolved == true
      assert html(socket) =~ "zebra.flag", "#{role}: reads are open to every active member"
    end
  end

  test "only an admin is offered the controls; a viewer's and a member's crafted write changes nothing, an admin's does", ctx do
    for role <- [:viewer, :member] do
      socket = H.live_socket(H.log_in(Map.fetch!(ctx, role)), SettingsLive, @path, ctx.org_id)
      assert socket.assigns.can_admin == false
      refute html(socket) =~ ~s(phx-click="toggle_flag")

      socket = H.event(SettingsLive, "toggle_flag", %{"id" => ctx.flag.id}, socket)
      assert socket.assigns.flag_error =~ "admin"
      assert raw(ctx.flag).enabled, "#{role} switched a flag off"
    end

    admin = H.live_socket(H.log_in(ctx.admin), SettingsLive, @path, ctx.org_id)
    assert admin.assigns.can_admin == true
    assert html(admin) =~ ~s(phx-click="toggle_flag")
    admin = H.event(SettingsLive, "toggle_flag", %{"id" => ctx.flag.id}, admin)
    assert admin.assigns.flag_error == nil
    refute raw(ctx.flag).enabled
  end

  test "NAVIGATION: a suspended member's page is the denied state: nothing is read, no event writes", ctx do
    login = H.log_in(ctx.admin)
    socket = H.live_socket(login, SettingsLive, @path, ctx.org_id)
    assert html(socket) =~ "zebra.flag", "nothing to read while acting (vacuous control)"

    SpineAccounts.suspend!(ctx.admin, ctx.org_id)
    refused = H.params(SettingsLive, socket, %{})
    assert refused.assigns.actor_state == :denied
    assert refused.assigns.acting_scope == nil
    out = html(refused)
    assert out =~ ~s(id="actor-denied")
    refute out =~ "zebra.flag"

    assert H.event(SettingsLive, "toggle_flag", %{"id" => ctx.flag.id}, refused).assigns == refused.assigns
    assert raw(ctx.flag).enabled
  end

  test "a failed membership lookup is the UNAVAILABLE state, never an empty page", ctx do
    socket = H.live_socket(H.log_in(ctx.member), SettingsLive, @path, ctx.org_id) |> H.break_identity()
    {refused, _log} = ExUnit.CaptureLog.with_log(fn -> H.params(SettingsLive, socket, %{}) end)
    assert refused.assigns.actor_state == :unavailable
    assert html(refused) =~ ~s(id="actor-unavailable")
    refute html(refused) =~ "zebra.flag"
  end

  test "OPEN PAGE: an admin demoted while the page is open writes nothing at the next event; an unchanged admin does", ctx do
    open = H.open_socket(H.log_in(ctx.admin), SettingsLive, @path, ctx.org_id)
    assert open.assigns.can_admin

    SpineAccounts.set_role!(ctx.admin, ctx.org_id, :member)
    demoted = H.live_event(SettingsLive, "toggle_flag", %{"id" => ctx.flag.id}, open)
    assert demoted.assigns.acting_scope.actor.role == :member
    refute demoted.assigns.can_admin
    assert raw(ctx.flag).enabled

    # positive control: an unchanged admin's event on a fresh page
    SpineAccounts.set_role!(ctx.admin, ctx.org_id, :admin)
    fresh = H.open_socket(H.log_in(ctx.admin), SettingsLive, @path, ctx.org_id)
    H.live_event(SettingsLive, "toggle_flag", %{"id" => ctx.flag.id}, fresh)
    refute raw(ctx.flag).enabled
  end
end
