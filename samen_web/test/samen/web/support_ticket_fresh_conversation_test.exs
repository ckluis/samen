defmodule Samen.Web.SupportTicketFreshConversationTest do
  @moduledoc """
  Phase-6 T85 gate dogfood, H4 (crash-gate) + M3 (first-reply affordance) — a ticket
  created through the UI seeds NO conversation (`support/blueprint.ex`'s plain
  `create: :*`), so `new_reply_form/3` returns `nil`. Before this fix, the KB
  suggestion "Insert" button rendered UNGATED (`ticket_live.ex:422`, unlike the macro
  palette right below it): clicking it called
  `AshPhoenix.Form.value(socket.assigns.reply_form, :body)` with `reply_form == nil`,
  and `AshPhoenix.Form.value/2` immediately calls `to_form!(nil)`, which RAISES.

  This exercises the FRESH-ticket state end-to-end: no crash on mount, no crash on
  Insert (both the DOM's disabled affordance AND the handler's own defense-in-depth
  guard), and a working "Start conversation" affordance that unlocks the real reply
  composer (mirrors `Samen.Web.SupportKbComposerTest`'s harness shape).
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Support.TicketLive
  alias Samen.Web.Support.KbReads
  alias Samen.Web.Mount

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

  # A ticket created through the product, exactly like a fresh UI-created ticket:
  # no conversation seeded — unlike `Seeds.seed_all/0`'s fixture, which seeds a
  # conversation + message on its ticket.
  defp fresh_ticket(org_id) do
    Samen.WebTest.Support.Ticket
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org_id, subject: "Rate confirmation FAQ needed", status: :open, priority: :normal},
      actor: %{org_id: org_id, role: :member},
      authorize?: false
    )
    |> Ash.create!()
  end

  defp seed_matching_article(org_id) do
    kb_mount = KbReads.kb_mount(build_mount(:support))
    scope = Mount.scope(kb_mount, org_id)

    article =
      Mount.resource(kb_mount, Post)
      |> Ash.Changeset.for_create(
        :create,
        %{
          title: "Rate confirmation FAQ",
          slug: "rate-confirmation-faq-#{System.unique_integer([:positive])}",
          body: "Rate confirmation documents: resend from the load detail page, under Documents.",
          org_id: org_id
        },
        scope: scope
      )
      |> Ash.create!()

    {:ok, published} = KbReads.publish_article(kb_mount, org_id, article.id)
    published
  end

  # ---------------------------------------------------------------------------
  describe "H4 — the KB Insert crash-gate on a fresh (no-conversation) ticket" do
    test "mounting a fresh ticket with a matching KB article never crashes; reply_form is nil" do
      org_id = Ash.UUID.generate()
      ticket = fresh_ticket(org_id)
      article = seed_matching_article(org_id)

      socket = mount_socket(org_id, ticket.id)

      assert socket.assigns.reply_form == nil
      assert socket.assigns.kb_suggestion.state == :ok

      rendered = html(socket)
      assert rendered =~ ~s(id="kb-suggestion-panel")
      assert rendered =~ article.title
      # The gated/disabled state renders — no live phx-click wired to a handler
      # that would raise on this nil reply_form.
      assert rendered =~ "disabled"
      refute rendered =~ ~s(phx-click="insert_suggestion")
    end

    test "clicking Insert on a fresh ticket does NOT crash the LiveView (the handler's own guard)" do
      org_id = Ash.UUID.generate()
      ticket = fresh_ticket(org_id)
      article = seed_matching_article(org_id)

      socket = mount_socket(org_id, ticket.id)
      assert socket.assigns.reply_form == nil

      # Defense-in-depth: drive the handler directly (a crafted phx-click, or a
      # stale DOM event racing the disabled attribute) — proving the CRASH-GATE
      # itself, not just that the button happens to render disabled.
      socket = event(socket, "insert_suggestion", %{"article_id" => to_string(article.id)})

      # The LiveView process stayed alive (no raise); state is untouched.
      assert socket.assigns.reply_form == nil
      assert html(socket) =~ ~s(id="kb-suggestion-panel")
    end

    test "a ticket WITH a conversation still has a LIVE, wired Insert button (no regression)" do
      %{org_id: org_id, support: %{ticket: ticket}} = Seeds.seed_all()
      _article = seed_matching_article(org_id)

      socket = mount_socket(org_id, ticket.id)
      assert socket.assigns.reply_form != nil

      rendered = html(socket)
      assert rendered =~ ~s(phx-click="insert_suggestion")
      refute rendered =~ "Start a conversation to insert this suggestion"
    end
  end

  # ---------------------------------------------------------------------------
  describe "M3 — the first-reply / start-conversation affordance" do
    test "a fresh ticket with no conversation shows the Start conversation affordance" do
      org_id = Ash.UUID.generate()
      ticket = fresh_ticket(org_id)

      socket = mount_socket(org_id, ticket.id)
      rendered = html(socket)

      assert rendered =~ "No conversation thread yet."
      assert rendered =~ ~s(id="start-conversation-btn")
      assert rendered =~ ~s(phx-click="start_conversation")
      refute rendered =~ ~s(id="reply-composer")
    end

    test "clicking Start conversation creates a real conversation and unlocks the reply composer" do
      org_id = Ash.UUID.generate()
      ticket = fresh_ticket(org_id)

      socket = mount_socket(org_id, ticket.id)
      assert socket.assigns.conversations == []
      assert socket.assigns.reply_form == nil

      socket = event(socket, "start_conversation", %{})

      assert [%{ticket_id: tid}] = socket.assigns.conversations
      assert tid == ticket.id
      assert socket.assigns.reply_form != nil

      rendered = html(socket)
      assert rendered =~ ~s(id="reply-composer")
      refute rendered =~ ~s(id="start-conversation-btn")

      # The real write landed via the sanctioned Conversation create action.
      convs =
        Samen.WebTest.Support.Conversation
        |> Ash.Query.ensure_selected([:ticket_id])
        |> Ash.read!(authorize?: false)
        |> Enum.filter(&(&1.ticket_id == ticket.id))

      assert length(convs) == 1
    end

    test "OPERATOR plane: no Start conversation affordance is offered (write posture, tenant-only)" do
      org_id = Ash.UUID.generate()
      ticket = fresh_ticket(org_id)

      socket = mount_socket(org_id, ticket.id, plane: :operator, target_org_id: org_id)
      rendered = html(socket)

      assert rendered =~ "No conversation thread yet."
      refute rendered =~ ~s(id="start-conversation-btn")
      refute rendered =~ ~s(phx-click="start_conversation")
    end
  end
end
