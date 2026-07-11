defmodule Samen.Web.NotificationsInboxTest do
  @moduledoc """
  WS-A A4 UNIT 2 — the framework notifications inbox (`Samen.Web.Notifications.InboxLive`,
  design §2.4, ADR-016 §4) on the A2/A3 kit contract:

    * **List on the kit (AC-G2-5 render half):** notifications written by the KERNEL
      engine (`Samen.Notifications.Engine.notify/1`) render through `ListLive` +
      `list_view/1`; the empty state is the kit default.
    * **Bounded read (AC-G1-5 carry):** `Reads.notifications_page/3` passes the
      `Samen.Web.Reads.bounded!/4` lint — the inbox cannot re-introduce an unbounded
      `read!`.
    * **Unread badge (AC-G2-7):** `Reads.unread_count/2` feeds the `nav_item` `count`
      affordance (finally lit); `mark_read` decrements it; `mark_all_read` zeroes it.
      Anti-tautology: the badge value DISCRIMINATES (2 → 1 → 0 across the flow), so a
      hardwired badge cannot pass.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Notifications.Engine
  alias Samen.Web.Mount
  alias Samen.Web.Notifications.InboxLive
  alias Samen.Web.Notifications.Reads

  @body "INBOX-BODY-SENTINEL your invoice #INV-7 is ready."

  # -- harness -------------------------------------------------------------------

  defp engine_opts do
    [
      notification_module: Samen.WebTest.Primitives.Notification,
      preference_module: Samen.WebTest.Primitives.NotificationPreference,
      repo: Samen.WebTest.Repo
    ]
  end

  defp notify!(org_id, overrides \\ %{}) do
    request =
      Map.merge(
        %{
          org_id: org_id,
          recipient_id: Ash.UUID.generate(),
          event_type: "invoice.created",
          channel: :in_app,
          rendered_body: @body
        },
        overrides
      )

    {:ok, notification} = Engine.notify(request, engine_opts())
    notification
  end

  defp mount_socket(org_id, plane_opts \\ []) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, build_mount(:notifications, plane_opts))
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> Phoenix.Component.assign(:return_to, nil)
    |> InboxLive.load(org_id)
  end

  defp html(socket), do: render_html(InboxLive, socket.assigns)

  defp event(socket, name, params) do
    {:noreply, socket} = InboxLive.handle_event(name, params, socket)
    socket
  end

  # ---------------------------------------------------------------------------
  # Render — the kit list (AC-G2-5 render half) + empty state
  # ---------------------------------------------------------------------------

  test "the inbox renders engine-written notifications through the kit list_view" do
    org_id = Ash.UUID.generate()
    notify!(org_id, %{event_type: "invoice.created"})
    notify!(org_id, %{event_type: "sla.breach"})

    socket = mount_socket(org_id)
    rendered = html(socket)

    # The kit list is present with one row per notification.
    assert rendered =~ ~s(id="notifications")
    assert rendered =~ "invoice.created"
    assert rendered =~ "sla.breach"
    # The tenant plane reads its own body in the clear (MC-3 green half).
    assert rendered =~ "INBOX-BODY-SENTINEL"
    # Sortable kit headers (the A2 contract, not bespoke wiring).
    assert rendered =~ ~s(phx-click="sort")
    assert rendered =~ ~s(phx-change="filter")
  end

  test "zero notifications render the kit default empty state" do
    socket = mount_socket(Ash.UUID.generate())
    rendered = html(socket)

    assert rendered =~ "No notifications yet."
    assert rendered =~ "empty-state"
  end

  # ---------------------------------------------------------------------------
  # Bounded read (the AC-G1-5 lint carry — RP-G1-5's green half for this read)
  # ---------------------------------------------------------------------------

  test "notifications_page/3 is BOUNDED by construction (bounded!/4 lint passes)" do
    org_id = Ash.UUID.generate()
    for _ <- 1..5, do: notify!(org_id)

    mount = build_mount(:notifications)
    scope = Mount.scope(mount, org_id)

    # 5 rows > probe page size 2 — the lint would RAISE on an unbounded read.
    assert :ok = Samen.Web.Reads.bounded!(&Reads.notifications_page/3, mount, scope, page_size: 2)
  end

  # ---------------------------------------------------------------------------
  # Unread badge + mark-read (AC-G2-7 — discriminating counts, not a hardwired pass)
  # ---------------------------------------------------------------------------

  test "unread badge is fed by unread_count; mark_read decrements; mark_all_read zeroes" do
    org_id = Ash.UUID.generate()
    n1 = notify!(org_id)
    _n2 = notify!(org_id)

    socket = mount_socket(org_id)
    assert socket.assigns.unread_count == 2

    rendered = html(socket)
    # The panel count AND the sidebar nav_item badge (the `cnt` affordance) are lit.
    assert rendered =~ ~s(id="notifications-unread">2<)
    assert rendered =~ ~s(class="cnt">2<)
    assert rendered =~ ~s(phx-click="mark_read")
    assert rendered =~ ~s(id="mark-all-read")

    # Mark ONE read → the badge DECREMENTS (2 → 1) and read_at is persisted.
    socket = event(socket, "mark_read", %{"id" => n1.id})
    assert socket.assigns.unread_count == 1
    assert html(socket) =~ ~s(id="notifications-unread">1<)

    raw = Ash.get!(Samen.WebTest.Primitives.Notification, n1.id, authorize?: false)
    assert %DateTime{} = raw.read_at
    assert raw.status == :read

    # Mark ALL read → the badge zeroes and the affordance disappears.
    socket = event(socket, "mark_all_read", %{})
    assert socket.assigns.unread_count == 0
    rendered = html(socket)
    assert rendered =~ ~s(id="notifications-unread">0<)
    refute rendered =~ ~s(id="mark-all-read")
    refute rendered =~ "n-unread-dot"
  end

  test "a cross-org mark_read is refused (OrgScope): the foreign row is untouched" do
    org_id = Ash.UUID.generate()
    other_org = Ash.UUID.generate()
    foreign = notify!(other_org)

    socket = mount_socket(org_id)
    socket = event(socket, "mark_read", %{"id" => foreign.id})

    # No crash, no write: the foreign notification is still unread.
    raw = Ash.get!(Samen.WebTest.Primitives.Notification, foreign.id, authorize?: false)
    assert raw.read_at == nil
    assert socket.assigns.unread_count == 0
  end

  # ---------------------------------------------------------------------------
  # Preference suppression rides through to the inbox (the UNIT 1 red path, seen
  # from the UI: a suppressed event type produces NO row to render).
  # ---------------------------------------------------------------------------

  test "a suppressed event type never reaches the inbox (no record, no row)" do
    org_id = Ash.UUID.generate()
    recipient_id = Ash.UUID.generate()

    Samen.WebTest.Primitives.NotificationPreference
    |> Ash.Changeset.for_create(:create, %{
      org_id: org_id,
      recipient_id: recipient_id,
      event_type: "digest.weekly",
      in_app_enabled: false
    })
    |> Ash.create!(authorize?: false)

    assert {:ok, :suppressed} =
             Engine.notify(
               %{
                 org_id: org_id,
                 recipient_id: recipient_id,
                 event_type: "digest.weekly",
                 channel: :in_app,
                 rendered_body: "SUPPRESSED-SENTINEL"
               },
               engine_opts()
             )

    rendered = html(mount_socket(org_id))
    refute rendered =~ "SUPPRESSED-SENTINEL"
    assert rendered =~ "No notifications yet."
  end
end
