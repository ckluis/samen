defmodule Samen.Web.MessageWindowTest do
  @moduledoc """
  Eval 2026-11-13 tenant-b F02 / operator F09: a long conversation shows its NEWEST messages
  (display order oldest-first) and says so when older ones are cut. The old reads sorted
  ascending and then limited, so message 201+ — the latest — was the part that vanished.

  `inserted_at` is second-resolution, so each bulk row gets a distinct instant set directly.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Mount

  @bulk 205

  defp set_inserted_at!(resource, id, at) do
    table = AshPostgres.DataLayer.Info.table(resource)
    col = Ash.Resource.Info.attribute(resource, :inserted_at).source
    idcol = Ash.Resource.Info.attribute(resource, :id).source
    Samen.WebTest.Repo.query!("UPDATE #{table} SET #{col} = $1 WHERE #{idcol} = $2", [at, Ecto.UUID.dump!(id)])
  end

  defp bulk_messages(module, org_id, conversation_id, agent_id) do
    base = DateTime.add(DateTime.utc_now(), 60, :second) |> DateTime.truncate(:second)

    for i <- 1..@bulk do
      msg =
        module
        |> Ash.Changeset.for_create(
          :create,
          %{
            org_id: org_id,
            conversation_id: conversation_id,
            agent_id: agent_id,
            sender_type: :agent,
            message_type: :reply,
            body: "bulk #{String.pad_leading("#{i}", 3, "0")}"
          },
          authorize?: false
        )
        |> Ash.create!()

      set_inserted_at!(module, msg.id, DateTime.add(base, i, :second))
    end
  end

  test "SUPPORT: the conversation read returns the newest 200 in order and flags the cut" do
    seeded = Seeds.seed_all()
    sup = seeded.support
    org_id = seeded.org_id
    mount = build_mount(:support)
    scope = Mount.scope(mount, org_id)

    bulk_messages(Samen.WebTest.Support.Message, org_id, sup.conversation.id, sup.agent.id)

    {msgs, hidden?} = Samen.Web.Support.Reads.messages_window_for_conversation(mount, scope, sup.conversation.id)
    assert hidden?
    assert length(msgs) == 200
    bodies = Enum.map(msgs, & &1.body)
    assert List.last(bodies) == "bulk 205"
    assert hd(bodies) == "bulk 006"

    [conv] = Samen.Web.Support.Reads.conversations_for_ticket(mount, scope, sup.ticket.id)
    assert conv.__earlier_hidden__
    assert List.last(conv.__messages__).body == "bulk 205"
  end

  test "SUPPORT: a short conversation is whole and not flagged" do
    seeded = Seeds.seed_all()
    mount = build_mount(:support)
    scope = Mount.scope(mount, seeded.org_id)

    {msgs, hidden?} =
      Samen.Web.Support.Reads.messages_window_for_conversation(mount, scope, seeded.support.conversation.id)

    refute hidden?
    assert length(msgs) == 1
  end

  test "OPERATOR DESK: the ticket detail carries the newest 200 messages and the 'earlier' row" do
    seed = Samen.WebTest.Operator.Seeds.seed_all(tenants: 1)
    ticket = hd(hd(seed.accounts).tickets)
    mount = build_operator_mount(seed.operator_org_id)
    scope = Mount.scope(mount, seed.operator_org_id)

    conv =
      Samen.WebTest.Operator.Conversation
      |> Ash.read!(authorize?: false)
      |> Enum.find(&(&1.ticket_id == ticket.id))

    agent_id = Samen.WebTest.Operator.Message |> Ash.read!(authorize?: false) |> hd() |> Map.fetch!(:agent_id)
    bulk_messages(Samen.WebTest.Operator.Message, seed.operator_org_id, conv.id, agent_id)

    detail = Samen.Web.Operator.Reads.ticket_detail(mount, scope, ticket.id)
    [thread | _] = detail.__conversations__
    assert thread.earlier_hidden
    assert length(thread.messages) == 200
    assert List.last(thread.messages).body == "bulk 205"

    html = render_live(Samen.Web.Operator.DeskDetailLive, mount, [ticket.id])
    assert html =~ "earlier-messages-hidden"
    assert html =~ "bulk 205"
  end
end
