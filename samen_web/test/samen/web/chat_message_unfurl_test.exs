defmodule Samen.Web.ChatMessageUnfurlTest do
  @moduledoc """
  THE CROWN-JEWEL GATE, IN THE CHAT CONTEXT (ADR-012 §7 red paths 1 + 2, test-plan §8.2).

  A single seeded chat message pastes a `samen:crm.person:<id>` ref. Rendered for the TENANT
  viewer and the OPERATOR viewer (the SAME message, the SAME object), the inline unfurl card:

    * TENANT — shows the person's REAL name/email; and
    * OPERATOR — shows `••••` for the SAME object, plaintext ABSENT, no `vt_`/`pii_` token.

  Plus the cross-org red path: a message whose ref points at a DIFFERENT org's person resolves
  to a "not available" chip (no leak, no existence oracle). This is the object-unfurl capability
  (`Samen.Web.ObjectRef`) exercised THROUGH the chat message-render path (`Samen.Web.Chat.
  resolve_cards/3`) — chat is the first consumer, masking is BY CONSTRUCTION.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Chat
  alias Samen.Web.Mount

  setup do
    seeded = Seeds.seed_all()
    chat = Seeds.seed_chat(seeded.org_id, person_id: seeded.crm.person.id)
    %{org_id: seeded.org_id, chat: chat, person_id: seeded.crm.person.id}
  end

  test "TENANT viewer: the message's unfurl card shows REAL PII (clear)", %{org_id: org_id, chat: chat} do
    mount = chat_mount(plane: :tenant)
    scope = Mount.scope(mount, org_id)

    # The message stores the ref; resolve_cards re-resolves per viewer (the render path).
    cards = Chat.resolve_cards(mount, scope, chat.message.refs)
    assert [{_ref, {:ok, card}}] = cards
    assert card.title == Seeds.contact_full_name()

    html = render_cards(cards)
    assert html =~ Seeds.contact_full_name()
    assert html =~ Seeds.contact_email()
  end

  test "OPERATOR viewer: the SAME message's unfurl card shows •••• (masked), no plaintext, no token", %{
    org_id: org_id,
    chat: chat
  } do
    mount = chat_mount(plane: :operator, target_org_id: org_id)
    scope = Mount.scope(mount, org_id)

    cards = Chat.resolve_cards(mount, scope, chat.message.refs)
    assert [{_ref, {:ok, card}}] = cards
    # Same object id as the tenant resolve — only masking differs.
    assert card.id == person_ref_id(chat)
    assert match?(%Samen.Masked{}, card.title)

    html = render_cards(cards)
    assert html =~ "••••"
    refute html =~ Seeds.contact_full_name()
    refute html =~ Seeds.contact_email()
    refute html =~ Seeds.contact_phone()
    refute html =~ "vt_"
    refute html =~ "pii_"
  end

  test "the SAME message ref resolves to the SAME object on both planes — only masking differs", %{
    org_id: org_id,
    chat: chat
  } do
    tenant_mount = chat_mount(plane: :tenant)
    op_mount = chat_mount(plane: :operator, target_org_id: org_id)

    [{_r, {:ok, t_card}}] = Chat.resolve_cards(tenant_mount, Mount.scope(tenant_mount, org_id), chat.message.refs)
    [{_r, {:ok, o_card}}] = Chat.resolve_cards(op_mount, Mount.scope(op_mount, org_id), chat.message.refs)

    assert t_card.id == o_card.id
    assert t_card.key == o_card.key
    assert is_binary(t_card.title)
    assert match?(%Samen.Masked{}, o_card.title)
  end

  test "a cross-org ref in a message renders a 'not available' chip (no leak)", %{org_id: org_id} do
    # A person in a DIFFERENT org.
    other_org = Ash.UUID.generate()

    foreign =
      Samen.WebTest.Crm.Person
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: other_org,
          display_name: "Foreign Chatperson",
          full_name: %Samen.Type.FullName{first: "Foreign", last: "Chatsecret"},
          emails: [%{label: "work", address: "foreign.chat@example.test"}]
        },
        authorize?: false
      )
      |> Ash.create!()

    mount = chat_mount(plane: :tenant)
    scope = Mount.scope(mount, org_id)

    cross_ref = ["samen:crm.person:#{foreign.id}"]
    cards = Chat.resolve_cards(mount, scope, cross_ref)
    assert [{_ref, {:error, :not_found}}] = cards

    html = render_cards(cards)
    refute html =~ "Foreign"
    refute html =~ "foreign.chat@example.test"
    assert html =~ "not available"
  end

  # -- helpers -----------------------------------------------------------------

  defp chat_mount(opts) do
    plane =
      case Keyword.get(opts, :plane, :tenant) do
        :operator ->
          Samen.Web.Plane.operator("op-1", Keyword.fetch!(opts, :target_org_id), "test-session")

        _ ->
          Samen.Web.Plane.tenant()
      end

    Mount.new(:chat, Samen.WebTest.Chat, Samen.WebTest.Repo, plane: plane)
  end

  defp person_ref_id(chat) do
    [ref] = chat.message.refs
    ref |> String.split(":") |> List.last()
  end

  # Render the message's inline unfurl cards (the DOM the viewer sees) to an HTML string. The
  # component takes a `%Card{}` or an `{:error, reason}`; `resolve_cards/3` returns
  # `{ref, {:ok, card} | {:error, reason}}`, so unwrap the ok tuple into the card the
  # component renders (an error passes through verbatim → the "not available" chip).
  defp render_cards(cards) do
    cards
    |> Enum.map(fn {_ref, result} ->
      card = card_of(result)

      %{card: card, __changed__: %{}}
      |> Samen.UI.object_card()
      |> Phoenix.HTML.Safe.to_iodata()
      |> IO.iodata_to_binary()
    end)
    |> Enum.join("\n")
  end

  defp card_of({:ok, card}), do: card
  defp card_of({:error, _} = err), do: err
end
