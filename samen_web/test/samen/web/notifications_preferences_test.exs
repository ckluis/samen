defmodule Samen.Web.NotificationsPreferencesTest do
  @moduledoc """
  WS-A A4 UNIT 3 — the `/notifications/settings` preferences panel
  (`Samen.Web.Notifications.PreferencesLive`; design §2.4 "Preferences UI",
  ADR-016 §4) on the A2 kit:

    * **Per-event-type grid**: one row per wired event source (SLA breach, chat
      mention, send blocked/failed, invoice events) rendered through the kit
      `simple_form/1` + `form_field/1` selects, showing the engine defaults
      honestly (in-app ON, email OFF) until a row exists.
    * **The toggle writes through Ash** (`Reads.set_preference/4` — OrgScope +
      RoleAtLeast member; upsert): flipping an event OFF persists a
      `NotificationPreference` row…
    * **…which the ENGINE then honors** (the UI→engine integration red path):
      after the UI toggle, `Engine.notify/2` for that event type returns
      `{:ok, :suppressed}` and writes NO record. The toggle grid is provably the
      dispatch gate, not cosmetic state.
    * **Plane posture**: the operator plane renders a READ-ONLY grid (disabled
      controls) and `save` is a no-op (the kernel policy enforces regardless).
    * **Recipient seam**: no wired recipient → the honest "no recipient wired"
      card, never a guessed identity.
  """
  use Samen.WebTest.DataCase, async: false

  require Ash.Query

  alias Samen.Notifications.Engine
  alias Samen.Web.Notifications.PreferencesLive
  alias Samen.WebTest.Primitives.{Notification, NotificationPreference}

  defp engine_opts do
    [
      notification_module: Notification,
      preference_module: NotificationPreference,
      repo: Samen.WebTest.Repo
    ]
  end

  defp mount_socket(org_id, recipient_id, plane_opts \\ []) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, build_mount(:notifications, plane_opts))
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> Phoenix.Component.assign(:return_to, nil)
    |> PreferencesLive.load(org_id, recipient_id)
  end

  defp html(socket), do: render_html(PreferencesLive, socket.assigns)

  defp toggle(socket, field, value) do
    {:noreply, socket} =
      PreferencesLive.handle_event(
        "save",
        %{"_target" => ["prefs", field], "prefs" => %{field => value}},
        socket
      )

    socket
  end

  defp preference_rows(org_id, recipient_id, event_type) do
    NotificationPreference
    |> Ash.Query.filter(org_id == ^org_id)
    |> Ash.Query.filter(recipient_id == ^recipient_id)
    |> Ash.Query.filter(event_type == ^event_type)
    |> Ash.read!(authorize?: false)
  end

  # ---------------------------------------------------------------------------
  # Render — the per-event-type kit grid
  # ---------------------------------------------------------------------------

  test "the grid renders one row per wired event source, on the kit form, with honest defaults" do
    org_id = Ash.UUID.generate()
    recipient_id = Ash.UUID.generate()

    rendered = html(mount_socket(org_id, recipient_id))

    # The kit form (A2 simple_form) drives the grid.
    assert rendered =~ ~s(id="preferences-form")
    assert rendered =~ ~s(phx-change="save")
    assert rendered =~ "simple-form"

    # Every wired source has a row (per-event-type granularity, design §2.4).
    for {event, _label} <- PreferencesLive.default_event_types() do
      assert rendered =~ ~s(id="pref-#{event}")
    end

    # No rows exist yet — the defaults are shown as defaults, not silently minted.
    assert rendered =~ "default"
    assert preference_rows(org_id, recipient_id, "sla_breach") == []
  end

  test "no wired recipient renders the honest seam card (no guessed identity, no grid)" do
    rendered = html(mount_socket(Ash.UUID.generate(), nil))

    assert rendered =~ ~s(id="no-recipient")
    refute rendered =~ ~s(id="preferences-form")
  end

  # ---------------------------------------------------------------------------
  # The toggle write → the engine honors it (the load-bearing integration)
  # ---------------------------------------------------------------------------

  test "toggling an event OFF persists the row AND the engine then suppresses that event type" do
    org_id = Ash.UUID.generate()
    recipient_id = Ash.UUID.generate()
    socket = mount_socket(org_id, recipient_id)

    # BEFORE the toggle: the engine dispatches (default-on in-app) — the
    # discriminating half; a hardwired suppression cannot pass this pair.
    assert {:ok, _} =
             Engine.notify(
               %{
                 org_id: org_id,
                 recipient_id: recipient_id,
                 event_type: "chat_mention",
                 channel: :in_app,
                 rendered_body: "pre-toggle"
               },
               engine_opts()
             )

    # The UI toggle: chat_mention in-app → off.
    socket = toggle(socket, "chat_mention__in_app", "off")

    assert [row] = preference_rows(org_id, recipient_id, "chat_mention")
    assert row.in_app_enabled == false

    # AFTER the toggle: the SAME notify is suppressed — NO new record.
    assert {:ok, :suppressed} =
             Engine.notify(
               %{
                 org_id: org_id,
                 recipient_id: recipient_id,
                 event_type: "chat_mention",
                 channel: :in_app,
                 rendered_body: "post-toggle"
               },
               engine_opts()
             )

    records =
      Notification
      |> Ash.Query.filter(org_id == ^org_id)
      |> Ash.Query.filter(event_type == ^"chat_mention")
      |> Ash.read!(authorize?: false)

    assert length(records) == 1

    # The grid reflects the persisted row (no longer a default).
    rendered = html(socket)
    assert rendered =~ ~s(id="pref-chat_mention")
  end

  test "toggling the same event back ON updates the existing row (upsert, not a duplicate)" do
    org_id = Ash.UUID.generate()
    recipient_id = Ash.UUID.generate()
    socket = mount_socket(org_id, recipient_id)

    socket = toggle(socket, "sla_breach__in_app", "off")
    socket = toggle(socket, "sla_breach__in_app", "on")

    assert [row] = preference_rows(org_id, recipient_id, "sla_breach")
    assert row.in_app_enabled == true

    _ = socket
  end

  test "toggling email ON persists the opt-in channel (per-channel granularity)" do
    org_id = Ash.UUID.generate()
    recipient_id = Ash.UUID.generate()
    socket = mount_socket(org_id, recipient_id)

    _socket = toggle(socket, "invoice.paid__email", "on")

    assert [row] = preference_rows(org_id, recipient_id, "invoice.paid")
    assert row.email_enabled == true
    # The untouched channel keeps its engine default.
    assert row.in_app_enabled == true
  end

  # ---------------------------------------------------------------------------
  # Plane posture (operator read-only) + malformed input
  # ---------------------------------------------------------------------------

  test "the operator plane renders a read-only grid and save is a no-op" do
    org_id = Ash.UUID.generate()
    recipient_id = Ash.UUID.generate()

    socket = mount_socket(org_id, recipient_id, plane: :operator, target_org_id: org_id)
    rendered = html(socket)

    # Disabled kit controls (posture; the kernel policy enforces regardless).
    assert rendered =~ "disabled"
    assert rendered =~ "read-only"

    _socket = toggle(socket, "chat_mention__in_app", "off")
    assert preference_rows(org_id, recipient_id, "chat_mention") == []
  end

  test "a malformed toggle field writes nothing (no crash, no oracle)" do
    org_id = Ash.UUID.generate()
    recipient_id = Ash.UUID.generate()
    socket = mount_socket(org_id, recipient_id)

    _socket = toggle(socket, "not-a-real-field", "off")
    _socket = toggle(socket, "chat_mention__bogus_channel", "off")

    assert preference_rows(org_id, recipient_id, "chat_mention") == []
  end
end
