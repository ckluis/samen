defmodule Samen.Reveal.GrantDbCheckTest do
  @moduledoc """
  T1.6 clause (b): distinct-party approval enforced BY DB CHECK
  (`rvg_granted_by <> rvg_requestor_id`), INDEPENDENT of the application policy.

  This is the belt-and-suspenders half of clause (b). `reveal_grants_test.exs`
  proves the POLICY layer refuses self-approval; this file proves that even a
  DIRECT insert that bypasses `Samen.Reveal.Grants.approve/2` entirely — as a
  bug or a bypass would — is REJECTED by the database with a constraint
  violation. Self-approval is impossible at the storage layer.
  """
  use ExUnit.Case, async: false

  alias Samen.Reveal.RevealGrant

  @repo SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    :ok
  end

  defp base_attrs(id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{
      id: Ecto.UUID.generate(),
      request_id: Ecto.UUID.generate(),
      subject_id: "subject-#{id}",
      reason: "direct insert",
      expires_at: DateTime.add(now, 900, :second),
      inserted_at: now,
      updated_at: now
    }
  end

  test "RED PATH: a DIRECT insert with granted_by == requestor_id raises the DB CHECK" do
    id = System.unique_integer([:positive])
    same = "same-party-#{id}"

    attrs =
      base_attrs(id)
      |> Map.merge(%{requestor_id: same, granted_by: same})

    cs =
      %RevealGrant{}
      |> Ecto.Changeset.cast(attrs, Map.keys(attrs))
      # Map the DB CHECK to a changeset error (mirrors the real grant_changeset).
      # The error ONLY surfaces because Postgres rejects the row — the constraint
      # is not re-checked in Elixir; it is the DB CHECK firing.
      |> Ecto.Changeset.check_constraint(:granted_by, name: :rvg_distinct_party)

    assert {:error, changeset} = @repo.insert(cs)
    assert changeset.errors != []

    # Confirm the specific constraint is the cause.
    assert Enum.any?(changeset.errors, fn {_field, {_msg, opts}} ->
             Keyword.get(opts, :constraint) == :check and
               Keyword.get(opts, :constraint_name) == "rvg_distinct_party"
           end)
  end

  test "RED PATH: even bypassing Ecto's check_constraint mapping, Postgres raises" do
    id = System.unique_integer([:positive])
    same = "same-raw-#{id}"
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    expires = DateTime.add(now, 900, :second)

    # Raw SQL insert — no application code, no changeset mapping at all.
    assert_raise Postgrex.Error, ~r/rvg_distinct_party/, fn ->
      @repo.query!(
        """
        INSERT INTO rvg_reveal_grant
          (rvg_id, rvg_request_id, rvg_subject_id, rvg_requestor_id, rvg_granted_by,
           rvg_reason, rvg_expires_at, rvg_inserted_at, rvg_updated_at)
        VALUES
          (gen_random_uuid(), gen_random_uuid(), $1, $2, $2, 'raw', $3, $4, $4)
        """,
        ["subject-#{id}", same, expires, now]
      )
    end
  end

  test "a DISTINCT-party direct insert SUCCEEDS (the CHECK only blocks self-approval)" do
    id = System.unique_integer([:positive])

    attrs =
      base_attrs(id)
      |> Map.merge(%{requestor_id: "requestor-#{id}", granted_by: "approver-#{id}"})

    cs = %RevealGrant{} |> Ecto.Changeset.cast(attrs, Map.keys(attrs))
    assert {:ok, %RevealGrant{}} = @repo.insert(cs)
  end
end
