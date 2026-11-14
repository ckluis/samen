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

  describe "the ASC bound follows the DATABASE column, not the attribute's allow_nil? (WP12)" do
    setup do
      Samen.Indexing.reset_not_null_cache()
      on_exit(&Samen.Indexing.reset_not_null_cache/0)
      :ok
    end

    test "positive control: a NOT NULL column gets the bound (and still pages exactly)", %{scope: scope} do
      assert {:ok, true} = Samen.Indexing.column_not_null(Person, :inserted_at)
      assert Samen.Indexing.column_not_null?(Person, :inserted_at)
      assert paged(scope, :inserted_at, :asc, 10) == unpaged(scope, :inserted_at, :asc)
    end

    test "an allow_nil? false attribute over a NULLABLE column gets no bound and keeps its NULL tail", %{
      org: org,
      scope: scope
    } do
      assert %{allow_nil?: false} = Ash.Resource.Info.attribute(Person, :inserted_at)

      # a hand migration the resource never heard of (rolled back with the test's sandbox transaction)
      Repo.query!("ALTER TABLE swp_person ALTER COLUMN swp_inserted_at DROP NOT NULL")

      Repo.query!(
        "INSERT INTO swp_person (swp_org_id, swp_display_name, swp_inserted_at, swp_updated_at) " <>
          "SELECT $1::uuid, 'null-' || i, NULL, now() FROM generate_series(1, 9) AS i",
        [Ecto.UUID.dump!(org)]
      )

      assert {:ok, false} = Samen.Indexing.column_not_null(Person, :inserted_at)
      refute Samen.Indexing.column_not_null?(Person, :inserted_at)

      expected = unpaged(scope, :inserted_at, :asc)
      assert length(expected) == @rows + 9

      # a deep ASC page: every NULL-sorted row is still reached
      for size <- [7, 10, 50] do
        assert paged(scope, :inserted_at, :asc, size) == expected
      end
    end

    test "an undeterminable column is `unknown` and gets no bound (and is not cached)" do
      assert :unknown = Samen.Indexing.column_not_null(Person, :no_such_attribute)
      assert :unknown = Samen.Indexing.column_not_null(Person, :inserted_at, repo: Samen.NoSuchRepo)
    end

    test "the answer is cached per resource: no catalog query on the second page read", %{scope: scope} do
      assert Samen.Indexing.column_not_null?(Person, :inserted_at)
      # the column is relaxed behind the cache's back: the cached answer stands until reset
      Repo.query!("ALTER TABLE swp_person ALTER COLUMN swp_inserted_at DROP NOT NULL")
      assert Samen.Indexing.column_not_null?(Person, :inserted_at)
      Samen.Indexing.reset_not_null_cache()
      refute Samen.Indexing.column_not_null?(Person, :inserted_at)
      assert paged(scope, :inserted_at, :asc, 10) == unpaged(scope, :inserted_at, :asc)
    end
  end
end
