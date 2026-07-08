defmodule Driftwood.SupportUiTest do
  @moduledoc """
  Support UI smoke tests — the inherited Support module rendered by the FRAMEWORK (ADR-009).

  The Support pages are `Samen.Web.Support.{Tickets,Ticket}Live`, MOUNTED by
  `DriftwoodWeb.Router` (`samen_module_routes :support, Driftwood.Support, repo:
  Driftwood.Repo`) over Driftwood's materialized `Driftwood.Support.*` resources. Deep
  render/masking coverage lives in samen_web (`web/support_render_test.exs`); these tests
  prove Driftwood's OWN MOUNT renders Driftwood's rows on both planes, keeping the two Support
  PII surfaces (agent full_name/email + message body).

    1. The mounted inbox + ticket-detail render with Driftwood's seeded rows (non-vacuous).
    2. MASKING (over the driftwood mount):
       a. TENANT plane — agent full_name + message body render IN THE CLEAR.
       b. OPERATOR plane — the SAME render •••• and the plaintext is ABSENT.
  """
  use Driftwood.DataCase, async: false

  alias Driftwood.Seeds
  alias Samen.Web.Support
  alias Samen.Web.Support.Reads
  alias Samen.Web.Mount

  setup do
    org_id = Ecto.UUID.generate()
    :ok = Seeds.run(org_id)
    assert Seeds.demo_all(org_id) == org_id
    %{org_id: org_id}
  end

  # Locate a seeded ticket that has a conversation (message body to mask). The framework
  # Reads are mount + scope parameterized.
  defp ticket_with_conv(mount, scope) do
    tickets = Reads.tickets(mount, scope)

    Enum.find(tickets, fn t ->
      length(Reads.conversations_for_ticket(mount, scope, t.id)) > 0
    end)
  end

  # ==========================================================================
  # MOUNTED ROUTES render Driftwood's seeded rows
  # ==========================================================================

  test "the mounted /support inbox renders metrics + Driftwood's tickets", %{org_id: org_id} do
    mount = driftwood_mount(:support)
    html = render_framework(Support.TicketsLive, mount, [org_id])

    assert html =~ ~s(class="app")
    assert html =~ "<table>"
    assert html =~ "Breaching SLA"
    assert html =~ "Solved this week"
    assert html =~ "Ticket Inbox"
    assert html =~ "ticket-row"

    refute html =~ "vt_"
  end

  test "the mounted /support/tickets/:id renders the conversation thread", %{org_id: org_id} do
    mount = driftwood_mount(:support)
    scope = Mount.scope(mount, org_id)
    ticket = ticket_with_conv(mount, scope)
    assert ticket != nil, "no ticket with conversations found"

    html = render_framework(Support.TicketLive, mount, [org_id, ticket.id])

    assert html =~ ~s(class="app")
    assert html =~ "support-ticket"
    assert html =~ "ticket-header"
    assert html =~ ticket.subject
    assert html =~ "conversation-pane"
    assert html =~ "msg-row"
    assert html =~ "Conversation"
    assert html =~ "Details"

    refute html =~ "vt_"
  end

  # ==========================================================================
  # MASKING over the driftwood mount — tenant clear / operator ••••
  # ==========================================================================

  describe "Support PII masking over the Driftwood mount (agent name + message body)" do
    test "TENANT plane: agent full_name + message body render IN THE CLEAR", %{org_id: org_id} do
      mount = driftwood_mount(:support, plane: :tenant)
      scope = Mount.scope(mount, org_id)
      ticket = ticket_with_conv(mount, scope)
      assert ticket != nil

      # Message body (conversation pane, default tab) IN THE CLEAR.
      conv_html = render_framework(Support.TicketLive, mount, [org_id, ticket.id])
      assert conv_html =~ "disputing the charge", "tenant plane did not render message body in the clear"
      refute conv_html =~ "vt_"

      # Agent full_name (Details tab) IN THE CLEAR.
      details_html =
        render_framework(Support.TicketLive, mount, [org_id, ticket.id], %{active_tab: "details"})

      assert details_html =~ "claims-desk", "tenant plane did not render agent handle"
      assert details_html =~ "Sofia" or details_html =~ "Marchetti",
             "tenant plane did not render agent full_name in the clear"
      refute details_html =~ "vt_"
    end

    test "OPERATOR/impersonation plane: agent full_name + message body render •••• (no leak)", %{org_id: org_id} do
      # Locate the ticket via a tenant read (org-scope still matches the same rows).
      tenant = driftwood_mount(:support, plane: :tenant)
      tscope = Mount.scope(tenant, org_id)
      ticket = ticket_with_conv(tenant, tscope)
      assert ticket != nil

      op_mount = driftwood_mount(:support, plane: :operator, target_org_id: org_id)

      # Message body masked on the conversation pane.
      conv_html = render_framework(Support.TicketLive, op_mount, [org_id, ticket.id])
      assert conv_html =~ "msg-row", "operator plane rendered no messages (vacuous)"
      assert conv_html =~ "••••", "operator plane did not mask the message body"
      refute conv_html =~ "disputing the charge", "operator plane leaked message body plaintext"
      refute conv_html =~ "vt_"

      # Agent full_name masked on the Details tab.
      details_html =
        render_framework(Support.TicketLive, op_mount, [org_id, ticket.id], %{active_tab: "details"})

      assert details_html =~ "••••", "operator plane did not mask agent full_name"
      refute details_html =~ "Marchetti", "operator plane leaked agent full_name in plaintext"
      refute details_html =~ "sofia.marchetti", "operator plane leaked agent email in plaintext"
      refute details_html =~ "vt_"
    end

    test "CROSS-ORG: a tenant mount for a DIFFERENT org sees ZERO tickets (org-scope isolation)", %{org_id: _org_id} do
      other_org = Ecto.UUID.generate()
      mount = driftwood_mount(:support, plane: :tenant)
      html = render_framework(Support.TicketsLive, mount, [other_org])

      refute html =~ "disputing the charge"
      refute html =~ "Marchetti"
      refute html =~ "vt_"
    end
  end
end
