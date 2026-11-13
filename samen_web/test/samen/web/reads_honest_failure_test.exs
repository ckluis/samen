defmodule Samen.Web.ReadsHonestFailureTest do
  @moduledoc """
  WP6 phase 1 — "a failed read never renders as empty", proven screen by screen.

  For every adopted screen (CRM, Search, Support) the read is made to FAIL through the real
  failure path (`inject_read_faults/1`: `Samen.Web.Reads.Guard`'s test seam raises inside the
  named read, exactly where a database error would) and the screen must:

    * render the kit error state (`error-state`, `role="alert"`, generic copy),
    * NOT render its empty-state copy or its create CTA (the duplicate-creating one),
    * stay alive (the load returns a socket and the render succeeds),
    * recover on retry once the fault is cleared;

  paired with a POSITIVE CONTROL: a genuinely empty result still renders the real empty state.
  A detail screen keeps 404 semantics for a genuinely missing record. The masking suites stay
  green because the error state is value-free (asserted: no vault token in any error DOM).
  """
  use Samen.WebTest.DataCase, async: false

  import ExUnit.CaptureLog

  alias Samen.Web.CRM.{
    CalendarLive,
    CompaniesLive,
    CompanyLive,
    ContactLive,
    ContactsGalleryLive,
    ContactsLive,
    DashboardLive,
    MailboxLive,
    PipelineLive,
    SequencesLive
  }

  alias Samen.Web.ListLive
  alias Samen.Web.Reads.Guard
  alias Samen.Web.Search.SearchLive
  alias Samen.Web.Support.{TicketLive, TicketsLive}

  # -- harness (same shape as the existing render suites) ----------------------------------

  defp socket_for(module, mount, load_args, extra \\ []) do
    base =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(:samen_mount, mount)
      |> Phoenix.Component.assign(:samen_acting_as, false)
      |> Phoenix.Component.assign(:return_to, nil)
      |> Phoenix.Component.assign(extra)

    apply(module, :load, [base | load_args])
  end

  defp html(module, socket), do: render_html(module, socket.assigns)

  defp event(module, socket, name, params \\ %{}) do
    {:noreply, socket} = module.handle_event(name, params, socket)
    socket
  end

  defp list_event(socket, name, params \\ %{}) do
    {:noreply, socket} = ListLive.handle_list_event(name, params, socket)
    socket
  end

  # Run `fun` (a screen load/event under an injected fault) and return its result; the
  # one-line failure log it emits is swallowed (the log contract is asserted in reads_guard_test).
  defp failing(fun), do: fun |> with_log() |> elem(0)

  # The kit error state, value-free: never a vault token, never a masked/plain field value.
  # `:page` = the whole page carries no field value at all (nothing else loaded); `:section` = a
  # loaded header may legitimately show the (tenant-plane, clear) contact, so only the vault
  # token is refuted page-wide.
  defp assert_error_state(html, scope \\ :page) do
    assert html =~ "error-state"
    assert html =~ ~s(role="alert")
    assert html =~ "Nothing was lost"
    refute html =~ "vt_"

    if scope == :page do
      refute html =~ Seeds.contact_email()
      refute html =~ Seeds.contact_full_name()
    end
  end

  defp refute_error_state(html), do: refute(html =~ "error-state")

  defp seed_people(n) do
    org_id = Ash.UUID.generate()

    for i <- 1..n do
      Samen.WebTest.Crm.Person
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: org_id, display_name: "Contact #{String.pad_leading(to_string(i), 2, "0")}", job_title: "Broker"},
        authorize?: false
      )
      |> Ash.create!()
    end

    org_id
  end

  setup do
    seeded = Seeds.seed_all()

    %{
      org_id: seeded.org_id,
      contact_id: seeded.crm.person.id,
      company_id: seeded.crm.company.id,
      ticket_id: seeded.support.ticket.id
    }
  end

  # ===========================================================================
  # ListLive (audit F07) — contacts / companies / tickets ride the same path
  # ===========================================================================

  describe "ListLive — a failed read keeps the page, the filter and the selection; retry re-runs it" do
    test "contacts: the first read fails → error state, no empty copy, no create CTA; retry recovers" do
      org_id = seed_people(3)
      mount = build_mount(:crm)
      inject_read_faults([:crm_contacts_page])

      socket = failing(fn -> socket_for(ContactsLive, mount, [org_id]) end)
      rendered = html(ContactsLive, socket)

      assert_error_state(rendered)
      refute rendered =~ "No contacts yet."
      refute rendered =~ "empty-new-contact"
      refute rendered =~ "Contact 01"
      assert socket.assigns.list_error

      clear_read_faults()
      socket = list_event(socket, "list_retry")
      rendered = html(ContactsLive, socket)

      refute_error_state(rendered)
      assert socket.assigns.list_error == nil
      assert rendered =~ "Contact 01"
    end

    test "contacts: a failed re-read (filter) keeps the previous page, the typed filter and the selection" do
      org_id = seed_people(3)
      mount = build_mount(:crm)
      socket = socket_for(ContactsLive, mount, [org_id])
      [first | _] = socket.assigns.page.items
      socket = list_event(socket, "select", %{"id" => first.id})
      before_ids = Enum.map(socket.assigns.page.items, & &1.id)

      inject_read_faults([:crm_contacts_page])
      socket = failing(fn -> list_event(socket, "filter", %{"filter" => "Contact 02"}) end)

      assert socket.assigns.list_error
      # The previous page is kept (never replaced by an empty one) …
      assert Enum.map(socket.assigns.page.items, & &1.id) == before_ids
      # … and what the user typed / ticked survives.
      assert socket.assigns.list_state.filter == "Contact 02"
      assert MapSet.member?(socket.assigns.list_state.selected, first.id)

      rendered = html(ContactsLive, socket)
      assert_error_state(rendered)
      assert rendered =~ ~s(value="Contact 02")
      refute rendered =~ "No matches"
      refute rendered =~ "No contacts yet."

      clear_read_faults()
      socket = list_event(socket, "list_retry")
      assert socket.assigns.list_error == nil
      assert Enum.map(socket.assigns.page.items, & &1.display_name) == ["Contact 02"]
      assert MapSet.member?(socket.assigns.list_state.selected, first.id)
    end

    test "a reads function that RAISES outright no longer crashes the LiveView (F07)" do
      org_id = seed_people(2)
      mount = build_mount(:crm)
      socket = socket_for(ContactsLive, mount, [org_id])

      # Fault the VIEW itself: the ListLive wrapper's own guard, not the read's.
      inject_read_faults([ContactsLive])
      socket = failing(fn -> list_event(socket, "paginate", %{"dir" => "next"}) end)
      socket = failing(fn -> list_event(socket, "filter", %{"filter" => "x"}) end)

      assert socket.assigns.list_error
      assert_error_state(html(ContactsLive, socket))
    end

    test "masking: on the operator plane the error DOM prints no value, masked or clear, and no token",
         %{org_id: org_id} do
      mount = build_mount(:crm, plane: :operator, target_org_id: org_id)
      inject_read_faults([:crm_contacts_page])

      rendered = ContactsLive |> html(failing(fn -> socket_for(ContactsLive, mount, [org_id]) end))

      assert_error_state(rendered)
      refute rendered =~ "pii_"
      # Non-vacuous: with the fault cleared the same page does render the masked rows.
      clear_read_faults()
      assert html(ContactsLive, socket_for(ContactsLive, mount, [org_id])) =~ "••••"
    end

    test "POSITIVE CONTROL: a genuinely empty org still renders the real empty state and its CTA" do
      mount = build_mount(:crm)
      socket = socket_for(ContactsLive, mount, [Ash.UUID.generate()])
      rendered = html(ContactsLive, socket)

      assert rendered =~ "No contacts yet."
      assert rendered =~ "empty-new-contact"
      refute_error_state(rendered)
      assert socket.assigns.list_error == nil
    end

    test "companies: failed page read AND a failed metric each show their own error; empty stays empty" do
      org_id = Ash.UUID.generate()
      mount = build_mount(:crm)

      assert html(CompaniesLive, socket_for(CompaniesLive, mount, [org_id])) =~ "No companies yet."

      inject_read_faults([:crm_companies_page, :crm_metric_companies])
      socket = failing(fn -> socket_for(CompaniesLive, mount, [org_id]) end)
      rendered = html(CompaniesLive, socket)

      assert_error_state(rendered)
      refute rendered =~ "No companies yet."
      refute rendered =~ "empty-new-company"
      assert rendered =~ "metric-error"
      assert socket.assigns.metric_errors == [:companies]

      clear_read_faults()
      socket = list_event(socket, "list_retry")
      assert html(CompaniesLive, socket) =~ "No companies yet."
    end

    test "tickets: failed page read → error state, not the empty inbox; metrics fail tile by tile", %{org_id: org_id} do
      mount = build_mount(:support)
      inject_read_faults([:support_tickets_page, :support_metric_breaching_sla, :support_agents])
      socket = failing(fn -> socket_for(TicketsLive, mount, [org_id]) end)
      rendered = html(TicketsLive, socket)

      assert_error_state(rendered)
      refute rendered =~ "No tickets yet."
      refute rendered =~ "empty-new-ticket"
      assert socket.assigns.metric_errors == [:breaching_sla]
      assert rendered =~ "metric-error"
      # The assignee column says so rather than rendering "—" (= "unassigned").
      assert socket.assigns.agents_by_id == :unavailable

      clear_read_faults()
      socket = list_event(socket, "list_retry")
      rendered = html(TicketsLive, socket)
      refute_error_state(rendered)
      assert rendered =~ "ticket-row"
    end

    test "tickets POSITIVE CONTROL: an empty inbox still renders the empty state" do
      mount = build_mount(:support)
      rendered = html(TicketsLive, socket_for(TicketsLive, mount, [Ash.UUID.generate()]))
      assert rendered =~ "No tickets yet."
      assert rendered =~ "empty-new-ticket"
      refute_error_state(rendered)
    end
  end

  # ===========================================================================
  # CRM — gallery, detail screens, pipeline, calendar, dashboard, sequences, mailbox
  # ===========================================================================

  describe "CRM gallery" do
    test "failed read → error state, not 'No contacts yet.'; retry recovers; empty stays empty", %{org_id: org_id} do
      mount = build_mount(:crm)
      assert html(ContactsGalleryLive, socket_for(ContactsGalleryLive, mount, [Ash.UUID.generate()])) =~ "No contacts yet."

      inject_read_faults([:crm_contacts_gallery])
      socket = failing(fn -> socket_for(ContactsGalleryLive, mount, [org_id]) end)
      rendered = html(ContactsGalleryLive, socket)

      assert_error_state(rendered)
      refute rendered =~ "No contacts yet."

      clear_read_faults()
      socket = event(ContactsGalleryLive, socket, "retry_load")
      rendered = html(ContactsGalleryLive, socket)
      refute_error_state(rendered)
      assert rendered =~ "contact-card-"
    end
  end

  describe "CRM contact detail" do
    test "a FAILED read is the error state — not 'Contact not found.'; retry recovers", %{org_id: org_id, contact_id: contact_id} do
      mount = build_mount(:crm)
      inject_read_faults([:crm_get_contact])
      socket = failing(fn -> socket_for(ContactLive, mount, [org_id, contact_id]) end)
      rendered = html(ContactLive, socket)

      assert_error_state(rendered)
      refute rendered =~ "Contact not found."
      refute rendered =~ "edit-contact"

      clear_read_faults()
      socket = event(ContactLive, socket, "retry_load")
      rendered = html(ContactLive, socket)
      refute_error_state(rendered)
      assert rendered =~ "contact-header"
    end

    test "404 semantics survive: a genuinely missing (or malformed) id is 'Contact not found.'", %{org_id: org_id} do
      mount = build_mount(:crm)

      for id <- [Ash.UUID.generate(), "not-a-uuid"] do
        rendered = html(ContactLive, socket_for(ContactLive, mount, [org_id, id]))
        assert rendered =~ "Contact not found."
        refute_error_state(rendered)
      end
    end

    test "a failed activity read → the Activity tab shows the error, not 'No activity yet'", %{org_id: org_id, contact_id: contact_id} do
      mount = build_mount(:crm)
      inject_read_faults([:crm_activities_for_person])
      socket = failing(fn -> socket_for(ContactLive, mount, [org_id, contact_id], active_tab: "activity") end)
      rendered = html(ContactLive, socket)

      assert_error_state(rendered, :section)
      refute rendered =~ "No activity yet"
      refute rendered =~ "log-activity-form"
      assert rendered =~ "contact-header"

      clear_read_faults()
      rendered = html(ContactLive, event(ContactLive, socket, "retry_load"))
      refute_error_state(rendered)
      assert rendered =~ "log-activity-form"
    end

    test "a failed deals read → the Deals tab shows the error, not 'No deals yet.'", %{org_id: org_id, contact_id: contact_id} do
      mount = build_mount(:crm)
      inject_read_faults([:crm_opportunities_for_company])
      socket = failing(fn -> socket_for(ContactLive, mount, [org_id, contact_id], active_tab: "deals") end)
      rendered = html(ContactLive, socket)

      assert_error_state(rendered, :section)
      refute rendered =~ "No deals yet."
    end
  end

  describe "CRM company detail" do
    test "a FAILED read is the error state — not 'Company not found.'; retry recovers", %{org_id: org_id, company_id: company_id} do
      mount = build_mount(:crm)
      inject_read_faults([:crm_get_company])
      socket = failing(fn -> socket_for(CompanyLive, mount, [org_id, company_id]) end)
      rendered = html(CompanyLive, socket)

      assert_error_state(rendered)
      refute rendered =~ "Company not found."

      clear_read_faults()
      rendered = html(CompanyLive, event(CompanyLive, socket, "retry_load"))
      refute_error_state(rendered)
      assert rendered =~ "company-header"
    end

    test "404 semantics survive for a genuinely missing company", %{org_id: org_id} do
      rendered = html(CompanyLive, socket_for(CompanyLive, build_mount(:crm), [org_id, Ash.UUID.generate()]))
      assert rendered =~ "Company not found."
      refute_error_state(rendered)
    end

    test "failed contacts / deals / activity reads each show their own error", %{org_id: org_id, company_id: company_id} do
      mount = build_mount(:crm)
      inject_read_faults([:crm_contacts_for_company, :crm_opportunities_for_company, :crm_activities_for_company])

      for tab <- ~w(overview deals activity) do
        socket = failing(fn -> socket_for(CompanyLive, mount, [org_id, company_id], active_tab: tab) end)
        rendered = html(CompanyLive, socket)
        assert_error_state(rendered)
        refute rendered =~ "No deals yet."
        refute rendered =~ "No activity yet"
        assert rendered =~ "company-header"
      end
    end
  end

  describe "CRM pipeline" do
    test "failed board read → error state, not 'No pipeline stages yet.'; retry recovers", %{org_id: org_id} do
      mount = build_mount(:crm)
      inject_read_faults([:crm_pipeline_board, :crm_pipeline_value_cents])
      socket = failing(fn -> socket_for(PipelineLive, mount, [org_id]) end)
      rendered = html(PipelineLive, socket)

      assert_error_state(rendered)
      refute rendered =~ "No pipeline stages yet."
      # The value is an error, not a confident $0.00.
      refute rendered =~ "$0.00"
      assert socket.assigns.value_error

      clear_read_faults()
      rendered = html(PipelineLive, event(PipelineLive, socket, "retry_load"))
      refute_error_state(rendered)
      assert rendered =~ "Chicago → Dallas dry van"
    end

    test "POSITIVE CONTROL: an org with no stages renders the real empty state" do
      rendered = html(PipelineLive, socket_for(PipelineLive, build_mount(:crm), [Ash.UUID.generate()]))
      assert rendered =~ "No pipeline stages yet."
      refute_error_state(rendered)
    end

    test "a failed 'load more' page leaves the column as it was and says so", %{org_id: org_id} do
      mount = build_mount(:crm)
      socket = socket_for(PipelineLive, mount, [org_id])
      board = socket.assigns.board
      key = to_string(hd(board.groups).key)

      inject_read_faults([:crm_pipeline_stage_page])
      socket = failing(fn -> event(PipelineLive, socket, "board_load_more", %{"key" => key}) end)

      assert socket.assigns.board == board
      assert socket.assigns.more_error
      assert html(PipelineLive, socket) =~ "Couldn&#39;t load more"
    end
  end

  describe "CRM calendar" do
    test "failed read → error state, not an empty month; retry recovers", %{org_id: org_id} do
      mount = build_mount(:crm)
      inject_read_faults([:crm_opportunity_calendar])
      socket = failing(fn -> socket_for(CalendarLive, mount, [org_id]) end)
      rendered = html(CalendarLive, socket)

      assert_error_state(rendered)
      refute rendered =~ "opp-ev"

      clear_read_faults()
      rendered = html(CalendarLive, event(CalendarLive, socket, "retry_load"))
      refute_error_state(rendered)
    end
  end

  describe "CRM dashboard (audit F05)" do
    test "one failed tile shows its own error; the other tiles still render", %{org_id: org_id} do
      mount = build_mount(:crm)
      inject_read_faults([:crm_opportunities_by_status])
      socket = failing(fn -> socket_for(DashboardLive, mount, [org_id]) end)
      rendered = html(DashboardLive, socket)

      assert Map.keys(socket.assigns.dash.errors) |> Enum.sort() == [:by_status, :rates]
      assert_error_state(rendered)
      # The independent tiles still render real data.
      assert rendered =~ "dash-value-by-stage"
      assert rendered =~ "Quoted"
      assert rendered =~ "dash-leaderboard"
    end

    test "EVERY read failing no longer crashes mount (the un-rescued safe_dashboard); retry recovers", %{org_id: org_id} do
      mount = build_mount(:crm)
      inject_read_faults(:all)
      socket = failing(fn -> socket_for(DashboardLive, mount, [org_id]) end)
      rendered = html(DashboardLive, socket)

      assert_error_state(rendered)
      assert map_size(socket.assigns.dash.errors) >= 6

      clear_read_faults()
      socket = event(DashboardLive, socket, "retry_load")
      assert socket.assigns.dash.errors == %{}
      refute_error_state(html(DashboardLive, socket))
    end

    test "a failed metric is an error tile, not a confident 0", %{org_id: org_id} do
      inject_read_faults([:crm_metric_pipeline_value])
      socket = failing(fn -> socket_for(DashboardLive, build_mount(:crm), [org_id]) end)
      assert socket.assigns.dash.errors == %{pipeline_value: :unavailable}
      assert html(DashboardLive, socket) =~ "metric-error"
    end
  end

  describe "CRM sequences" do
    test "failed reads → error states, not 'No sequences yet.' / 'No enrollments yet.'; retry recovers" do
      org_id = Ash.UUID.generate()
      mount = build_mount(:crm)

      positive = html(SequencesLive, socket_for(SequencesLive, mount, [org_id]))
      assert positive =~ "No sequences yet."
      assert positive =~ "No enrollments yet."

      inject_read_faults([:crm_sequences, :crm_enrollments])
      socket = failing(fn -> socket_for(SequencesLive, mount, [org_id]) end)
      rendered = html(SequencesLive, socket)

      assert_error_state(rendered)
      refute rendered =~ "No sequences yet."
      refute rendered =~ "No enrollments yet."
      refute rendered =~ "No sequences exist yet"

      clear_read_faults()
      rendered = html(SequencesLive, event(SequencesLive, socket, "retry_load"))
      refute_error_state(rendered)
      assert rendered =~ "No sequences yet."
    end
  end

  describe "CRM mailbox" do
    setup do
      previous = Application.get_env(:samen_core, :mailbox_provider)
      Samen.Mailbox.FakeProvider.reset()
      Samen.Mailbox.FakeProvider.set_capabilities([:inbound_sync, :outbound_send])
      Application.put_env(:samen_core, :mailbox_provider, {Samen.Mailbox.FakeProvider, %{configured: true}})

      on_exit(fn ->
        Samen.Mailbox.FakeProvider.reset()

        case previous do
          nil -> Application.delete_env(:samen_core, :mailbox_provider)
          value -> Application.put_env(:samen_core, :mailbox_provider, value)
        end
      end)

      :ok
    end

    test "a failed connections read does not offer 'Connect mailbox' as if none existed", %{org_id: org_id} do
      mount = build_mount(:crm)
      assert html(MailboxLive, socket_for(MailboxLive, mount, [org_id])) =~ "No mailbox connected yet."

      inject_read_faults([:crm_mailbox_connections])
      socket = failing(fn -> socket_for(MailboxLive, mount, [org_id]) end)
      rendered = html(MailboxLive, socket)

      assert_error_state(rendered)
      refute rendered =~ "No mailbox connected yet."
      refute rendered =~ "mailbox-connect-button"

      clear_read_faults()
      rendered = html(MailboxLive, event(MailboxLive, socket, "retry_load"))
      assert rendered =~ "No mailbox connected yet."
    end
  end

  # ===========================================================================
  # Search (audit F22)
  # ===========================================================================

  describe "Search" do
    defp search_mount do
      Samen.Web.Mount.new(:search, Samen.WebTest.Primitives, Samen.WebTest.Repo,
        plane: Samen.Web.Plane.tenant(),
        labels: %{title: "Test Org"}
      )
    end

    test "a failed engine read is the error state — not 'No matches.'; retry re-runs the same term; recovers" do
      org_id = Ash.UUID.generate()
      inject_read_faults([:search_query])

      socket = failing(fn -> socket_for(SearchLive, search_mount(), [org_id, "invoice"]) end)
      rendered = html(SearchLive, socket)

      assert_error_state(rendered)
      refute rendered =~ "No matches."
      # The term the user typed is kept.
      assert rendered =~ ~s(value="invoice")

      clear_read_faults()
      socket = event(SearchLive, socket, "retry_search")
      rendered = html(SearchLive, socket)
      refute_error_state(rendered)
      assert socket.assigns.q == "invoice"
      # Recovered: the engine ran, found nothing — the HONEST empty result now shows.
      assert rendered =~ "No matches."
    end

    test "POSITIVE CONTROL: a search that matches nothing still says 'No matches.'" do
      rendered = html(SearchLive, socket_for(SearchLive, search_mount(), [Ash.UUID.generate(), "zzzz"]))
      assert rendered =~ "No matches."
      refute_error_state(rendered)
    end
  end

  # ===========================================================================
  # Support ticket detail (audit F08)
  # ===========================================================================

  describe "Support ticket detail" do
    defp ticket_socket(mount, org_id, ticket_id) do
      socket_for(TicketLive, mount, [org_id, ticket_id], org_id: org_id, ticket_id: ticket_id, active_tab: "conversation")
    end

    defp fresh_ticket(org_id) do
      Samen.WebTest.Support.Ticket
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: org_id, subject: "Fresh, no thread", status: :open, priority: :normal},
        actor: %{org_id: org_id, role: :member},
        authorize?: false
      )
      |> Ash.create!()
    end

    test "a FAILED conversations read is NOT 'No conversation thread yet' + Start conversation (F08)", %{org_id: org_id, ticket_id: ticket_id} do
      mount = build_mount(:support)
      inject_read_faults([:support_conversations_for_ticket])
      socket = failing(fn -> ticket_socket(mount, org_id, ticket_id) end)
      rendered = html(TicketLive, socket)

      assert_error_state(rendered)
      refute rendered =~ "No conversation thread yet."
      refute rendered =~ "start-conversation-btn"
      refute rendered =~ "reply-composer"
      # The ticket itself still rendered.
      assert rendered =~ "ticket-header"

      clear_read_faults()
      rendered = html(TicketLive, event(TicketLive, socket, "retry_load"))
      refute_error_state(rendered)
      assert rendered =~ "reply-composer"
    end

    test "POSITIVE CONTROL: a genuinely thread-less ticket still offers 'Start conversation'", %{org_id: org_id} do
      mount = build_mount(:support)
      rendered = html(TicketLive, ticket_socket(mount, org_id, fresh_ticket(org_id).id))
      assert rendered =~ "No conversation thread yet."
      assert rendered =~ "start-conversation-btn"
      refute_error_state(rendered)
    end

    test "a failed ticket read is the error state — not 'Ticket not found.'; a missing ticket is still a 404", %{org_id: org_id, ticket_id: ticket_id} do
      mount = build_mount(:support)
      inject_read_faults([:support_get_ticket])
      socket = failing(fn -> ticket_socket(mount, org_id, ticket_id) end)
      rendered = html(TicketLive, socket)

      assert_error_state(rendered)
      refute rendered =~ "Ticket not found."

      clear_read_faults()
      refute_error_state(html(TicketLive, event(TicketLive, socket, "retry_load")))

      missing = html(TicketLive, ticket_socket(mount, org_id, Ash.UUID.generate()))
      assert missing =~ "Ticket not found."
      refute_error_state(missing)
    end

    test "failed agents / CSAT reads are named on the Details tab", %{org_id: org_id, ticket_id: ticket_id} do
      mount = build_mount(:support)
      inject_read_faults([:support_agents, :support_csat_for_ticket])

      socket =
        failing(fn ->
          socket_for(TicketLive, mount, [org_id, ticket_id], org_id: org_id, ticket_id: ticket_id, active_tab: "details")
        end)

      rendered = html(TicketLive, socket)
      assert rendered =~ "Agents couldn&#39;t be loaded"
      assert rendered =~ "CSAT couldn&#39;t be loaded"
    end
  end

  # An error state never prints a Guard-internal value.
  test "the generic copy is the same constant everywhere (no per-failure detail leaks)" do
    assert Guard.message() =~ "Nothing was lost"
  end
end
