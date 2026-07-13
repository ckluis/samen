defmodule PawChart.NotificationsMountTest do
  @moduledoc """
  WS-A A5 (inheritance proof, second vertical) — the framework NOTIFICATIONS INBOX
  (`Samen.Web.Notifications.InboxLive`) mounted over PawChart's Primitives mount
  (`PawChart.Primitives.{Notification,NotificationPreference}`) by ONE
  `samen_notifications_routes` line in `PawChartWeb.Router`. Zero PawChart LiveView
  code. Proves the mount end-to-end:

    1. GREEN — a notification written through the REAL kernel engine
       (`Samen.Notifications.Engine.notify/1`: vault-routed body + audit + id-only
       broadcast) renders through the mounted framework inbox on the tenant plane,
       body IN THE CLEAR.
    2. RED (masking, MC-3) — the SAME row on the operator/impersonation plane
       renders `••••`; the plaintext body is ABSENT from the DOM.
    3. RED (org isolation) — a foreign scope reads zero rows; a foreign id re-read
       is `:error` (no existence oracle).

  Anti-tautology: (1) and (2) render the SAME notification id through the SAME
  LiveView — only the mount's plane differs — asserting OPPOSITE facts about the
  same sentinel string.
  """
  use PawChart.DataCase, async: false

  alias Samen.Notifications.Engine
  alias Samen.Web.Mount
  alias Samen.Web.Notifications.InboxLive
  alias Samen.Web.Notifications.Reads
  alias Samen.Web.Plane

  @body "PAWCHART-INBOX-SENTINEL vaccine reminder: Biscuit is due for rabies."

  defp engine_opts do
    [
      notification_module: PawChart.Primitives.Notification,
      preference_module: PawChart.Primitives.NotificationPreference,
      repo: PawChart.Repo
    ]
  end

  defp notify!(org_id) do
    {:ok, notification} =
      Engine.notify(
        %{
          org_id: org_id,
          recipient_id: Ash.UUID.generate(),
          event_type: "vaccine.due",
          channel: :in_app,
          rendered_body: @body
        },
        engine_opts()
      )

    notification
  end

  defp notifications_mount(opts \\ []) do
    plane =
      case Keyword.get(opts, :plane, :tenant) do
        :operator ->
          Plane.operator("op-pawchart", Keyword.fetch!(opts, :target_org_id), "test-session")

        _ ->
          Plane.tenant()
      end

    Mount.new(:notifications, PawChart.Primitives, PawChart.Repo, plane: plane)
  end

  defp render_inbox(mount, org_id) do
    socket =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(:samen_mount, mount)
      |> Phoenix.Component.assign(:samen_acting_as, false)
      |> Phoenix.Component.assign(:return_to, nil)
      |> InboxLive.load(org_id)

    socket.assigns
    |> Map.put(:__changed__, %{})
    |> InboxLive.render()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  test "the mounted /notifications renders an engine-written notification on the tenant plane (clear)" do
    org_id = Ecto.UUID.generate()
    notify!(org_id)

    mount = notifications_mount()
    html = render_inbox(mount, org_id)

    # Structural: the framework app shell + the kit list (no bespoke pawchart wiring).
    assert html =~ ~s(id="notifications")
    assert html =~ ~s(phx-click="sort")

    # Non-vacuous + clear on the tenant plane.
    assert html =~ "vaccine.due"
    assert html =~ "PAWCHART-INBOX-SENTINEL"
    refute html =~ "vt_"
    refute html =~ "••••"

    # The unread badge is lit.
    assert Reads.unread_count(mount, Mount.scope(mount, org_id)) == 1
  end

  test "RED PATH (MC-3): the SAME notification renders •••• on the operator plane — plaintext ABSENT" do
    org_id = Ecto.UUID.generate()
    notify!(org_id)

    mount = notifications_mount(plane: :operator, target_org_id: org_id)
    html = render_inbox(mount, org_id)

    assert html =~ "vaccine.due"
    assert html =~ "••••"
    refute html =~ "PAWCHART-INBOX-SENTINEL"
    refute html =~ "vt_"
  end

  test "RED PATH (org isolation): a foreign org's notification is invisible through the mount" do
    org_id = Ecto.UUID.generate()
    notification = notify!(org_id)

    mount = notifications_mount()
    foreign_scope = Mount.scope(mount, Ecto.UUID.generate())

    page = Reads.notifications_page(mount, foreign_scope, %Samen.Web.ListState{})
    assert page.items == []

    assert Reads.get_notification(mount, foreign_scope, notification.id) == :error
  end
end
