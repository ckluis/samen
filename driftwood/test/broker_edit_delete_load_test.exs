defmodule DriftwoodWeb.BrokerEditDeleteLoadTest do
  @moduledoc """
  T158 — LOADS edit + delete (T148 landed create only). `update_load/3` persists real
  edits through the resource's REAL `:update` action; `delete_load/2` rides the
  resource's default SOFT destroy (`Driftwood.Crm.Opportunity` is `archivable: true`,
  ADR-040 §5.9) — a deleted load disappears from `load_board/1` (the archive
  preparation filters it out), never a raw irreversible DELETE.

  RED twins prove both writes are genuinely governed (a missing required `name`
  refuses the edit; a cross-org id is a genuine not-found, never a silent no-op)
  — not stubs that always "succeed".
  """
  use Driftwood.DataCase, async: false

  alias Driftwood.Reads
  alias DriftwoodWeb.BrokerLive

  @org "c1230000-0000-4000-8000-0000000000c2"
  @other_org "c1230000-0000-4000-8000-0000000000c3"

  defp seeded_load(org) do
    {:ok, load} =
      BrokerLive.create_load(org, %{
        "name" => "BRL-9001 dry van",
        "lane" => "TX->CA",
        "rate" => "3200.00",
        "status" => "open"
      })

    load
  end

  # -- EDIT --------------------------------------------------------------------

  test "GREEN: update_load/3 persists a real edit through the :update action" do
    load = seeded_load(@org)

    assert {:ok, updated} =
             BrokerLive.update_load(@org, load.id, %{
               "name" => "BRL-9001 dry van (rebooked)",
               "lane" => "TX->AZ",
               "rate" => "3400.50",
               "status" => "won"
             })

    assert updated.id == load.id
    assert updated.name == "BRL-9001 dry van (rebooked)"
    assert updated.status == :won
    assert Samen.Type.Money.cents(updated.value) == 340_050

    # The edit is visible on the SAME org-scoped read the loads panel renders.
    scope = BrokerLive.broker_scope(@org)
    board = Reads.load_board(scope)
    assert Enum.any?(board, &(&1.id == load.id and &1.name == "BRL-9001 dry van (rebooked)" and &1.__lane__ == "TX->AZ"))
  end

  test "RED: an edit that blanks the required load reference name is refused" do
    load = seeded_load(@org)

    assert {:error, _changeset} =
             BrokerLive.update_load(@org, load.id, %{"name" => "", "status" => "open"})

    # Unchanged — the refused edit did NOT persist.
    scope = BrokerLive.broker_scope(@org)
    board = Reads.load_board(scope)
    assert Enum.any?(board, &(&1.id == load.id and &1.name == "BRL-9001 dry van"))
  end

  test "RED: editing another org's load id is a genuine :not_found (org-scope pin)" do
    victim_load = seeded_load(@org)

    assert {:error, :not_found} =
             BrokerLive.update_load(@other_org, victim_load.id, %{"name" => "STOLEN", "status" => "open"})

    # The victim org's load is UNCHANGED.
    scope = BrokerLive.broker_scope(@org)
    board = Reads.load_board(scope)
    assert Enum.any?(board, &(&1.id == victim_load.id and &1.name == "BRL-9001 dry van"))
    refute Enum.any?(board, &(&1.name == "STOLEN"))
  end

  # -- DELETE (soft) -------------------------------------------------------------

  test "GREEN: delete_load/2 soft-deletes — the load disappears from the load board" do
    load = seeded_load(@org)
    scope = BrokerLive.broker_scope(@org)
    assert Enum.any?(Reads.load_board(scope), &(&1.id == load.id))

    assert {:ok, destroyed} = BrokerLive.delete_load(@org, load.id)
    assert destroyed.id == load.id

    refute Enum.any?(Reads.load_board(scope), &(&1.id == load.id))

    # SOFT delete: the row still exists (archived), never hard-removed from the table.
    raw =
      Ecto.Adapters.SQL.query!(
        Driftwood.Repo,
        "SELECT fop_archived_at FROM fop_opportunity WHERE fop_id = $1",
        [Ecto.UUID.dump!(to_string(load.id))]
      )

    assert %{rows: [[archived_at]]} = raw
    refute is_nil(archived_at), "expected the soft-deleted row to carry a non-nil archived_at"
  end

  test "RED: deleting another org's load id is a genuine :not_found — nothing destroyed" do
    victim_load = seeded_load(@org)

    assert {:error, :not_found} = BrokerLive.delete_load(@other_org, victim_load.id)

    # The victim org's load survives, undeleted.
    scope = BrokerLive.broker_scope(@org)
    assert Enum.any?(Reads.load_board(scope), &(&1.id == victim_load.id))
  end

  test "RED: deleting an unknown load id is a genuine :not_found" do
    assert {:error, :not_found} = BrokerLive.delete_load(@org, Ecto.UUID.generate())
  end
end
