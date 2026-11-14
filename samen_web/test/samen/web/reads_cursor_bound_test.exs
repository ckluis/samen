defmodule Samen.Web.ReadsCursorBoundTest do
  @moduledoc """
  ARCH-4 (S4) — the redundant index bound `Samen.Web.Reads` ANDs onto the keyset cursor
  (`f <= v` for DESC always, `f >= v` for ASC only when the attribute cannot be NULL) must not
  change WHICH rows a page returns. The EXPLAIN side (the bound is what lets a deep page seek) is
  in `Samen.Web.TenantIndexPlanTest`; this is the result-set side.

  Property: paging a whole org forward, page by page, in both sort directions, over rows that
  carry NULLs and duplicate sort values, yields exactly the rows — in exactly the order — of one
  unpaged read with the same ORDER BY. A bound that drops the ASC NULLS-LAST tail (the failure the
  `allow_nil? false` rule exists to prevent), or one that is wrong for duplicates, shows up as a
  missing, repeated or reordered row. Two sort columns: `job_title` (nullable, heavy duplicates)
  and `inserted_at` (cannot be NULL; the ASC bound IS applied), over page sizes that do and do
  not divide the row count.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.ListState
  alias Samen.Web.Mount
  alias Samen.Web.Reads
  alias Samen.WebTest.Crm.Person
  alias Samen.WebTest.Repo

  @rows 97

  setup do
    org = Ash.UUID.generate()
    other = Ash.UUID.generate()

    # job_title: NULL for every 4th row, 3 distinct values otherwise (long duplicate runs);
    # inserted_at: 5 distinct instants (every row has duplicates). A second org's rows must not appear.
    for {o, n} <- [{org, @rows}, {other, 20}] do
      Repo.query!(
        """
        INSERT INTO swp_person (swp_org_id, swp_display_name, swp_job_title, swp_inserted_at, swp_updated_at)
        SELECT $1::uuid, md5(i::text),
               CASE WHEN i % 4 = 0 THEN NULL ELSE 'job-' || (i % 3) END,
               timestamp '2026-01-01 00:00:00' + ((i % 5) || ' hours')::interval, now()
          FROM generate_series(1, $2) AS i
        """,
        [Ecto.UUID.dump!(o), n]
      )
    end

    {:ok, org: org, scope: Mount.scope(build_mount(:crm), org)}
  end

  defp unpaged(scope, field, dir) do
    Person
    |> Ash.Query.sort([{field, dir}, {:id, dir}])
    |> Ash.read!(scope: scope)
    |> Enum.map(& &1.id)
  end

  defp paged(scope, field, dir, size) do
    state = %ListState{sort: {field, dir}, page_size: size}
    collect(scope, state, [])
  end

  defp collect(scope, state, acc) do
    page = Reads.page!(Person, state, scope: scope)
    acc = acc ++ Enum.map(page.items, & &1.id)

    case page.next_cursor do
      nil -> acc
      cursor -> collect(scope, %{state | cursor: cursor}, acc)
    end
  end

  for field <- [:job_title, :inserted_at], dir <- [:asc, :desc], size <- [7, 10, 97, 100] do
    test "paging #{field} #{dir} by #{size} returns exactly the unpaged ordered read", %{scope: scope} do
      expected = unpaged(scope, unquote(field), unquote(dir))
      assert length(expected) == @rows
      assert paged(scope, unquote(field), unquote(dir), unquote(size)) == expected
    end
  end

  test "the seed really has NULLs and duplicates (the property is not vacuous)", %{scope: scope} do
    rows = Ash.read!(Person, scope: scope)
    titles = Enum.map(rows, & &1.job_title)

    assert Enum.any?(titles, &is_nil/1)
    assert length(Enum.uniq(titles)) < length(titles) / 10
    assert length(Enum.uniq(Enum.map(rows, & &1.inserted_at))) <= 5
  end

  test "an ASC cursor on a nullable column still reaches the NULLS-LAST tail", %{scope: scope} do
    ids = paged(scope, :job_title, :asc, 10)
    last = Ash.read!(Person, scope: scope) |> Map.new(&{&1.id, &1.job_title})

    assert last[List.last(ids)] == nil
    assert Enum.count(ids, &(last[&1] == nil)) == div(@rows, 4)
  end
end
