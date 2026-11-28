defmodule Samen.Web.TenantRoleSupportTest do
  @moduledoc """
  ADR-045 §4.4 residual (the `:member` default), Support: the ticket inbox, the ticket page and the knowledge base act
  with the role the signed-in person's ACTIVE membership resolves to (`Samen.Web.TenantActor`), never `Plane.scope/2`'s
  fixed `:member`.

  Driven with a REAL spine login (`POST /login`) and the REAL tenant gate (`Samen.WebTest.RoleHarness`). Every refusal is
  paired with a positive control.

  Policy: reads are not role-gated. `Ticket` and `Conversation` writes are `RoleAtLeast :member`; `Message` and the CMS
  `Post` (the KB article) only check the org in the kernel, so the PAGE requires a member for a reply and for authoring an
  article (decision, same rank as the ticket writes); `Post :publish` is `RoleAtLeast :admin`.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Support.{KbLive, TicketLive, TicketsLive}
  alias Samen.WebTest.RoleHarness, as: H
  alias Samen.WebTest.SpineAccounts

  setup do
    H.setup_accounts()
  end

  defp html(view, socket), do: render_html(view, socket.assigns)

  # -- seeds (system context) ---------------------------------------------------------------------------------

  defp ticket!(org_id, subject) do
    Samen.WebTest.Support.Ticket
    |> Ash.Changeset.for_create(:create, %{org_id: org_id, subject: subject, status: :open, priority: :normal}, authorize?: false)
    |> Ash.create!()
  end

  defp conversation!(org_id, ticket) do
    Samen.WebTest.Support.Conversation
    |> Ash.Changeset.for_create(:create, %{org_id: org_id, ticket_id: ticket.id, channel: :email, status: :open, subject: "Re"}, authorize?: false)
    |> Ash.create!()
  end

  defp article!(org_id, title, visibility \\ :internal) do
    Samen.WebTest.Cms.Post
    |> Ash.Changeset.for_create(:create, %{title: title, body: "body", visibility: visibility, org_id: org_id}, authorize?: false)
    |> Ash.create!()
  end

  defp tickets(org_id) do
    Samen.WebTest.Support.Ticket
    |> Ash.Query.ensure_selected([:org_id, :subject, :status, :archived_at])
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&(&1.org_id == org_id))
  end

  defp archived_ticket?(org_id, subject) do
    Samen.WebTest.Support.Ticket
    |> Samen.Archival.archived_query()
    |> Ash.Query.ensure_selected([:org_id, :subject, :archived_at])
    |> Ash.read!(authorize?: false)
    |> Enum.any?(&(&1.org_id == org_id and &1.subject == subject))
  end

  defp conversations(ticket_id) do
    Samen.WebTest.Support.Conversation
    |> Ash.Query.ensure_selected([:ticket_id])
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&(&1.ticket_id == ticket_id))
  end

  defp messages(conversation_id) do
    Samen.WebTest.Support.Message
    |> Ash.Query.ensure_selected([:conversation_id])
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&(&1.conversation_id == conversation_id))
  end

  defp posts(org_id) do
    Samen.WebTest.Cms.Post
    |> Ash.Query.ensure_selected([:org_id, :title, :status])
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&(&1.org_id == org_id))
  end

  defp post_named(org_id, title), do: Enum.find(posts(org_id), &(&1.title == title))

  defp pages(org_id) do
    ticket = ticket!(org_id, "Probe Ticket")
    conversation!(org_id, ticket)
    article!(org_id, "Probe Article")

    [
      %{name: "TicketsLive", view: TicketsLive, path: "/support", extra: %{}, probe: &length(&1.assigns.page.items), events: [{"new_ticket", %{}}, {"delete", %{"id" => ticket.id}}]},
      %{name: "TicketLive", view: TicketLive, path: "/support/tickets/:id", extra: %{"id" => ticket.id}, probe: &(&1.assigns.ticket != nil), events: [{"set_status", %{"status" => "closed"}}, {"start_conversation", %{}}]},
      %{name: "KbLive", view: KbLive, path: "/support/kb", extra: %{}, probe: &length(&1.assigns.articles), events: [{"new_article", %{}}, {"publish", %{"id" => ticket.id}}]}
    ]
  end

  # -- every page acts as the RESOLVED role --------------------------------------------------------------------

  test "every Support page acts with the RESOLVED role, not :member", ctx do
    logins = for who <- [:viewer, :member, :admin, :owner], into: %{}, do: {who, H.log_in(Map.fetch!(ctx, who))}

    for page <- pages(ctx.org_id), role <- [:viewer, :member, :admin, :owner] do
      socket = H.live_socket(Map.fetch!(logins, role), page.view, page.path, ctx.org_id, page.extra)
      assert socket.assigns.actor_state == :ok, page.name
      assert socket.assigns.acting_scope.actor.role == role, "#{page.name} acted as #{socket.assigns.acting_scope.actor.role}, not #{role}"
      assert socket.assigns.acting_scope.actor.resolved == true
      refute String.starts_with?(socket.assigns.acting_scope.actor.id, "broker:")
    end
  end

  test "NAVIGATION: a suspended member's page is the denied state: nothing is read, no event reads or writes", ctx do
    pages = pages(ctx.org_id)
    login = H.log_in(ctx.member)
    sockets = for page <- pages, do: {page, H.live_socket(login, page.view, page.path, ctx.org_id, page.extra)}

    for {page, socket} <- sockets do
      assert page.probe.(socket) not in [nil, false, 0], "#{page.name}: nothing to read while acting (vacuous control)"
    end

    SpineAccounts.suspend!(ctx.member, ctx.org_id)

    for {page, socket} <- sockets do
      refused = H.params(page.view, socket, page.extra)
      assert refused.assigns.actor_state == :denied, page.name
      assert refused.assigns.acting_scope == nil, page.name
      assert page.probe.(refused) in [nil, false, 0], "#{page.name} still holds data after the denial"
      out = html(page.view, refused)
      assert out =~ ~s(id="actor-denied"), page.name
      refute out =~ "Probe Ticket" or out =~ "Probe Article", page.name

      for {name, p} <- page.events do
        assert H.event(page.view, name, p, refused).assigns == refused.assigns, "#{page.name} #{name} changed the refused page"
      end
    end

    refute archived_ticket?(ctx.org_id, "Probe Ticket")
    assert Enum.all?(tickets(ctx.org_id), &(&1.status == :open))
  end

  test "OPEN PAGE: a member suspended while the page is open is refused at the next event, and a demotion takes effect at once", ctx do
    ticket = ticket!(ctx.org_id, "Open Ticket")
    victim = ticket!(ctx.org_id, "Victim Ticket")
    login = H.log_in(ctx.member)

    # positive control: while acting, the very same event writes
    open = H.open_socket(login, TicketsLive, "/support", ctx.org_id)
    H.live_event(TicketsLive, "delete", %{"id" => victim.id}, open)
    assert archived_ticket?(ctx.org_id, "Victim Ticket")

    SpineAccounts.suspend!(ctx.member, ctx.org_id)
    after_event = H.live_event(TicketsLive, "delete", %{"id" => ticket.id}, open)
    assert after_event.assigns.actor_state == :denied
    assert after_event.assigns.acting_scope == nil
    refute archived_ticket?(ctx.org_id, "Open Ticket")

    # a demotion: an admin demoted to viewer while the KB is open can no longer publish
    article = article!(ctx.org_id, "Demote Article")
    admin_login = H.log_in(ctx.admin)
    kb = H.open_socket(admin_login, KbLive, "/support/kb", ctx.org_id)
    assert kb.assigns.can_admin
    SpineAccounts.set_role!(ctx.admin, ctx.org_id, :viewer)
    kb = H.live_event(KbLive, "publish", %{"id" => article.id}, kb)
    assert kb.assigns.acting_scope.actor.role == :viewer
    refute kb.assigns.can_admin
    assert post_named(ctx.org_id, "Demote Article").status != :published
  end

  test "a failed membership lookup is the UNAVAILABLE state on every Support page, never an empty page", ctx do
    login = H.log_in(ctx.member)

    for page <- pages(ctx.org_id) do
      socket = H.live_socket(login, page.view, page.path, ctx.org_id, page.extra) |> H.break_identity()
      {refused, _log} = ExUnit.CaptureLog.with_log(fn -> H.params(page.view, socket, page.extra) end)
      assert refused.assigns.actor_state == :unavailable, page.name
      assert refused.assigns.acting_scope == nil
      out = html(page.view, refused)
      assert out =~ ~s(id="actor-unavailable"), page.name
      refute out =~ "Probe Ticket" or out =~ "Probe Article"
    end
  end

  # -- writes -------------------------------------------------------------------------------------------------

  describe "TicketsLive writes (Ticket: member)" do
    test "a VIEWER cannot create or delete a ticket; a member and an owner can", ctx do
      target = ticket!(ctx.org_id, "Existing Ticket")
      before = length(tickets(ctx.org_id))

      create = fn account, subject ->
        socket = H.live_socket(H.log_in(account), TicketsLive, "/support", ctx.org_id)
        socket = H.event(TicketsLive, "new_ticket", %{}, socket)
        H.event(TicketsLive, "save_new", %{"form" => %{"subject" => subject, "priority" => "normal"}}, socket)
      end

      # RED: before the conversion a viewer created and archived tickets
      create.(ctx.viewer, "Viewer Ticket")
      assert length(tickets(ctx.org_id)) == before

      viewer = H.live_socket(H.log_in(ctx.viewer), TicketsLive, "/support", ctx.org_id)
      assert viewer.assigns.acting_scope.actor.role == :viewer
      viewer = H.event(TicketsLive, "delete", %{"id" => target.id}, viewer)
      refute archived_ticket?(ctx.org_id, "Existing Ticket")
      assert viewer.assigns.delete_error == "Could not delete this ticket."

      create.(ctx.member, "Member Ticket")
      create.(ctx.owner, "Owner Ticket")
      assert length(tickets(ctx.org_id)) == before + 2

      member = H.live_socket(H.log_in(ctx.member), TicketsLive, "/support", ctx.org_id)
      H.event(TicketsLive, "delete", %{"id" => target.id}, member)
      assert archived_ticket?(ctx.org_id, "Existing Ticket")
    end

    test "a viewer's render has no write control; a member's has them", ctx do
      ticket!(ctx.org_id, "Controls Ticket")
      member = html(TicketsLive, H.live_socket(H.log_in(ctx.member), TicketsLive, "/support", ctx.org_id))
      viewer = html(TicketsLive, H.live_socket(H.log_in(ctx.viewer), TicketsLive, "/support", ctx.org_id))

      for control <- ["new-ticket", ~s(phx-click="delete")] do
        assert member =~ control, "the member's page has no #{control} (vacuous)"
        refute viewer =~ control, "the viewer's page offers #{control}"
      end
    end
  end

  describe "TicketLive writes (status, conversation: member; reply: member by the page)" do
    test "a VIEWER cannot change the status, start a conversation or reply; a member can", ctx do
      ticket = ticket!(ctx.org_id, "Detail Ticket")
      path = "/support/tickets/:id"
      viewer = H.live_socket(H.log_in(ctx.viewer), TicketLive, path, ctx.org_id, %{"id" => ticket.id})
      assert viewer.assigns.acting_scope.actor.role == :viewer

      viewer = H.event(TicketLive, "set_status", %{"status" => "closed"}, viewer)
      assert viewer.assigns.status_error == "Could not update the ticket status."
      assert Enum.find(tickets(ctx.org_id), &(&1.id == ticket.id)).status == :open

      viewer = H.event(TicketLive, "start_conversation", %{}, viewer)
      assert viewer.assigns.conversation_error == "Could not start the conversation."
      assert conversations(ticket.id) == []

      # reply on a conversation that exists
      conv = conversation!(ctx.org_id, ticket)
      viewer = H.live_socket(H.log_in(ctx.viewer), TicketLive, path, ctx.org_id, %{"id" => ticket.id})
      refute html(TicketLive, viewer) =~ ~s(id="reply-composer")
      refute html(TicketLive, viewer) =~ ~s(id="ticket-status-form")
      H.event(TicketLive, "save_reply", %{"form" => %{"body" => "viewer reply", "message_type" => "reply"}}, viewer)
      assert messages(conv.id) == []

      # positive controls
      member = H.live_socket(H.log_in(ctx.member), TicketLive, path, ctx.org_id, %{"id" => ticket.id})
      assert html(TicketLive, member) =~ ~s(id="reply-composer")
      H.event(TicketLive, "save_reply", %{"form" => %{"body" => "member reply", "message_type" => "reply"}}, member)
      assert length(messages(conv.id)) == 1
      H.event(TicketLive, "set_status", %{"status" => "closed"}, member)
      assert Enum.find(tickets(ctx.org_id), &(&1.id == ticket.id)).status == :closed

      other = ticket!(ctx.org_id, "No Conversation Yet")
      member = H.live_socket(H.log_in(ctx.member), TicketLive, path, ctx.org_id, %{"id" => other.id})
      H.event(TicketLive, "start_conversation", %{}, member)
      assert length(conversations(other.id)) == 1
    end
  end

  describe "KbLive writes (author: member by the page; publish: admin by the kernel)" do
    test "a VIEWER cannot create or edit an article; a member can; only an admin publishes", ctx do
      article = article!(ctx.org_id, "Draft Article")
      path = "/support/kb"

      create = fn account, title ->
        socket = H.live_socket(H.log_in(account), KbLive, path, ctx.org_id)
        socket = H.event(KbLive, "new_article", %{}, socket)
        socket = H.event(KbLive, "save_new", %{"form" => %{"title" => title, "body" => "b", "visibility" => "internal"}}, socket)
        socket
      end

      # RED: before the conversion a viewer authored and edited articles
      create.(ctx.viewer, "Viewer Article")
      assert post_named(ctx.org_id, "Viewer Article") == nil

      viewer = H.live_socket(H.log_in(ctx.viewer), KbLive, path, ctx.org_id)
      viewer = H.event(KbLive, "edit_article", %{"id" => article.id}, viewer)
      H.event(KbLive, "save_edit", %{"form" => %{"title" => "Viewer Renamed", "body" => "b", "visibility" => "internal"}}, viewer)
      assert post_named(ctx.org_id, "Viewer Renamed") == nil
      refute html(KbLive, viewer) =~ ~s(id="new-article")

      create.(ctx.member, "Member Article")
      assert post_named(ctx.org_id, "Member Article")

      member = H.live_socket(H.log_in(ctx.member), KbLive, path, ctx.org_id)
      assert html(KbLive, member) =~ ~s(id="new-article")
      refute html(KbLive, member) =~ ~s(phx-click="publish")
      member = H.event(KbLive, "publish", %{"id" => article.id}, member)
      assert member.assigns.save_error =~ "admin role required"
      assert post_named(ctx.org_id, "Draft Article").status != :published

      admin = H.live_socket(H.log_in(ctx.admin), KbLive, path, ctx.org_id)
      assert html(KbLive, admin) =~ ~s(phx-click="publish")
      H.event(KbLive, "publish", %{"id" => article.id}, admin)
      assert post_named(ctx.org_id, "Draft Article").status == :published
    end
  end
end
