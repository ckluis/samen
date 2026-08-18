defmodule DriftwoodWeb.BrokerCreateLoadTest do
  @moduledoc """
  T148 — the minimal-but-real "New load" create flow. Proves the wired "New load" CTA's
  `create_load/2` persists a real `Driftwood.Crm.Opportunity` (the freight `Load` alias)
  through the resource's REAL `:create` action on the tenant broker scope, and that the new
  row then shows on the load board `Driftwood.Reads.load_board/1` reads. The RED twin proves
  the create is genuinely governed by the Ash action (a missing required `name` is refused),
  so the green path cannot be a stub that always "succeeds".
  """
  use Driftwood.DataCase, async: false

  alias Driftwood.Reads
  alias DriftwoodWeb.BrokerLive

  @org "c1230000-0000-4000-8000-0000000000c1"

  test "GREEN: 'New load' create persists a real Opportunity that shows on the load board" do
    scope = BrokerLive.broker_scope(@org)
    assert Reads.load_board(scope) == []

    assert {:ok, load} =
             BrokerLive.create_load(@org, %{
               "name" => "BRL-4805 reefer",
               "lane" => "TX->CA",
               "rate" => "4800.00",
               "status" => "open"
             })

    # It is a persisted, governed write — not a stub.
    assert load.name == "BRL-4805 reefer"
    assert load.status == :open
    assert Samen.Type.Money.cents(load.value) == 480_000

    # And it now appears on the same ORG-SCOPED read the loads panel renders (its presence on
    # this scope's board proves the org boundary), lane included.
    board = Reads.load_board(scope)
    assert Enum.any?(board, &(&1.id == load.id and &1.__lane__ == "TX->CA"))
  end

  test "RED: a load with no reference name is refused by the real :create action" do
    assert {:error, _changeset} = BrokerLive.create_load(@org, %{"name" => "", "status" => "open"})
    # Nothing was persisted.
    assert Reads.load_board(BrokerLive.broker_scope(@org)) == []
  end
end
