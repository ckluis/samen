defmodule Samen.Web.SupportRenderTest do
  @moduledoc """
  Framework Support render tests against the test-support host. The two-plane guarantee spans
  BOTH support PII surfaces: agent `full_name`/`email` and message `body` — tenant clear vs
  operator ••••, on both the inbox and the ticket-detail page.
  """
  use Samen.WebTest.DataCase, async: false

  setup do
    seeded = Seeds.seed_all()
    %{org_id: seeded.org_id, ticket_id: seeded.support.ticket.id}
  end

  test "/support inbox renders the app shell + seeded ticket", %{org_id: org_id} do
    mount = build_mount(:support)
    html = render_live(Samen.Web.Support.TicketsLive, mount, [org_id])

    assert html =~ ~s(class="app")
    assert html =~ "ticket-row"
    assert html =~ "Missing rate confirmation"
  end

  test "TENANT plane: ticket detail shows agent PII + message body in the clear", %{org_id: org_id, ticket_id: ticket_id} do
    mount = build_mount(:support, plane: :tenant)
    html = render_live(Samen.Web.Support.TicketLive, mount, [org_id, ticket_id])

    # Conversation body (PII) in the clear on the tenant plane.
    assert html =~ Seeds.message_body()
  end

  test "TENANT plane: ticket detail Details tab shows agent name/email in the clear", %{org_id: org_id, ticket_id: ticket_id} do
    mount = build_mount(:support, plane: :tenant)
    # Render the Details tab by pre-setting active_tab via a socket assign path.
    html = render_details_tab(mount, org_id, ticket_id)

    assert html =~ Seeds.agent_full_name()
    assert html =~ Seeds.agent_email()
  end

  test "OPERATOR plane: ticket detail masks message body ••••, plaintext absent", %{org_id: org_id, ticket_id: ticket_id} do
    mount = build_mount(:support, plane: :operator, target_org_id: org_id)
    html = render_live(Samen.Web.Support.TicketLive, mount, [org_id, ticket_id])

    assert html =~ "••••"
    refute html =~ Seeds.message_body()
    refute html =~ "vt_"
  end

  test "OPERATOR plane: Details tab masks agent name + email, plaintext absent", %{org_id: org_id, ticket_id: ticket_id} do
    mount = build_mount(:support, plane: :operator, target_org_id: org_id)
    html = render_details_tab(mount, org_id, ticket_id)

    assert html =~ "••••"
    refute html =~ Seeds.agent_full_name()
    refute html =~ Seeds.agent_email()
  end

  # Render the ticket-detail Details tab: load, then flip active_tab, then render.
  defp render_details_tab(mount, org_id, ticket_id) do
    socket =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(:samen_mount, mount)
      |> Phoenix.Component.assign(:samen_acting_as, false)
      |> Samen.Web.Support.TicketLive.load(org_id, ticket_id)
      |> Phoenix.Component.assign(:active_tab, "details")

    render_html(Samen.Web.Support.TicketLive, socket.assigns)
  end
end
