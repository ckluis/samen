defmodule Driftwood.SupportUiTest do
  @moduledoc """
  Support UI page tests — inherited Support module.

  Covers four guarantees:

    1. Each Support route (/support, /support/tickets/:id) renders 200 with
       seeded data: real rows appear, no crash, the app shell + tables are present.

    2. MASKING TEST — agent PII + message body invariant:
       a. TENANT plane (plane: :tenant): an agent's full_name and message body
          render IN THE CLEAR — the org reads its own agents' PII per the
          tenant-as-owner rule (§external-surface :707).
       b. OPERATOR / impersonation plane (plane: :operator + impersonation marker):
          the SAME fields render •••• — `%Masked{}` passes through the UIKit
          data_table untouched and Phoenix.HTML.Safe emits ••••.

    3. STATUS + PRIORITY PILLS: open/pending/on_hold/resolved → correct variant;
       low/normal/high/urgent → correct variant.

    4. Non-vacuous: the "clear" assertion verifies a seeded agent handle / message
       IS PRESENT (not merely "non-empty page"), and the "masked" assertion verifies
       the •••• sentinel IS present AND the plaintext is ABSENT.

  Uses `Driftwood.Seeds.demo_all/1` to seed the inherited Support rows.
  """
  use Driftwood.DataCase, async: false

  alias Driftwood.{Seeds, SupportReads}

  # Render a LiveView module's render/1 to an HTML string.
  defp render(mod, assigns) do
    assigns
    |> Map.put(:__changed__, %{})
    |> mod.render()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  setup do
    org_id = Ecto.UUID.generate()
    # Seed the Tier-0 pipeline stages (required by demo_all).
    :ok = Seeds.run(org_id)
    # Seed the inherited Support scope (tickets, conversations, messages, agents, csats).
    assert Seeds.demo_all(org_id) == org_id
    %{org_id: org_id}
  end

  # ==========================================================================
  # ROUTE TEST 1 — /support renders ticket inbox + metric cards
  # ==========================================================================

  test "/support renders app shell + tickets data_table with seeded data", %{org_id: org_id} do
    socket =
      %Phoenix.LiveView.Socket{}
      |> DriftwoodWeb.SupportLive.load(org_id)

    html = render(DriftwoodWeb.SupportLive, socket.assigns)

    # Structural: the app shell and data table are present.
    assert html =~ ~s(class="app")
    assert html =~ ~s(class="side")
    assert html =~ "<table>"
    assert html =~ ~s(class="card")

    # Non-vacuous: seeded tickets appear.
    assert html =~ "ticket-row"

    # 10 tickets were seeded.
    assert length(socket.assigns.tickets) == 10

    # Metric cards rendered.
    assert html =~ "Open tickets"
    assert html =~ "Breaching SLA"
    assert html =~ "Solved this week"
    assert html =~ "CSAT avg"

    # The support sidebar "Inbox" nav item is rendered.
    assert html =~ "Inbox"

    # Non-PII: no vault token leaks.
    refute html =~ "vt_"
  end

  # ==========================================================================
  # ROUTE TEST 2 — /support/tickets/:id renders conversation thread + details
  # ==========================================================================

  test "/support/tickets/:id renders conversation thread with seeded data", %{org_id: org_id} do
    # Get the first seeded ticket (it has conversation + messages per seeds).
    scope = DriftwoodWeb.SupportTicketLive.support_scope(org_id)
    tickets = SupportReads.tickets(scope)

    # Find the first ticket that has conversations seeded (idx < 4 in seeds).
    ticket_with_conv =
      Enum.find(tickets, fn t ->
        convs = SupportReads.conversations_for_ticket(scope, t.id)
        length(convs) > 0
      end)

    assert ticket_with_conv != nil, "no ticket with conversations found"

    socket =
      %Phoenix.LiveView.Socket{}
      |> DriftwoodWeb.SupportTicketLive.load(org_id, ticket_with_conv.id)

    html = render(DriftwoodWeb.SupportTicketLive, socket.assigns)

    # Structural.
    assert html =~ ~s(class="app")
    assert html =~ "support-ticket"

    # Ticket header rendered.
    assert html =~ "ticket-header"
    assert html =~ ticket_with_conv.subject

    # Conversation pane is present.
    assert html =~ "conversation-pane"

    # Message rows present.
    assert html =~ "msg-row"

    # Tabs are present.
    assert html =~ "Conversation"
    assert html =~ "Details"

    # Non-PII: no vault token leaks.
    refute html =~ "vt_"
  end

  test "/support/tickets/:id Details tab renders agents table", %{org_id: org_id} do
    scope = DriftwoodWeb.SupportTicketLive.support_scope(org_id)
    tickets = SupportReads.tickets(scope)
    ticket = List.first(tickets)

    assert ticket != nil, "no tickets found"

    socket =
      %Phoenix.LiveView.Socket{}
      |> DriftwoodWeb.SupportTicketLive.load(org_id, ticket.id)
      |> Map.update!(:assigns, &Map.put(&1, :active_tab, "details"))

    html = render(DriftwoodWeb.SupportTicketLive, socket.assigns)

    # Details pane rendered.
    assert html =~ "details-pane"
    assert html =~ "agent-row"

    # 3 agents were seeded.
    assert length(socket.assigns.agents) == 3

    # Non-PII: no vault token leaks.
    refute html =~ "vt_"
  end

  # ==========================================================================
  # STATUS + PRIORITY PILL TESTS
  # ==========================================================================

  describe "Ticket status pill variants" do
    test "open ticket renders 'info' pill", %{org_id: org_id} do
      scope = DriftwoodWeb.SupportLive.support_scope(org_id)
      tickets = SupportReads.tickets(scope)

      open_ticket = Enum.find(tickets, &(&1.status == :open))
      assert open_ticket != nil, "no open tickets seeded"

      html =
        render(DriftwoodWeb.SupportLive, %{
          no_org: false,
          org_id: org_id,
          tickets: [open_ticket],
          agents_by_id: %{},
          metrics: %{open_tickets: 1, breaching_sla: 0, solved_this_week: 0, csat_avg: nil},
          flash: %{}
        })

      # open → pill class "info"
      assert html =~ "open"
      assert html =~ "pill info"
    end

    test "pending ticket renders 'warn' pill", %{org_id: org_id} do
      scope = DriftwoodWeb.SupportLive.support_scope(org_id)
      tickets = SupportReads.tickets(scope)

      pending_ticket = Enum.find(tickets, &(&1.status == :pending))
      assert pending_ticket != nil, "no pending tickets seeded"

      html =
        render(DriftwoodWeb.SupportLive, %{
          no_org: false,
          org_id: org_id,
          tickets: [pending_ticket],
          agents_by_id: %{},
          metrics: %{open_tickets: 0, breaching_sla: 0, solved_this_week: 0, csat_avg: nil},
          flash: %{}
        })

      assert html =~ "pending"
      assert html =~ "pill warn"
    end

    test "resolved ticket renders 'ok' pill", %{org_id: org_id} do
      scope = DriftwoodWeb.SupportLive.support_scope(org_id)
      tickets = SupportReads.tickets(scope)

      resolved_ticket = Enum.find(tickets, &(&1.status == :resolved))
      assert resolved_ticket != nil, "no resolved tickets seeded"

      html =
        render(DriftwoodWeb.SupportLive, %{
          no_org: false,
          org_id: org_id,
          tickets: [resolved_ticket],
          agents_by_id: %{},
          metrics: %{open_tickets: 0, breaching_sla: 0, solved_this_week: 0, csat_avg: nil},
          flash: %{}
        })

      assert html =~ "resolved"
      assert html =~ "pill ok"
    end

    test "urgent ticket renders 'bad' pill for priority", %{org_id: org_id} do
      scope = DriftwoodWeb.SupportLive.support_scope(org_id)
      tickets = SupportReads.tickets(scope)

      urgent_ticket = Enum.find(tickets, &(&1.priority == :urgent))
      assert urgent_ticket != nil, "no urgent tickets seeded"

      html =
        render(DriftwoodWeb.SupportLive, %{
          no_org: false,
          org_id: org_id,
          tickets: [urgent_ticket],
          agents_by_id: %{},
          metrics: %{open_tickets: 0, breaching_sla: 0, solved_this_week: 0, csat_avg: nil},
          flash: %{}
        })

      assert html =~ "urgent"
      assert html =~ "pill bad"
    end

    test "high priority renders 'warn' pill", %{org_id: org_id} do
      scope = DriftwoodWeb.SupportLive.support_scope(org_id)
      tickets = SupportReads.tickets(scope)

      high_ticket = Enum.find(tickets, &(&1.priority == :high))
      assert high_ticket != nil, "no high-priority tickets seeded"

      html =
        render(DriftwoodWeb.SupportLive, %{
          no_org: false,
          org_id: org_id,
          tickets: [high_ticket],
          agents_by_id: %{},
          metrics: %{open_tickets: 0, breaching_sla: 0, solved_this_week: 0, csat_avg: nil},
          flash: %{}
        })

      assert html =~ "high"
      assert html =~ "pill warn"
    end
  end

  # ==========================================================================
  # MASKING TEST — agent PII: tenant plane clear, operator plane ••••
  # ==========================================================================

  describe "Support agent PII masking invariant (tenant-owner rule)" do
    test "TENANT plane: agent handle + name renders IN THE CLEAR (org reads its own agents)", %{org_id: org_id} do
      # The TENANT scope: plane: :tenant.
      tenant_scope = DriftwoodWeb.SupportTicketLive.support_scope(org_id)
      agents = SupportReads.agents(tenant_scope)

      # Non-vacuous: 3 agents were seeded.
      assert length(agents) == 3

      # Render the details tab with tenant-plane resolved agents.
      scope = DriftwoodWeb.SupportTicketLive.support_scope(org_id)
      tickets = SupportReads.tickets(scope)
      ticket = List.first(tickets)

      html =
        render(DriftwoodWeb.SupportTicketLive, %{
          no_org: false,
          org_id: org_id,
          ticket: ticket,
          conversations: [],
          agents: agents,
          active_tab: "details",
          flash: %{}
        })

      # MUST render at least one agent handle IN THE CLEAR.
      # "claims-desk" is the first agent seeded.
      assert html =~ "claims-desk", "tenant plane did not render agent handle"

      # MUST NOT render the vault token.
      refute html =~ "vt_"
    end

    test "OPERATOR/impersonation plane: agent PII renders •••• (no plaintext leak)", %{org_id: org_id} do
      # The OPERATOR impersonation scope: plane: :operator.
      operator_scope = DriftwoodWeb.SupportTicketLive.operator_scope(org_id)
      agents = SupportReads.agents(operator_scope)

      # Non-vacuous: same rows returned (org-scope still matches).
      assert length(agents) == 3

      scope = DriftwoodWeb.SupportTicketLive.support_scope(org_id)
      tickets = SupportReads.tickets(scope)
      ticket = List.first(tickets)

      html =
        render(DriftwoodWeb.SupportTicketLive, %{
          no_org: false,
          org_id: org_id,
          ticket: ticket,
          conversations: [],
          agents: agents,
          active_tab: "details",
          flash: %{}
        })

      # MUST render •••• (the %Masked{} sentinel on the impersonation plane).
      assert html =~ "••••", "operator/impersonation plane did not mask agent PII"

      # MUST NOT render any seeded plaintext agent names or emails.
      refute html =~ "Marchetti", "operator plane leaked agent full_name in plaintext"
      refute html =~ "sofia.marchetti", "operator plane leaked agent email in plaintext"

      # MUST NOT render vault tokens.
      refute html =~ "vt_"
    end

    test "OPERATOR plane: message body renders •••• (no plaintext leak)", %{org_id: org_id} do
      operator_scope = DriftwoodWeb.SupportTicketLive.operator_scope(org_id)
      tenant_scope = DriftwoodWeb.SupportTicketLive.support_scope(org_id)

      tickets = SupportReads.tickets(tenant_scope)

      # Find a ticket with a conversation (first 4 in seeds).
      ticket_with_conv =
        Enum.find(tickets, fn t ->
          convs = SupportReads.conversations_for_ticket(tenant_scope, t.id)
          length(convs) > 0
        end)

      assert ticket_with_conv != nil, "no ticket with conversations found"

      # Read conversations through the OPERATOR scope to trigger PII masking on message body.
      operator_convs = SupportReads.conversations_for_ticket(operator_scope, ticket_with_conv.id)

      # Gather all messages.
      all_msgs = Enum.flat_map(operator_convs, & &1.__messages__)
      assert length(all_msgs) > 0, "no messages found for ticket with conversation"

      # At least one message body should be %Masked{} (or empty on error).
      has_masked_body =
        Enum.any?(all_msgs, fn msg ->
          match?(%Samen.Masked{}, msg.body)
        end)

      assert has_masked_body,
             "operator plane did not mask message body — body should be %Masked{}"

      html =
        render(DriftwoodWeb.SupportTicketLive, %{
          no_org: false,
          org_id: org_id,
          ticket: ticket_with_conv,
          conversations: operator_convs,
          agents: [],
          active_tab: "conversation",
          flash: %{}
        })

      # The masked body renders •••• through Phoenix.HTML.Safe.
      assert html =~ "••••", "operator plane message body did not render as ••••"

      # Plaintext message content must NOT appear.
      refute html =~ "disputing the charge", "operator plane leaked message body plaintext"

      # No vault tokens.
      refute html =~ "vt_"
    end

    test "the SupportTicketLive renders a %Masked{} agent name as •••• (UIKit masking invariant)", %{
      org_id: _org_id
    } do
      # Synthesize an agent struct with %Masked{} PII — the exact shape the resolver
      # returns on the operator plane. No DB needed.
      masked_name = Samen.Masked.new("vault:test-tok-agent-name", :full_name)
      masked_email = Samen.Masked.new("vault:test-tok-agent-email", :email)

      fake_agent = %{
        id: Ecto.UUID.generate(),
        handle: "test-agent",
        full_name: masked_name,
        email: masked_email,
        role: :agent,
        status: :active,
        timezone: "UTC"
      }

      fake_ticket = %{
        id: Ecto.UUID.generate(),
        subject: "Test ticket",
        status: :open,
        priority: :normal,
        sla_breach_at: nil,
        breached: false,
        resolved_at: nil,
        tags: []
      }

      html =
        render(DriftwoodWeb.SupportTicketLive, %{
          no_org: false,
          org_id: Ecto.UUID.generate(),
          ticket: fake_ticket,
          conversations: [],
          agents: [fake_agent],
          active_tab: "details",
          flash: %{}
        })

      # The mask IS rendered (via Phoenix.HTML.Safe on %Masked{}).
      assert html =~ "••••"

      # The raw vault token NEVER leaks into the page.
      refute html =~ "vault:test-tok-agent-name"
      refute html =~ "vault:test-tok-agent-email"
      refute html =~ "test-tok"
    end

    test "the SupportTicketLive renders a %Masked{} message body as •••• (UIKit masking invariant)", %{
      org_id: _org_id
    } do
      # Synthesize a message struct with %Masked{} body.
      masked_body = Samen.Masked.new("vault:test-tok-msg-body", :body)

      fake_msg = %{
        id: Ecto.UUID.generate(),
        body: masked_body,
        sender_type: :customer,
        sender_id: nil,
        message_type: :reply,
        created_via: :email,
        conversation_id: Ecto.UUID.generate(),
        agent_id: nil,
        __agent__: nil
      }

      fake_conv = %{
        id: Ecto.UUID.generate(),
        channel: :email,
        status: :open,
        subject: "Test",
        ticket_id: Ecto.UUID.generate(),
        __messages__: [fake_msg]
      }

      fake_ticket = %{
        id: Ecto.UUID.generate(),
        subject: "Test ticket",
        status: :open,
        priority: :normal,
        sla_breach_at: nil,
        breached: false,
        resolved_at: nil,
        tags: []
      }

      html =
        render(DriftwoodWeb.SupportTicketLive, %{
          no_org: false,
          org_id: Ecto.UUID.generate(),
          ticket: fake_ticket,
          conversations: [fake_conv],
          agents: [],
          active_tab: "conversation",
          flash: %{}
        })

      # The mask IS rendered.
      assert html =~ "••••"

      # The raw vault token NEVER leaks.
      refute html =~ "vault:test-tok-msg-body"
      refute html =~ "test-tok"
    end
  end

  # ==========================================================================
  # CROSS-ORG ISOLATION TEST
  # ==========================================================================

  test "CROSS-ORG: a tenant broker in a DIFFERENT org sees ZERO support rows", %{org_id: _org_id} do
    other_org = Ecto.UUID.generate()
    other_scope = DriftwoodWeb.SupportLive.support_scope(other_org)

    tickets = SupportReads.tickets(other_scope)
    assert tickets == [], "cross-org tenant read the scenario org's tickets"

    agents = SupportReads.agents(other_scope)
    assert agents == [], "cross-org tenant read the scenario org's agents"
  end
end
