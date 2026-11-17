defmodule Demo.ApiKeyLookupUnavailableTest do
  @moduledoc """
  A key lookup that FAILS (the read errored) is not a bad key. `DemoWeb.Api.KeyAuthPlug` answers 503 with
  `Retry-After`, reports the failure once (value-free), halts (the request is never served, not even as an actor-less
  one) and never echoes the key. An unknown key stays the actor-less fail-closed path; a good key is served.

  The failure is REAL: Postgres DDL is transactional, so renaming the digest column inside the sandbox makes the very
  lookup fail and rolls back with the test.
  """
  use Demo.ApiCase, async: false

  import ExUnit.CaptureLog

  defp break_lookup!,
    do: Ecto.Adapters.SQL.query!(Demo.Repo, "ALTER TABLE key_api_key RENAME COLUMN key_token_digest TO key_token_digest_renamed", [])

  setup do
    org = mk_org("Acme")
    _c = mk_contact(org.id, %{display_name: "Guarded"})
    {raw, _key} = mk_api_key(org.id)
    {:ok, org: org, raw: raw}
  end

  test "a failed lookup is 503 + Retry-After, reported once, halted, and names no key", %{raw: raw} do
    break_lookup!()

    log = capture_log(fn -> send(self(), {:conn, api_get("/contacts", raw)}) end)
    assert_received {:conn, conn}

    assert conn.status == 503
    assert [retry] = Plug.Conn.get_resp_header(conn, "retry-after")
    assert String.to_integer(retry) > 0
    assert conn.halted
    assert %{"errors" => [%{"status" => "503"}]} = json(conn)
    refute conn.resp_body =~ "Guarded"
    refute conn.resp_body =~ raw
    refute Map.has_key?(conn.private, :samen_api_actor)

    assert length(Regex.scan(~r/read=demo_api_key_lookup/, log)) == 1
    refute log =~ raw
    refute log =~ DemoWeb.Api.KeyAuthPlug.digest(raw)
    refute log =~ String.slice(raw, 0, 6)
  end

  test "controls: an unknown key is NOT 503 (actor-less, nothing served), a good key is 200 with the row", %{raw: raw} do
    log = capture_log(fn -> send(self(), {:unknown, api_get("/contacts", "sk_unknown")}) end)
    assert_received {:unknown, unknown}
    assert unknown.status != 503
    refute unknown.resp_body =~ "Guarded"
    refute log =~ "demo_api_key_lookup"

    good = api_get("/contacts", raw)
    assert good.status == 200
    assert good.resp_body =~ "Guarded"
  end
end
