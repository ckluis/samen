defmodule Driftwood.NotificationsUiTest do
  @moduledoc """
  WS-A A5 (inheritance proof) — the framework NOTIFICATIONS INBOX
  (`Samen.Web.Notifications.InboxLive`) mounted over Driftwood's Primitives mount
  (`Driftwood.Primitives.{Notification,NotificationPreference}`) by ONE
  `samen_notifications_routes` line in `DriftwoodWeb.Router`. NO Driftwood LiveView
  code renders these pages; these tests prove Driftwood's MOUNT is correct:

    1. GREEN — the seeded notifications (written through the REAL kernel engine by
       `Driftwood.Seeds.demo_all/1`) render through the mounted framework inbox on
       the tenant plane, body IN THE CLEAR, unread badge = 2 (3 seeded, 1 read).
    2. RED (masking, MC-3) — the SAME rows on the operator/impersonation plane
       render `••••` and the plaintext body is ABSENT from the DOM.
    3. RED (org isolation) — another org's notification is invisible through the
       mount: the list page reads zero foreign rows and a foreign id re-read is
       `:error` (no existence oracle).

  Anti-tautology: (1) and (2) render the SAME notification ids through the SAME
  LiveView — only the mount's plane differs — and assert OPPOSITE facts about the
  same sentinel string, so a hardwired pass on either side fails the other.
  """
  use Driftwood.DataCase, async: false

  require Ash.Query

  alias Driftwood.Seeds
  alias Samen.Web.Mount
  alias Samen.Web.Notifications.InboxLive
  alias Samen.Web.Notifications.Reads

  setup do
    org_id = Ecto.UUID.generate()
    :ok = Seeds.run(org_id)
    assert Seeds.demo_all(org_id) == org_id
    %{org_id: org_id}
  end

  defp render_inbox(mount, org_id) do
    render_framework(InboxLive, mount, [org_id], %{return_to: nil})
  end

  test "the mounted /notifications renders the seeded notifications on the tenant plane (clear)",
       %{org_id: org_id} do
    mount = driftwood_mount(:notifications)
    html = render_inbox(mount, org_id)

    # Structural: the framework app shell + the kit list (ListLive/list_view — no
    # bespoke driftwood wiring).
    assert html =~ ~s(class="app")
    assert html =~ ~s(id="notifications")
    assert html =~ ~s(phx-click="sort")

    # Non-vacuous: all three curated engine-seeded events appear (the newest rows —
    # keyset newest-first), PLUS at least one ORGANIC notification the wired kernel
    # event sources fired during the billing seed (invoice status changes).
    assert html =~ "sla.breach"
    assert html =~ "invoice.past_due"
    assert html =~ "chat.mention"
    assert html =~ "invoice.paid"

    # Tenant plane reads its OWN body in the clear (MC-3 green half).
    assert html =~ "SLA breached on"
    refute html =~ "vt_"
    refute html =~ "••••"

    # Unread badge: EXACTLY one seeded notification is marked read, so unread =
    # total − 1 (discriminating: a hardwired badge or an all-unread seed both fail).
    scope = Mount.scope(mount, org_id)

    total =
      Driftwood.Primitives.Notification
      |> Ash.Query.filter(org_id == ^org_id)
      |> Ash.count!(authorize?: false)

    assert total >= 4
    assert Reads.unread_count(mount, scope) == total - 1
  end

  test "RED PATH (MC-3): the SAME notifications render •••• on the operator plane — plaintext ABSENT",
       %{org_id: org_id} do
    mount = driftwood_mount(:notifications, plane: :operator, target_org_id: org_id)
    html = render_inbox(mount, org_id)

    # The rows are PRESENT (the operator sees the org's inbox exists) …
    assert html =~ "sla.breach"

    # … but the vaulted body is masked: •••• present, plaintext + token ABSENT.
    assert html =~ "••••"
    refute html =~ "SLA breached on"
    refute html =~ "vt_"
  end

  test "RED PATH (org isolation): a foreign org's notifications are invisible through the mount",
       %{org_id: org_id} do
    foreign_org = Ecto.UUID.generate()

    mount = driftwood_mount(:notifications)
    foreign_scope = Mount.scope(mount, foreign_org)

    # The foreign org's list page contains NONE of this org's rows.
    page = Reads.notifications_page(mount, foreign_scope, %Samen.Web.ListState{})
    assert page.items == []

    # A direct re-read of one of this org's ids under the foreign scope is :error
    # (OrgScope reads zero rows — no existence oracle).
    [notification | _] =
      Driftwood.Primitives.Notification
      |> Ash.Query.filter(org_id == ^org_id)
      |> Ash.Query.limit(1)
      |> Ash.read!(authorize?: false)

    assert Reads.get_notification(mount, foreign_scope, notification.id) == :error
  end
end
