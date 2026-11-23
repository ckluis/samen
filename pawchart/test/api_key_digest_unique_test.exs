defmodule PawChart.ApiKeyDigestUniqueTest do
  @moduledoc """
  `pok_api_key` carries a UNIQUE index on its token digest. The auth lookup assumes one row per digest, so the database refuses a second one (a duplicate made
  the lookup error: 503, an availability hole). Raw SQL on purpose: the guarantee is the index, not the minting code.
  """
  use PawChart.DataCase, async: false

  # `mode: :savepoint` rolls the refused statement back to a savepoint, so the sandbox transaction stays usable.
  defp insert(table, digest_col, org_col, inserted_col, updated_col, digest) do
    Ecto.Adapters.SQL.query(
      PawChart.Repo,
      "INSERT INTO #{table} (#{digest_col}, #{org_col}, #{inserted_col}, #{updated_col}) " <>
        "VALUES ($1, gen_random_uuid(), now(), now())",
      [digest],
      mode: :savepoint
    )
  end

  test "pok_api_key: a duplicate digest is refused by the database, a distinct one is not" do
    assert {:ok, _} = insert("pok_api_key", "pok_token_digest", "pok_org_id", "pok_inserted_at", "pok_updated_at", "d1")
    # positive control: a distinct digest inserts
    assert {:ok, _} = insert("pok_api_key", "pok_token_digest", "pok_org_id", "pok_inserted_at", "pok_updated_at", "d2")

    assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation, constraint: "pok_api_key_token_digest_uidx"}}} =
             insert("pok_api_key", "pok_token_digest", "pok_org_id", "pok_inserted_at", "pok_updated_at", "d1")
  end
end
