defmodule Samen.Web.SupportTicketsCrudTest do
  @moduledoc """
  A3 WIRING (billing-support batch) — `Samen.Web.Support.TicketsLive` on the A2 kit
  contract (`ListLive` + `list_view` + `simple_form`/`modal`/`delete_confirm`). The
  ticket header is non-PII (agent PII masking on this page is asserted in
  `support_render_test.exs`, which exercises the SAME render path):

    * **CRUD (AC-G1-1/2)** — "New ticket" is a REAL button opening the modal +
      `simple_form`; an INVALID submit (missing required subject) renders inline
      errors and persists NOTHING; a VALID submit persists + refreshes the bounded
      inbox; each row carries `delete_confirm/1` — deleting a ticket with linked
      conversations now ARCHIVES it (ADR-040 §5.9/T37f: `Ticket` is `archivable
      true`, the cascade PARENT of `ticket ▸cascade conversation ▸cascade message`,
      §5.4), cascading the archive to its conversation/message at the same instant,
      superseding the old hard-delete FK-refusal.
    * **Bounded read (AC-G1-5)** — `tickets_page/3` passes `bounded!/4` non-vacuously;
      a 55-ticket org NEVER loads the full set; keyset next/prev + sort + filter work
      on the REAL page; the sort red path refuses an undeclared field.
    * **Operator posture (belt)** — no write affordance in the operator DOM.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.ListLive
  alias Samen.Web.Mount
  alias Samen.Web.Reads, as: WebReads
  alias Samen.Web.Support.Reads
  alias Samen.Web.Support.TicketsLive

  # -- harness -------------------------------------------------------------------

  defp mount_socket(org_id, plane_opts \\ []) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, build_mount(:support, plane_opts))
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> Phoenix.Component.assign(:return_to, nil)
    |> TicketsLive.load(org_id)
  end

  defp html(socket), do: render_html(TicketsLive, socket.assigns)

  defp event(socket, name, params) do
    {:noreply, socket} = TicketsLive.handle_event(name, params, socket)
    socket
  end

  defp list_event(socket, name, params) do
    {:noreply, socket} = ListLive.handle_list_event(name, params, socket)
    socket
  end

  defp ticket_count(org_id) do
    Samen.WebTest.Support.Ticket
    |> Ash.Query.ensure_selected([:org_id])
    |> Ash.read!(authorize?: false)
    |> Enum.count(&(&1.org_id == org_id))
  end

  defp seed_tickets(org_id, n) do
    for i <- 1..n do
      Samen.WebTest.Support.Ticket
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          subject: "Ticket #{String.pad_leading(to_string(i), 2, "0")}",
          status: :open,
          priority: :normal
        },
        authorize?: false
      )
      |> Ash.create!()
    end
  end

  # ---------------------------------------------------------------------------
  # Create — green + red (AC-G1-1/2)
  # ---------------------------------------------------------------------------

  test "New ticket opens the modal; a VALID submit persists and refreshes the bounded inbox" do
    org_id = Ash.UUID.generate()
    socket = mount_socket(org_id)

    rendered = html(socket)
    assert rendered =~ ~s(id="new-ticket")
    assert rendered =~ ~s(phx-click="new_ticket")

    socket = event(socket, "new_ticket", %{})
    rendered = html(socket)
    assert rendered =~ ~s(role="dialog")
    assert rendered =~ ~s(id="new-ticket-form")
    assert rendered =~ ~s(name="form[subject]")

    socket =
      event(socket, "save_new", %{"form" => %{"subject" => "Pallet arrived crushed", "priority" => "high"}})

    refute socket.assigns.show_new
    assert ticket_count(org_id) == 1
    rendered = html(socket)
    assert rendered =~ "Pallet arrived crushed"
    assert rendered =~ "high"
  end

  test "RED PATH (AC-G1-2): an INVALID submit (missing required subject) shows inline errors and persists NOTHING" do
    org_id = Ash.UUID.generate()
    socket = mount_socket(org_id) |> event("new_ticket", %{})

    socket = event(socket, "save_new", %{"form" => %{"subject" => "", "priority" => "low"}})

    assert socket.assigns.show_new
    rendered = html(socket)
    assert rendered =~ "field-invalid"
    assert rendered =~ "field-error"
    assert ticket_count(org_id) == 0
    assert socket.assigns.page.items == []
  end

  # ---------------------------------------------------------------------------
  # Delete — interlock + ADR-040 §5.9/T37f archive cascade
  # ---------------------------------------------------------------------------

  test "delete archives a bare ticket; a ticket with conversations ALSO archives, cascading to its conversation/message" do
    %{org_id: org_id, support: %{ticket: linked_ticket, conversation: conversation, message: message}} =
      Seeds.seed_all()

    [bare_ticket] = seed_tickets(org_id, 1)

    socket = mount_socket(org_id)
    rendered = html(socket)
    assert rendered =~ ~s(data-confirm="Delete this record? This cannot be undone.")
    assert rendered =~ ~s(phx-value-id="#{bare_ticket.id}")

    socket = event(socket, "delete", %{"id" => bare_ticket.id})
    assert ticket_count(org_id) == 1
    refute bare_ticket.id in Enum.map(socket.assigns.page.items, & &1.id)

    # ADR-040 §5.9/T37f: a ticket with a linked conversation/message is no longer
    # refused — it archives (dropping out of the bounded list), cascading the
    # archive to its conversation AND message at the same instant.
    socket = event(socket, "delete", %{"id" => linked_ticket.id})
    assert ticket_count(org_id) == 0
    refute html(socket) =~ "Could not delete this ticket"
    refute linked_ticket.id in Enum.map(socket.assigns.page.items, & &1.id)

    live_conversation_ids =
      Samen.WebTest.Support.Conversation
      |> Ash.Query.ensure_selected([:id])
      |> Ash.read!(authorize?: false)
      |> Enum.map(& &1.id)

    live_message_ids =
      Samen.WebTest.Support.Message
      |> Ash.Query.ensure_selected([:id])
      |> Ash.read!(authorize?: false)
      |> Enum.map(& &1.id)

    refute conversation.id in live_conversation_ids
    refute message.id in live_message_ids
  end

  # ---------------------------------------------------------------------------
  # Bounded read + list ergonomics on the REAL page (AC-G1-5 / AC-G1-3)
  # ---------------------------------------------------------------------------

  test "a 55-ticket org NEVER loads the full set; keyset next/prev, sort, and filter work; undeclared sort refused" do
    org_id = Ash.UUID.generate()
    seed_tickets(org_id, 55)
    mount = build_mount(:support)
    scope = Mount.scope(mount, org_id)

    assert :ok == WebReads.bounded!(&Reads.tickets_page/3, mount, scope, page_size: 10)

    socket = mount_socket(org_id)
    assert length(socket.assigns.page.items) == WebReads.default_page_size()
    assert socket.assigns.page.has_more
    refute html(socket) =~ "Ticket 51"

    socket = list_event(socket, "paginate", %{"dir" => "next"})
    assert length(socket.assigns.page.items) == 5
    refute socket.assigns.page.has_more

    socket = list_event(socket, "paginate", %{"dir" => "prev"})
    assert length(socket.assigns.page.items) == WebReads.default_page_size()

    # Sort toggle + the undeclared-field red path (no atom minting).
    socket = list_event(socket, "sort", %{"field" => "subject"})
    assert socket.assigns.list_state.sort == {:subject, :desc}
    before_state = socket.assigns.list_state
    socket = list_event(socket, "sort", %{"field" => "org_id"})
    assert socket.assigns.list_state == before_state

    # Filter narrows server-side.
    socket = list_event(socket, "filter", %{"filter" => "Ticket 07"})
    assert Enum.map(socket.assigns.page.items, & &1.subject) == ["Ticket 07"]
  end

  test "zero rows render the kit-default empty_state" do
    org_id = Ash.UUID.generate()
    socket = mount_socket(org_id)
    assert socket.assigns.page.items == []
    assert html(socket) =~ "empty-state"
  end

  # ---------------------------------------------------------------------------
  # Operator posture (belt)
  # ---------------------------------------------------------------------------

  test "OPERATOR plane: no create/delete affordance; the inbox still renders" do
    %{org_id: org_id} = Seeds.seed_all()
    socket = mount_socket(org_id, plane: :operator, target_org_id: org_id)

    rendered = html(socket)
    # Non-vacuous: the seeded ticket row renders (header is non-PII).
    assert rendered =~ "ticket-row"
    assert rendered =~ "Missing rate confirmation"
    refute rendered =~ ~s(phx-click="new_ticket")
    refute rendered =~ ~s(phx-click="delete")
    refute rendered =~ "data-confirm"
    refute rendered =~ "vt_"
  end
end
