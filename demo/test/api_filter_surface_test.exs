defmodule Demo.ApiFilterSurfaceTest do
  @moduledoc """
  F3.7 — the API's FILTER/SORT surface must match its SERIALIZATION surface.

  Gate-3 §F3.7 found that `?filter[org_id]=…` (a public field NOT in `show_fields`)
  returned 200 and acted as a real predicate — a hit/miss side channel over a field
  the opt-in allowlist keeps out of the body. The fix (in `Demo.Crm.Contact`'s
  `json_api do` block) sets `derive_filter?(false)`, so a filter over a
  non-allowlisted field can no longer influence the result set.

  Two guarantees, tested as red paths:

    * **SORT** on a non-allowlisted field is REFUSED with a 4xx. AshJsonApi's sort
      parser validates each field against `show_field?/2` — a field absent from the
      allowlist yields `InvalidSort` (400). This is the "filtering/sorting on a
      non-allowlisted field 4xx" red path the task names.

    * **FILTER** on a non-allowlisted field is INERT — it does not act as a
      predicate, so it cannot be used as a differencing oracle. Proven by a
      two-value differencing probe: a filter that (if honored) would match zero rows
      returns the SAME rows as a filter that would match all rows. If the filter were
      still live (the sabotage — `derive_filter?` back to true), the two counts
      diverge.

  ## Anti-tautology / non-vacuity

  The positive control (a plain index returns 200 with the seeded row) proves the
  differencing probe is over a live, non-empty result set — so "inert filter" means
  the filter value is genuinely ignored, not that the route is broken/empty.
  """
  use Demo.ApiCase, async: false

  setup do
    org = mk_org("FilterSurfaceOrg")
    _c = mk_contact(org.id, %{display_name: "Alice"})
    {raw, _key} = mk_api_key(org.id, plane: :tenant)
    {:ok, org: org, key: raw}
  end

  describe "F3.7 — SORT surface is closed to non-allowlisted fields (4xx red path)" do
    test "sorting on org_id (a public field NOT in show_fields) is REFUSED", %{key: key} do
      conn = api_get("/contacts?sort=org_id", key)

      assert conn.status >= 400 and conn.status < 500,
             "F3.7: sorting on a non-allowlisted field must be refused (4xx), got " <>
               "#{conn.status}. The allowlist must govern the sort surface, not just " <>
               "the serialized body."
    end

    test "sorting on an ALLOWLISTED field (display_name) is accepted — positive control",
         %{key: key} do
      conn = api_get("/contacts?sort=display_name", key)

      assert conn.status == 200,
             "sorting on an allowlisted field must work (200) — proving the 4xx above is " <>
               "the allowlist rejecting a non-allowlisted field, not sort being broken. " <>
               "Got #{conn.status}."
    end
  end

  describe "F3.7 — FILTER over a non-allowlisted field is inert (no differencing oracle)" do
    test "a filter on org_id cannot influence the result set", %{org: org, key: key} do
      # Baseline: the seeded org has exactly one contact.
      baseline = api_get("/contacts", key)
      assert baseline.status == 200
      baseline_count = length(json(baseline)["data"])
      assert baseline_count >= 1, "positive control: the result set must be non-empty"

      # A filter that, IF honored as a predicate, would match ZERO rows (a random org).
      would_miss =
        api_get("/contacts?filter[org_id]=00000000-0000-0000-0000-000000000000", key)

      # A filter that, IF honored, would match the seeded rows (this org).
      would_hit = api_get("/contacts?filter[org_id]=#{org.id}", key)

      miss_count = if would_miss.status == 200, do: length(json(would_miss)["data"]), else: :err
      hit_count = if would_hit.status == 200, do: length(json(would_hit)["data"]), else: :err

      # The security property: the filter value must NOT change the result set (it is
      # ignored). If derive_filter? were true, miss_count would be 0 and hit_count
      # would be baseline_count — they'd diverge, and the field would be a live oracle.
      assert miss_count == hit_count,
             "F3.7: a filter over a NON-allowlisted field must be inert. It changed the " <>
               "result set (miss=#{inspect(miss_count)} hit=#{inspect(hit_count)}) — the " <>
               "field is still a live filter predicate / differencing oracle."

      assert miss_count == baseline_count,
             "F3.7: the ignored filter must leave the baseline result set intact " <>
               "(baseline=#{baseline_count} miss=#{inspect(miss_count)})."
    end
  end
end
