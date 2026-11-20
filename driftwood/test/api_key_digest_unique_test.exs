defmodule Driftwood.ApiKeyDigestUniqueTest do
  @moduledoc """
  `dak_api_key` (freight) and `dok_api_key` (operator mount) carry a UNIQUE index on their token digest. The auth lookup assumes one row per digest, so the database refuses a second one (a duplicate made
  the lookup error: 503, an availability hole). Raw SQL on purpose: the guarantee is the index, not the minting code.
  """
  use Driftwood.DataCase, async: false

  # `mode: :savepoint` rolls the refused statement back to a savepoint, so the sandbox transaction stays usable.
  defp insert(table, digest_col, org_col, inserted_col, updated_col, digest) do
    Ecto.Adapters.SQL.query(
      Driftwood.Repo,
      "INSERT INTO #{table} (#{digest_col}, #{org_col}, #{inserted_col}, #{updated_col}) " <>
        "VALUES ($1, gen_random_uuid(), now(), now())",
      [digest],
      mode: :savepoint
    )
  end

  test "dak_api_key: a duplicate digest is refused by the database, a distinct one is not" do
    assert {:ok, _} = insert("dak_api_key", "dak_token_digest", "dak_org_id", "dak_inserted_at", "dak_updated_at", "d1")
    # positive control: a distinct digest inserts
    assert {:ok, _} = insert("dak_api_key", "dak_token_digest", "dak_org_id", "dak_inserted_at", "dak_updated_at", "d2")

    assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation, constraint: "dak_api_key_token_digest_uidx"}}} =
             insert("dak_api_key", "dak_token_digest", "dak_org_id", "dak_inserted_at", "dak_updated_at", "d1")
  end

  test "dok_api_key: a duplicate digest is refused by the database, a distinct one is not" do
    assert {:ok, _} = insert("dok_api_key", "dok_token_digest", "dok_org_id", "dok_inserted_at", "dok_updated_at", "d1")
    # positive control: a distinct digest inserts
    assert {:ok, _} = insert("dok_api_key", "dok_token_digest", "dok_org_id", "dok_inserted_at", "dok_updated_at", "d2")

    assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation, constraint: "dok_api_key_token_digest_uidx"}}} =
             insert("dok_api_key", "dok_token_digest", "dok_org_id", "dok_inserted_at", "dok_updated_at", "d1")
  end

  test "dak_api_key: the unique index replaced the plain lookup index (one index on the digest, and it is unique)" do
    %{rows: rows} =
      Driftwood.Repo.query!(
        "SELECT i.indisunique FROM pg_index i JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey) " <>
          "WHERE i.indrelid = 'dak_api_key'::regclass AND a.attname = 'dak_token_digest' AND i.indisvalid"
      )

    assert rows == [[true]]
  end
end
