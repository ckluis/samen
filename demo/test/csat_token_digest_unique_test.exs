defmodule Demo.CsatTokenDigestUniqueTest do
  @moduledoc """
  `dsc_csat_survey_token` carry a UNIQUE index on the survey-token digest. `preview` reads the row by digest with `limit(1)` and
  `respond` consumes by digest, so one row per digest is an invariant the database now enforces (the plain index only made
  it a matter of 32 random bytes). Raw SQL on purpose: the guarantee is the index, not the minting code.
  """
  use Demo.DataCase, async: false

  @dsc %{prefix: "dsc", table: "dsc_csat_survey_token", ticket: Demo.SupportScope.Ticket}

  # `mode: :savepoint` rolls the refused statement back to a savepoint, so the sandbox transaction stays usable.
  defp insert(%{table: table, prefix: p}, ticket_id, digest) do
    Ecto.Adapters.SQL.query(
      Demo.Repo,
      "INSERT INTO #{table} (#{p}_token_digest, #{p}_expires_at, #{p}_ticket_id, #{p}_org_id, #{p}_inserted_at, #{p}_updated_at) " <>
        "VALUES ($1, now() + interval '1 day', $2, gen_random_uuid(), now(), now())",
      [digest, Ecto.UUID.dump!(ticket_id)],
      mode: :savepoint
    )
  end

  defp ticket!(mod) do
    mod
    |> Ash.Changeset.for_create(:create, %{subject: "digest-#{System.unique_integer([:positive])}", status: :open, priority: :normal, org_id: Ash.UUID.generate()})
    |> Ash.create!(authorize?: false)
    |> Map.fetch!(:id)
  end

  defp assert_duplicate_refused(survey) do
    ticket_id = ticket!(survey.ticket)

    assert {:ok, _} = insert(survey, ticket_id, "d1")
    # positive control: a distinct digest inserts
    assert {:ok, _} = insert(survey, ticket_id, "d2")

    assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation, constraint: constraint}}} =
             insert(survey, ticket_id, "d1")

    assert constraint == "#{survey.table}_token_digest_uidx"
  end

  # one valid index on the digest, it is unique, and the plain one it replaced is gone
  defp assert_unique_replaced_plain(%{table: table, prefix: p}) do
    %{rows: rows} =
      Demo.Repo.query!(
        "SELECT i.indisunique FROM pg_index i JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey) " <>
          "WHERE i.indrelid = '#{table}'::regclass AND a.attname = '#{p}_token_digest' AND i.indisvalid"
      )

    assert rows == [[true]]
  end

  test "dsc_csat_survey_token: a duplicate digest is refused by the database, a distinct one is not" do
    assert_duplicate_refused(@dsc)
  end

  test "dsc_csat_survey_token: the unique index replaced the plain lookup index (one valid index on the digest, and it is unique)" do
    assert_unique_replaced_plain(@dsc)
  end

end
