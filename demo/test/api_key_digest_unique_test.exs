defmodule Demo.ApiKeyDigestUniqueTest do
  @moduledoc """
  `key_api_key` carries a UNIQUE index on its token digest. The auth lookup assumes one row per digest, so the database refuses a second one (a duplicate made
  the lookup error: 503, an availability hole). Raw SQL on purpose: the guarantee is the index, not the minting code.
  """
  use Demo.DataCase, async: false

  # `mode: :savepoint` rolls the refused statement back to a savepoint, so the sandbox transaction stays usable.
  defp insert(table, digest_col, org_col, inserted_col, updated_col, digest) do
    Ecto.Adapters.SQL.query(
      Demo.Repo,
      "INSERT INTO #{table} (#{digest_col}, #{org_col}, #{inserted_col}, #{updated_col}) " <>
        "VALUES ($1, gen_random_uuid(), now(), now())",
      [digest],
      mode: :savepoint
    )
  end

  test "key_api_key: a duplicate digest is refused by the database, a distinct one is not" do
    assert {:ok, _} = insert("key_api_key", "key_token_digest", "key_org_id", "key_inserted_at", "key_updated_at", "d1")
    # positive control: a distinct digest inserts
    assert {:ok, _} = insert("key_api_key", "key_token_digest", "key_org_id", "key_inserted_at", "key_updated_at", "d2")

    assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation, constraint: "key_api_key_token_digest_uidx"}}} =
             insert("key_api_key", "key_token_digest", "key_org_id", "key_inserted_at", "key_updated_at", "d1")
  end
end
