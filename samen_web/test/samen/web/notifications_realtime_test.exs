defmodule Samen.Web.NotificationsRealtimeTest do
  @moduledoc """
  WS-A A4 UNIT 2 — THE REALTIME GATE for notifications (AC-G2-5 realtime half +
  AC-G2-10 / RP-G2-10; Invariant N1; the ADR-012 chat pattern reused verbatim).

  The kernel engine (`Samen.Notifications.Engine.notify/1`) hands the web broadcaster
  (`Samen.Web.Notifications.PubSubBroadcaster`) an **id-only** envelope; the broadcaster
  publishes it on the recipient + org topics. Each subscriber RE-READS the record
  through the reads layer with ITS OWN scope:

    * the TENANT subscriber's re-read → the CLEAR body (own plane);
    * the OPERATOR subscriber's re-read → `%Masked{}` (→ ••••), from the SAME broadcast.

  RP-G2-10 (red path): plaintext NEVER transits PubSub — the envelope carries no body
  key, and the web broadcaster STRIPS any non-id key, so even a poisoned envelope
  cannot push plaintext onto a topic. An operator listener cannot receive plaintext.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Notifications.Engine
  alias Samen.Web.Mount
  alias Samen.Web.Notifications.InboxLive
  alias Samen.Web.Notifications.PubSub, as: NotificationsPubSub
  alias Samen.Web.Notifications.PubSubBroadcaster
  alias Samen.Web.Notifications.Reads

  @pubsub Samen.WebTest.NotificationsPubSub
  @body "REALTIME-BODY-SENTINEL settlement #S-88 cleared."

  setup do
    start_supervised!({Phoenix.PubSub, name: @pubsub})

    # Wire the web broadcaster to the test PubSub server (the host-config seam).
    Application.put_env(:samen_web, PubSubBroadcaster, pubsub: @pubsub)
    on_exit(fn -> Application.delete_env(:samen_web, PubSubBroadcaster) end)

    %{org_id: Ash.UUID.generate(), recipient_id: Ash.UUID.generate()}
  end

  defp notifications_mount(opts \\ []) do
    plane =
      case Keyword.get(opts, :plane, :tenant) do
        :operator ->
          Samen.Web.Plane.operator("op-1", Keyword.fetch!(opts, :target_org_id), "test-session")

        _ ->
          Samen.Web.Plane.tenant()
      end

    Mount.new(:notifications, Samen.WebTest.Primitives, Samen.WebTest.Repo,
      plane: plane,
      labels: %{pubsub: @pubsub}
    )
  end

  defp engine_opts do
    [
      notification_module: Samen.WebTest.Primitives.Notification,
      preference_module: Samen.WebTest.Primitives.NotificationPreference,
      repo: Samen.WebTest.Repo,
      broadcaster: PubSubBroadcaster
    ]
  end

  # ---------------------------------------------------------------------------
  # AC-G2-5/-10 — id-only envelope, delivered on both topics, re-read per plane
  # ---------------------------------------------------------------------------

  test "notify → id-only envelope; tenant re-read CLEAR, operator re-read •••• from the SAME broadcast",
       %{org_id: org_id, recipient_id: recipient_id} do
    tenant_mount = notifications_mount()
    operator_mount = notifications_mount(plane: :operator, target_org_id: org_id)

    # A SECOND subscriber process (the operator viewer) on the org topic relays what it
    # receives — proving cross-process realtime delivery + per-plane masking.
    test_pid = self()

    operator_subscriber =
      spawn_link(fn ->
        Phoenix.PubSub.subscribe(@pubsub, NotificationsPubSub.org_topic(org_id))
        send(test_pid, :operator_subscribed)

        receive do
          {:notification_created, envelope} ->
            op_scope = Mount.scope(operator_mount, org_id)
            {:ok, notification} = Reads.get_notification(operator_mount, op_scope, envelope.id)
            send(test_pid, {:operator_saw, notification.rendered_body})
        after
          5_000 -> send(test_pid, :operator_timeout)
        end
      end)

    # The tenant viewer (this process) subscribes on BOTH topics (recipient + org).
    :ok = NotificationsPubSub.subscribe(tenant_mount, org_id, recipient_id)
    :ok = NotificationsPubSub.subscribe_org(tenant_mount, org_id)
    assert_receive :operator_subscribed, 2_000

    # The KERNEL engine dispatches through the WEB broadcaster (the wired seam).
    {:ok, notification} =
      Engine.notify(
        %{
          org_id: org_id,
          recipient_id: recipient_id,
          event_type: "settlement.cleared",
          channel: :in_app,
          rendered_body: @body
        },
        engine_opts()
      )

    # Invariant N1 — the envelope carries the FIVE bounded routing keys, nothing else:
    # no rendered body, no resolved PII, on EITHER topic.
    assert_receive {:notification_created, envelope}, 2_000
    assert Map.keys(envelope) |> Enum.sort() == [:channel, :event_type, :id, :org_id, :recipient_id]
    refute Map.has_key?(envelope, :rendered_body)
    assert envelope.id == notification.id

    # The second topic delivered the SAME id-only envelope.
    assert_receive {:notification_created, ^envelope}, 2_000

    # The TENANT re-read (own scope) → CLEAR body.
    tenant_scope = Mount.scope(tenant_mount, org_id)
    {:ok, tenant_view} = Reads.get_notification(tenant_mount, tenant_scope, envelope.id)
    assert tenant_view.rendered_body == @body

    # The OPERATOR subscriber re-read the SAME id → %Masked{} (••••), never the sentinel.
    assert_receive {:operator_saw, operator_body}, 3_000
    assert match?(%Samen.Masked{}, operator_body)
    refute is_binary(operator_body) and operator_body =~ "REALTIME-BODY-SENTINEL"

    Process.exit(operator_subscriber, :normal)
  end

  # ---------------------------------------------------------------------------
  # RP-G2-10 — the red path: plaintext cannot transit the web seam
  # ---------------------------------------------------------------------------

  test "the web broadcaster STRIPS any non-id key — a poisoned envelope cannot leak plaintext",
       %{org_id: org_id, recipient_id: recipient_id} do
    Phoenix.PubSub.subscribe(@pubsub, NotificationsPubSub.org_topic(org_id))

    # A buggy/hostile caller hands an envelope CARRYING the plaintext body. The
    # broadcaster narrows to the bounded key set before publish — the listener
    # receives the id-only envelope (the anti-tautology probe: sabotaging the strip
    # makes this test FAIL).
    :ok =
      PubSubBroadcaster.broadcast(%{
        id: Ash.UUID.generate(),
        org_id: org_id,
        recipient_id: recipient_id,
        event_type: "poisoned.event",
        channel: :in_app,
        rendered_body: "POISONED-PLAINTEXT-SENTINEL"
      })

    assert_receive {:notification_created, envelope}, 2_000
    refute Map.has_key?(envelope, :rendered_body)
    assert Map.keys(envelope) |> Enum.sort() == [:channel, :event_type, :id, :org_id, :recipient_id]
  end

  test "a malformed envelope (no routing ids) is refused, not published" do
    assert {:error, :malformed_envelope} = PubSubBroadcaster.broadcast(%{rendered_body: "LEAK"})
  end

  # ---------------------------------------------------------------------------
  # The LiveView handle_info — each session re-reads under its OWN scope
  # ---------------------------------------------------------------------------

  test "InboxLive.handle_info re-reads the broadcast id under its OWN scope and refreshes list + badge",
       %{org_id: org_id, recipient_id: recipient_id} do
    tenant_socket = inbox_socket(notifications_mount(), org_id)
    assert tenant_socket.assigns.unread_count == 0

    {:ok, notification} =
      Engine.notify(
        %{
          org_id: org_id,
          recipient_id: recipient_id,
          event_type: "settlement.cleared",
          channel: :in_app,
          rendered_body: @body
        },
        engine_opts()
      )

    {:noreply, tenant_socket} =
      InboxLive.handle_info({:notification_created, %{id: notification.id}}, tenant_socket)

    # The tenant session's re-read: the row is on the page, the badge incremented,
    # and the body renders CLEAR (own plane).
    assert Enum.any?(tenant_socket.assigns.page.items, &(&1.id == notification.id))
    assert tenant_socket.assigns.unread_count == 1
    assert render_html(InboxLive, tenant_socket.assigns) =~ "REALTIME-BODY-SENTINEL"

    # The SAME envelope into an OPERATOR session re-reads MASKED (its own scope).
    operator_socket =
      inbox_socket(notifications_mount(plane: :operator, target_org_id: org_id), org_id)

    {:noreply, operator_socket} =
      InboxLive.handle_info({:notification_created, %{id: notification.id}}, operator_socket)

    operator_html = render_html(InboxLive, operator_socket.assigns)
    assert operator_html =~ "••••"
    refute operator_html =~ "REALTIME-BODY-SENTINEL"
  end

  test "a CROSS-ORG envelope re-reads to zero rows and is ignored (no existence oracle)",
       %{org_id: org_id} do
    other_org = Ash.UUID.generate()

    {:ok, foreign} =
      Engine.notify(
        %{
          org_id: other_org,
          recipient_id: Ash.UUID.generate(),
          event_type: "foreign.event",
          channel: :in_app,
          rendered_body: "FOREIGN-ORG-SENTINEL"
        },
        engine_opts()
      )

    socket = inbox_socket(notifications_mount(), org_id)
    {:noreply, socket} = InboxLive.handle_info({:notification_created, %{id: foreign.id}}, socket)

    # OrgScope narrowed the re-read to zero rows: nothing rendered, nothing counted.
    refute Enum.any?(socket.assigns.page.items, &(&1.id == foreign.id))
    assert socket.assigns.unread_count == 0
    refute render_html(InboxLive, socket.assigns) =~ "FOREIGN-ORG-SENTINEL"
  end

  # -- harness -------------------------------------------------------------------

  defp inbox_socket(mount, org_id) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, mount)
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> Phoenix.Component.assign(:return_to, nil)
    |> InboxLive.load(org_id)
  end
end
