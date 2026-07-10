defmodule Demo.ApiPaginationTest do
  @moduledoc """
  JSON:API BOUNDED-by-default pagination (WS-A design §1.1, ADR-016 §3, AC-G1-6 / RP-G1-6).
  The `Demo.Crm.Contact` read action declares `pagination keyset?: true, default_limit: 50,
  max_page_size: 200`, so:

    * an index read with NO `page` params returns a BOUNDED page (≤ default_limit), never
      the full set; and
    * a `page[limit]` ABOVE `max_page_size` is CLAMPED/REJECTED, never honored.

  ## Anti-tautology posture

  Non-vacuity is proven by seeding MORE rows than the probe limit and confirming the
  response is capped BELOW the seeded count — so "bounded" means the limit held over a
  genuinely larger dataset, not that there were too few rows to bound. The clamp test
  proves a hostile `page[limit]` cannot pull the full set.
  """
  use Demo.ApiCase, async: false

  # Must exceed max_page_size (200) so the clamp test exercises the cap boundary —
  # with fewer rows than the cap, a raised/removed cap is unobservable (gate P2-1).
  @seed 210

  setup do
    org = mk_org("PaginationOrg")
    for i <- 1..@seed, do: mk_contact(org.id, %{display_name: "C#{i}"})
    {raw, _key} = mk_api_key(org.id, plane: :tenant)
    {:ok, org: org, key: raw, seed: @seed}
  end

  test "RP-G1-6: an index read with NO page params is BOUNDED by default_limit (never the full set)",
       %{key: key, seed: seed} do
    conn = api_get("/contacts", key)
    assert conn.status == 200

    data = json(conn)["data"]

    # Non-vacuity: we seeded MORE than the default page, so a bounded read must return
    # FEWER than the seeded count.
    assert seed > 50
    assert length(data) <= 50,
           "an unbounded index read returned #{length(data)} rows — the default_limit did " <>
             "not bound the read (RP-G1-6). It must return at most 50."
    assert length(data) == 50, "default_limit 50 should fill the first page from #{seed} rows"
  end

  test "RP-G1-6: page[limit] ABOVE max_page_size is CLAMPED/REJECTED, not honored",
       %{key: key, seed: seed} do
    conn = api_get("/contacts?page[limit]=10000", key)

    # Non-vacuity: the dataset exceeds the cap, so a clamped page is exactly the cap —
    # a raised/removed cap would observably return more.
    assert seed > 200

    cond do
      # Clamp posture: exactly max_page_size rows (never the full/huge set).
      conn.status == 200 ->
        data = json(conn)["data"]

        assert length(data) == 200,
               "page[limit]=10000 returned #{length(data)} rows — expected exactly the " <>
                 "max_page_size cap (200) over a #{seed}-row dataset (RP-G1-6)."

      # Reject posture: AshJsonApi may 4xx an over-max page size — also acceptable
      # (the full set is provably NOT returned either way).
      conn.status >= 400 and conn.status < 500 ->
        :ok

      true ->
        flunk("unexpected status #{conn.status} for an over-max page[limit]")
    end
  end

  test "an explicit small page[limit] is honored (positive control — pagination is live)",
       %{key: key} do
    conn = api_get("/contacts?page[limit]=5", key)
    assert conn.status == 200
    assert length(json(conn)["data"]) == 5
  end

  test "keyset next-page link traverses to a disjoint second page (gate P2-2)", %{key: key} do
    conn = api_get("/contacts?page[limit]=5", key)
    assert conn.status == 200
    body = json(conn)
    ids1 = Enum.map(body["data"], & &1["id"])

    next = body["links"]["next"]
    assert next, "keyset pagination must emit a links.next cursor link"

    after_cursor = URI.parse(next).query |> URI.decode_query() |> Map.get("page[after]")
    assert after_cursor, "links.next must carry a page[after] keyset cursor"

    conn2 =
      api_get(
        "/contacts?page[limit]=5&page[after]=#{URI.encode_www_form(after_cursor)}",
        key
      )

    assert conn2.status == 200
    ids2 = Enum.map(json(conn2)["data"], & &1["id"])

    assert length(ids2) == 5
    assert ids1 -- ids2 == ids1, "second page overlaps the first — cursor did not advance"
  end
end
