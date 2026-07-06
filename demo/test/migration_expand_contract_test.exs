defmodule Demo.MigrationExpandContractTest do
  @moduledoc """
  T2.4 dogfood: the demo's expand migration (`ExpandAddContactTier`) added a nullable
  `cnt_tier` column AND wrote a `samen_migration_meta` bake-clock row. This test proves
  the contract-phase gate reads that row and refuses/permits correctly, on the REAL
  demo DB (not a fixture).
  """
  use ExUnit.Case, async: false

  alias Demo.Repo
  alias Samen.Migration.ExpandContract
  alias Samen.Migration.Meta

  @change_key "demo_contact_tier"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  test "the expand migration added the nullable cnt_tier column (additive)" do
    %{rows: [[udt, nullable]]} =
      Repo.query!(
        "SELECT udt_name, is_nullable FROM information_schema.columns " <>
          "WHERE table_name = 'cnt_contact' AND column_name = 'cnt_tier'",
        []
      )

    assert udt == "text"
    assert nullable == "YES"
  end

  test "the expand wrote a samen_migration_meta bake-clock row" do
    %{rows: rows} =
      Repo.query!(
        "SELECT smm_phase FROM #{Meta.table()} WHERE smm_change_key = $1",
        [@change_key]
      )

    assert rows == [["expand"]]
  end

  test "contract_ready? refuses before the bake window, permits after (dogfood)" do
    # The expand row was written at migrate time (test setup). With a 7-day window
    # it is still baking; backdated past a short window it is ready. Same row, same
    # query — only the window differs (anti-tautology on the real DB).
    assert {:not_ready, {:baking, _, _}} =
             ExpandContract.contract_ready?(Repo, @change_key, bake_window: {7, :day})

    Repo.query!(
      "UPDATE #{Meta.table()} SET smm_expanded_at = now() - interval '10 seconds' " <>
        "WHERE smm_change_key = $1",
      [@change_key]
    )

    assert {:ready, _} =
             ExpandContract.contract_ready?(Repo, @change_key, bake_window: {5, :second})
  end
end
