defmodule Driftwood.ApiKeyMembershipUnavailableTest do
  @moduledoc """
  A Freight key that RESOLVES while the read of its minter's membership FAILS is not a bad key: the plug answers
  503 + `Retry-After`, reports the failure once under its own name, halts, and never serves the request. A key
  whose minter has no active membership stays the actor-less fail-closed path (control).

  The failure is REAL: Postgres DDL is transactional, so renaming the membership table inside the sandbox fails
  the very read and rolls back with the test.
  """
  use Driftwood.ApiCase, async: false

  import ExUnit.CaptureLog

  test "a key whose membership read FAILS is 503 + Retry-After, reported once, halted, never served" do
    org = mk_org()
    {raw, _key} = mk_api_key(org)
    # CONTROL: healthy, the key is served
    assert api_get("/drivers", raw).status == 200

    table = AshPostgres.DataLayer.Info.table(Driftwood.Operator.Membership)
    Ecto.Adapters.SQL.query!(Driftwood.Repo, "ALTER TABLE #{table} RENAME TO #{table}_broken", [])

    log = capture_log(fn -> send(self(), {:conn, api_get("/drivers", raw)}) end)
    assert_received {:conn, conn}

    assert conn.status == 503
    assert conn.halted
    assert [retry] = Plug.Conn.get_resp_header(conn, "retry-after")
    assert String.to_integer(retry) > 0
    refute Map.has_key?(conn.private, :samen_api_actor)
    assert length(Regex.scan(~r/read=driftwood_api_key_membership_load/, log)) == 1
    refute log =~ "read=driftwood_api_key_lookup"
    refute log =~ raw
  end

  test "CONTROL: a key whose minter has no active membership is NOT 503 (actor-less), and nothing is reported" do
    org = mk_org()
    {raw, _key} = mk_api_key(org)

    for m <- Ash.read!(Driftwood.Operator.Membership, authorize?: false) do
      m |> Ash.Changeset.for_update(:update, %{}, authorize?: false) |> Ash.Changeset.force_change_attribute(:status, "suspended") |> Ash.update!(authorize?: false)
    end

    log = capture_log(fn -> send(self(), {:conn, api_get("/drivers", raw)}) end)
    assert_received {:conn, conn}
    refute conn.status == 503
    refute conn.halted
    refute log =~ "membership_load"
  end
end
