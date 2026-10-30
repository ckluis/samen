defmodule Samen.Scopes.ArchivalSignalsTest do
  @moduledoc """
  Issue #96 D3 — the composition cascades of the CMS, Support, Chat and Work scopes are
  `Ash.Signals` listeners (`Samen.Archival.Signals`, `Samen.Archival.Cascade`).

    * each mount's parent emits ITS OWN mount's `:archived`/`:restored`, and exactly that
      mount's children listen — the tenant Support mount and the operator ticket desk (two
      mounts of one scope in one app) never reach each other's listeners;
    * RED: a cascade listener action called directly — not as a listener — is forbidden,
      even to an org admin; CONTROL: archiving and restoring the page cascades through it.

  The cascades' own semantics (same instant, independent archive survives, same-second
  sibling) are proven per scope by the existing suites, unchanged.
  """
  use Samen.WebTest.DataCase, async: false

  require Ash.Query

  alias Samen.WebTest.{Chat, Cms, Operator, Support, Work}

  # parent => the resources listening to each of its signals (sorted)
  @mounts [
    {Cms.Page, archived: [Cms.Block], restored: [Cms.Block]},
    {Support.Ticket, archived: [Support.Conversation], restored: [Support.Conversation]},
    {Operator.Ticket, archived: [Operator.Conversation], restored: [Operator.Conversation]},
    {Chat.ChatThread,
     archived: [Chat.ChatMessage, Chat.ChatParticipant],
     restored: [Chat.ChatMessage, Chat.ChatParticipant]},
    {Work.Task, archived: [Work.Task], restored: [Work.Task]}
  ]

  describe "wiring" do
    test "each parent emits its own mount's signals, and exactly its own children listen" do
      for {parent, expected} <- @mounts do
        signals = Module.concat(parent, Archival)

        assert emits(parent, :archive) == [{signals, :archived}], inspect(parent)
        assert emits(parent, :restore) == [{signals, :restored}], inspect(parent)

        for {signal, children} <- expected do
          assert listening(signals, signal) == children, "#{inspect(parent)} #{signal}"
        end
      end
    end
  end

  describe "the listener lock" do
    setup do
      org_id = Ash.UUID.generate()
      admin = %Samen.Scope{actor: %{id: Ash.UUID.generate(), role: :admin, org_id: org_id}}

      page = create!(Cms.Page, %{title: "Pricing", org_id: org_id}, admin)
      block = create!(Cms.Block, %{name: "hero", page_id: page.id, org_id: org_id}, admin)

      %{admin: admin, page: page, block: block}
    end

    test "RED: a cascade listener action cannot be called directly, even by an org admin",
         %{admin: admin, page: page, block: block} do
      # Well-formed signals, so the refusal is the policy's, not input validation's.
      archived = %{signal_id: Ash.UUIDv7.generate(), record_id: page.id, archived_at: DateTime.utc_now()}
      restored = %{signal_id: Ash.UUIDv7.generate(), record_id: page.id, archived_at: DateTime.utc_now()}

      assert {:error, %Ash.Error.Forbidden{}} =
               run(Cms.Block, :cascade_page_archived, archived, admin)

      assert {:error, %Ash.Error.Forbidden{}} =
               run(Cms.Block, :cascade_page_restored, restored, admin)

      # nothing cascaded: the block is still live
      assert archived_at(Cms.Block, block.id) == nil
    end

    test "CONTROL: archiving the page cascades through the listener, and restoring it back",
         %{admin: admin, page: page, block: block} do
      assert {:ok, archived_page} = Samen.Archival.archive(page, scope: admin)
      assert %DateTime{} = instant = archived_at(Cms.Page, page.id)
      assert archived_page.archived_at == instant
      assert archived_at(Cms.Block, block.id) == instant

      assert {:ok, _} = Samen.Archival.restore(archived_page, scope: admin)
      assert archived_at(Cms.Block, block.id) == nil
    end
  end

  defp emits(resource, action) do
    Ash.Resource.Info.action(resource, action).emits
    |> Enum.map(&{&1.signal_module, &1.signal})
  end

  defp listening(signals, signal) do
    signals
    |> Ash.Signals.Registry.listeners(signal)
    |> Enum.map(& &1.resource)
    |> Enum.sort()
  end

  defp create!(resource, attrs, scope) do
    resource
    |> Ash.Changeset.for_create(:create, attrs, scope: scope)
    |> Ash.create!()
  end

  defp run(resource, action, signal, scope) do
    resource
    |> Ash.ActionInput.for_action(action, %{signal: signal}, scope: scope)
    |> Ash.run_action()
  end

  # Reads through the trash read too, so an archived row is visible with its instant.
  defp archived_at(resource, id) do
    live = resource |> Ash.Query.filter(id == ^id) |> Ash.read!(authorize?: false)

    trashed =
      resource
      |> Ash.Query.for_read(:archived)
      |> Ash.Query.filter(id == ^id)
      |> Ash.read!(authorize?: false)

    case live ++ trashed do
      [record] -> record.archived_at
    end
  end
end
