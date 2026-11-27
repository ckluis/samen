defmodule Samen.Web.FleetDirectivesKillAllTest do
  @moduledoc """
  The fleet kill switch (`FleetDirectivesLive`, `publish_kill` target `all`) is a destructive
  control: it renders with the `data-confirm` interlock and a disabled-while-running state, only
  for a fleet admin, and the handler publishes exactly one kill directive for an admin and
  nothing for anyone else.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Fleet.Registry
  alias Samen.Web.Mount
  alias Samen.Web.Operator.FleetDirectivesLive

  @ns Samen.WebTest.Fleet
  @otp_app :samen_web_fleet_kill_all_test_host

  setup do
    Application.put_env(@otp_app, :fleet, mode: :manual)

    on_exit(fn ->
      Application.delete_env(@otp_app, :fleet_authority)
      Application.delete_env(@otp_app, :fleet)
    end)

    :ok
  end

  def roles_for(roles, _principal_id), do: roles

  defp mounted(role) do
    Application.put_env(@otp_app, :fleet_authority, {__MODULE__, :roles_for, [%{fleet: role}]})

    mount =
      Mount.new(:operator, Samen.WebTest.Operator, Samen.WebTest.Repo,
        plane: Samen.Web.Plane.tenant(),
        labels: %{otp_app: @otp_app, fleet_namespace: @ns, fleet_cockpit: true}
      )

    socket = %Phoenix.LiveView.Socket{} |> Phoenix.Component.assign(:samen_mount, mount)
    {:ok, socket} = FleetDirectivesLive.mount(%{}, %{"samen_current_user" => "op-1"}, socket)
    socket
  end

  defp kill_button(html) do
    [tag] = Regex.run(~r/<button[^>]*id="publish-kill-all"[^>]*>/s, html)
    tag
  end

  defp directive_count(socket) do
    {:ok, list} = Registry.list_directives(@ns, Samen.Aggregate.Actor.new())
    _ = socket
    length(list)
  end

  test "the kill-all control carries the confirm interlock and a disabled-while-running state" do
    tag = mounted(:operator_admin).assigns |> then(&render_html(FleetDirectivesLive, &1)) |> kill_button()

    assert tag =~ ~r/data-confirm="[^"]+"/
    assert tag =~ ~r/phx-disable-with="[^"]+"/
    assert tag =~ ~s(phx-click="publish_kill")
  end

  test "a non-admin sees no kill-all control (positive control: the admin does)" do
    refute render_html(FleetDirectivesLive, mounted(:operator_readonly).assigns) =~ "publish-kill-all"
    assert render_html(FleetDirectivesLive, mounted(:operator_admin).assigns) =~ "publish-kill-all"
  end

  test "the handler publishes one kill directive for an admin and none for a read-only role" do
    admin = mounted(:operator_admin)
    before = directive_count(admin)
    {:noreply, admin} = FleetDirectivesLive.handle_event("publish_kill", %{"target" => "all"}, admin)
    assert directive_count(admin) == before + 1
    assert admin.assigns.publish_error == nil

    ro = mounted(:operator_readonly)
    {:noreply, ro} = FleetDirectivesLive.handle_event("publish_kill", %{"target" => "all"}, ro)
    assert directive_count(ro) == before + 1
    assert ro.assigns.publish_error =~ "operator_admin"
  end
end
