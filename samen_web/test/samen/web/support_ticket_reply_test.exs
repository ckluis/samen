defmodule Samen.Web.SupportTicketReplyTest do
  @moduledoc """
  A3 WIRING (billing-support batch) — the WRITE side of `Samen.Web.Support.TicketLive`
  (🔒 PII: `Message.body` is a vault-routed scalar — the support batch's NEW PII WRITE
  SURFACE), plus the sanctioned ticket STATUS update:

    * **Reply (AC-G1-1/2 + MC-2)** — the composer is a REAL `simple_form`; a VALID
      reply persists through Ash, refreshes the thread, and renders CLEAR on the
      tenant plane; the raw (resolver-bypassing) record carries NO plaintext body
      (the vault write chokepoint). An INVALID submit (garbage message_type) renders
      inline errors and persists NOTHING.
    * **Status (AC-G1-1)** — the status select updates through the sanctioned
      `update: :*`; a garbage status is REFUSED against the BOUNDED enum (no atom is
      ever minted from client input) and the ticket is unchanged.
    * **MC-1 / RP-G1-7 (the write-path red path)** — an operator-plane reply carrying
      a plaintext body is REJECTED at the Ash write path (`Samen.Pii.WriteGuard`); DB
      unchanged. Anti-tautology: the SAME submit on the tenant plane succeeds — the
      rejection discriminates on the plane. The operator DOM also carries no
      composer/status affordance and renders the thread masked (belt).
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Support.TicketLive

  @reply_body "REPLY-SENTINEL: please resend the rate confirmation."

  # -- harness -------------------------------------------------------------------

  defp mount_socket(org_id, ticket_id, plane_opts \\ []) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, build_mount(:support, plane_opts))
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> Phoenix.Component.assign(:return_to, nil)
    |> Phoenix.Component.assign(:org_id, org_id)
    |> Phoenix.Component.assign(:ticket_id, ticket_id)
    |> Phoenix.Component.assign(:active_tab, "conversation")
    |> TicketLive.load(org_id, ticket_id)
  end

  defp html(socket), do: render_html(TicketLive, socket.assigns)

  defp event(socket, name, params) do
    {:noreply, socket} = TicketLive.handle_event(name, params, socket)
    socket
  end

  defp message_count(conversation_id) do
    Samen.WebTest.Support.Message
    |> Ash.Query.ensure_selected([:conversation_id])
    |> Ash.read!(authorize?: false)
    |> Enum.count(&(&1.conversation_id == conversation_id))
  end

  defp raw_messages(conversation_id) do
    Samen.WebTest.Support.Message
    |> Ash.Query.ensure_selected([:conversation_id, :body])
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&(&1.conversation_id == conversation_id))
  end

  # ---------------------------------------------------------------------------
  # Reply — green path (AC-G1-1/2 + MC-2)
  # ---------------------------------------------------------------------------

  test "the reply composer posts through Ash, refreshes the thread, renders clear on tenant, and vault-routes the body (MC-2)" do
    %{org_id: org_id, support: %{ticket: ticket, conversation: conversation}} = Seeds.seed_all()
    socket = mount_socket(org_id, ticket.id)

    rendered = html(socket)
    assert rendered =~ ~s(id="reply-composer")
    assert rendered =~ ~s(id="reply-form")
    assert rendered =~ ~s(name="form[body]")
    before_count = message_count(conversation.id)

    socket =
      event(socket, "save_reply", %{"form" => %{"body" => @reply_body, "message_type" => "reply"}})

    assert message_count(conversation.id) == before_count + 1
    # The refreshed thread renders the new body CLEAR on the tenant plane.
    assert html(socket) =~ @reply_body

    # MC-2: the vaulted body is NOT plaintext at rest — the raw records (no resolver)
    # carry no sentinel fragment. A vault bypass would FAIL here.
    for raw <- raw_messages(conversation.id) do
      refute inspect(raw.body) =~ "REPLY-SENTINEL"
    end
  end

  test "RED PATH (AC-G1-2): an INVALID reply (garbage message_type) shows inline errors and persists NOTHING" do
    %{org_id: org_id, support: %{ticket: ticket, conversation: conversation}} = Seeds.seed_all()
    socket = mount_socket(org_id, ticket.id)
    before_count = message_count(conversation.id)

    socket =
      event(socket, "save_reply", %{"form" => %{"body" => "half a reply", "message_type" => "bogus-type"}})

    rendered = html(socket)
    assert rendered =~ "field-invalid"
    assert rendered =~ "field-error"
    assert message_count(conversation.id) == before_count
  end

  # ---------------------------------------------------------------------------
  # Status — the sanctioned update, with the bounded-enum red path
  # ---------------------------------------------------------------------------

  test "the status select updates the ticket through the sanctioned update; a garbage status is REFUSED (bounded enum)" do
    %{org_id: org_id, support: %{ticket: ticket}} = Seeds.seed_all()
    socket = mount_socket(org_id, ticket.id)

    rendered = html(socket)
    assert rendered =~ ~s(id="ticket-status-form")
    assert rendered =~ ~s(phx-change="set_status")
    assert socket.assigns.ticket.status == :open

    socket = event(socket, "set_status", %{"status" => "resolved"})
    assert socket.assigns.ticket.status == :resolved
    raw = Ash.get!(Samen.WebTest.Support.Ticket, ticket.id, authorize?: false)
    assert raw.status == :resolved

    # RED PATH: client garbage never mints an atom and never lands — refused +
    # surfaced, ticket unchanged.
    socket = event(socket, "set_status", %{"status" => "hacked_status_#{System.unique_integer([:positive])}"})
    assert html(socket) =~ "Could not update the ticket status."
    raw = Ash.get!(Samen.WebTest.Support.Ticket, ticket.id, authorize?: false)
    assert raw.status == :resolved
  end

  # ---------------------------------------------------------------------------
  # MC-1 / RP-G1-7 — the operator plane: DOM belt + write-path suspenders
  # ---------------------------------------------------------------------------

  test "OPERATOR plane: no composer/status affordance in the DOM; the thread renders masked (belt)" do
    %{org_id: org_id, support: %{ticket: ticket}} = Seeds.seed_all()
    socket = mount_socket(org_id, ticket.id, plane: :operator, target_org_id: org_id)

    rendered = html(socket)
    # Non-vacuous: the seeded message renders, masked.
    assert rendered =~ "msg-row"
    assert rendered =~ "••••"
    refute rendered =~ Seeds.message_body()
    # No write affordance offered to the operator.
    refute rendered =~ ~s(id="reply-composer")
    refute rendered =~ ~s(id="ticket-status-form")
    refute rendered =~ ~s(phx-change="set_status")
    # And no token leaks through the (unrendered) form plumbing.
    refute rendered =~ "vt_"
  end

  test "RED PATH (MC-1 / RP-G1-7): an operator-plane reply with a plaintext body is REJECTED at the write path; DB unchanged" do
    %{org_id: org_id, support: %{ticket: ticket, conversation: conversation}} = Seeds.seed_all()
    before_count = message_count(conversation.id)

    # Drive the HANDLER directly on an operator-plane socket — bypassing the hidden
    # composer entirely. The enforcement under test is Samen.Pii.WriteGuard on the
    # Ash write path, NOT the DOM.
    socket = mount_socket(org_id, ticket.id, plane: :operator, target_org_id: org_id)

    socket =
      event(socket, "save_reply", %{
        "form" => %{"body" => "Operator authored plaintext body", "message_type" => "reply"}
      })

    assert message_count(conversation.id) == before_count
    assert AshPhoenix.Form.errors(socket.assigns.reply_form.source) != []

    assert socket.assigns.reply_form.source
           |> AshPhoenix.Form.errors()
           |> inspect() =~ "no-operator-plaintext-write"
  end

  test "ANTI-TAUTOLOGY pairing: the SAME reply on the TENANT plane succeeds — the rejection discriminates on the plane" do
    %{org_id: org_id, support: %{ticket: ticket, conversation: conversation}} = Seeds.seed_all()
    before_count = message_count(conversation.id)
    socket = mount_socket(org_id, ticket.id)

    _socket =
      event(socket, "save_reply", %{
        "form" => %{"body" => "Operator authored plaintext body", "message_type" => "reply"}
      })

    # If the guard rejected regardless of plane (over-block) this would fail; if it
    # never rejected (tautology) the operator red path above would fail instead.
    assert message_count(conversation.id) == before_count + 1
  end
end
