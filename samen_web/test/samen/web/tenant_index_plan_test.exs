defmodule Samen.Web.TenantIndexPlanTest do
  @moduledoc """
  ARCH-4 — the PLANNER uses the tenant keyset index `(org_id, <keyset sort>, id)`.

  `mix samen.verify.indexes` proves the index EXISTS. This proves the thing it exists for: the
  statement `Samen.Web.Reads` really sends for an org-scoped keyset page is an ordered index scan
  that stops at `LIMIT`, in both sort directions, on the first page and on a page after a cursor —
  with no `Seq Scan` of the table and no `Sort` node.

  The SQL is NOT hand-written: it is captured from the repo's telemetry while the real
  `Samen.Web.Reads.page!/3` runs (so it carries the OrgScope filter, the archival filter, the
  keyset ORDER BY and the cursor OR-chain exactly as Ash emits them), then re-sent under
  `EXPLAIN (FORMAT JSON)` with the same bound parameters.

  Two orgs of 20_000 rows each per table (person, ticket, message) — enough that a sequential scan
  plus top-N sort is visibly more expensive than the index walk, and small enough for the `pr`
  budget (a 1M-row lane would not change the planner's choice, only the seed time).

  Positive control (anti-tautology): the same assertion goes RED once the index is dropped inside
  the test transaction — the plan falls back to a `Seq Scan` + `Sort`, so the test cannot pass
  vacuously.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.ListState
  alias Samen.Web.Mount
  alias Samen.Web.Reads
  alias Samen.WebTest.Crm.Person
  alias Samen.WebTest.Repo
  alias Samen.WebTest.Support.{Message, Ticket}

  @rows_per_org 20_000

  setup context do
    org_a = Ash.UUID.generate()
    org_b = Ash.UUID.generate()
    seed!(context.seed, [org_a, org_b])
    {:ok, org: org_a, scope: Mount.scope(build_mount(:crm), org_a)}
  end

  # -- seeding (raw SQL: 120k rows through Ash would take minutes) -------------------------

  defp seed!(:person, orgs) do
    Repo.query!(
      """
      INSERT INTO swp_person (swp_org_id, swp_display_name, swp_inserted_at, swp_updated_at)
      SELECT o, md5(i::text), now(), now()
        FROM unnest($1::uuid[]) AS o, generate_series(1, $2) AS i
      """,
      [Enum.map(orgs, &Ecto.UUID.dump!/1), @rows_per_org]
    )

    Repo.query!("ANALYZE swp_person")
  end

  defp seed!(kind, orgs) when kind in [:ticket, :message] do
    Repo.query!(
      """
      INSERT INTO wsk_ticket (wsk_org_id, wsk_subject, wsk_inserted_at, wsk_updated_at)
      SELECT o, md5(i::text), now(), now()
        FROM unnest($1::uuid[]) AS o, generate_series(1, $2) AS i
      """,
      [Enum.map(orgs, &Ecto.UUID.dump!/1), @rows_per_org]
    )

    Repo.query!("ANALYZE wsk_ticket")
    if kind == :message, do: seed_messages!(orgs)
  end

  defp seed_messages!(orgs) do
    Repo.query!("""
    INSERT INTO wsc_conversation (wsc_org_id, wsc_ticket_id, wsc_inserted_at, wsc_updated_at)
    SELECT wsk_org_id, (array_agg(wsk_id))[1], now(), now() FROM wsk_ticket GROUP BY wsk_org_id
    """)

    Repo.query!(
      """
      INSERT INTO wsm_message (wsm_org_id, wsm_conversation_id, wsm_inserted_at, wsm_updated_at)
      SELECT c.wsc_org_id, c.wsc_id, now() - (i || ' seconds')::interval, now()
        FROM wsc_conversation c, generate_series(1, $1) AS i
       WHERE c.wsc_org_id = ANY($2::uuid[])
      """,
      [@rows_per_org, Enum.map(orgs, &Ecto.UUID.dump!/1)]
    )

    Repo.query!("ANALYZE wsm_message")
  end

  # -- capturing the real statement ----------------------------------------------------------

  # Run `fun` and return the LAST statement that reads `table` with a LIMIT — the page query.
  defp capture_page_sql(table, fun) do
    ref = make_ref()
    me = self()
    event = Repo.config()[:telemetry_prefix] ++ [:query]
    id = {__MODULE__, ref}

    :telemetry.attach(id, event, &__MODULE__.handle_query/4, {me, ref})

    try do
      result = fun.()
      {result, drain(ref, table, nil)}
    after
      :telemetry.detach(id)
    end
  end

  @doc false
  def handle_query(_event, _measurements, metadata, {pid, ref}),
    do: send(pid, {ref, metadata.query, metadata.params})

  defp drain(ref, table, last) do
    receive do
      {^ref, sql, params} ->
        if sql =~ ~s(FROM "#{table}") and sql =~ "LIMIT",
          do: drain(ref, table, {sql, params}),
          else: drain(ref, table, last)
    after
      0 -> last || flunk("no page statement against #{table} was captured")
    end
  end

  defp explain({sql, params}) do
    %{rows: [[[%{"Plan" => root}]]]} = Repo.query!("EXPLAIN (FORMAT JSON) " <> sql, params)
    flatten(root)
  end

  defp flatten(node), do: [node | Enum.flat_map(node["Plans"] || [], &flatten/1)]

  # The page is served by `index` iff an Index Scan on it walks in `direction`, nothing seq-scans
  # `table`, and nothing sorts (the index already delivers the ORDER BY).
  defp assert_index_page!(nodes, table, index, direction) do
    assert Enum.any?(nodes, &(&1["Index Name"] == index and &1["Node Type"] == "Index Scan")),
           "expected an Index Scan on #{index}; plan nodes: #{inspect(summary(nodes))}"

    assert Enum.any?(nodes, &(&1["Index Name"] == index and &1["Scan Direction"] == direction)),
           "expected the #{index} scan to run #{direction}; plan nodes: #{inspect(summary(nodes))}"

    refute Enum.any?(nodes, &(&1["Node Type"] == "Seq Scan" and &1["Relation Name"] == table)),
           "#{table} was sequentially scanned: #{inspect(summary(nodes))}"

    refute Enum.any?(nodes, &(&1["Node Type"] in ["Sort", "Incremental Sort"])),
           "the page still sorts (the index does not deliver the ORDER BY): #{inspect(summary(nodes))}"
  end

  defp summary(nodes), do: Enum.map(nodes, &{&1["Node Type"], &1["Relation Name"], &1["Index Name"]})

  defp page(%Ash.Query{resource: resource} = query, scope, state) do
    capture_page_sql(AshPostgres.DataLayer.Info.table(resource), fn ->
      Reads.page!(query, state, scope: scope)
    end)
  end

  defp page(resource, scope, state) do
    capture_page_sql(AshPostgres.DataLayer.Info.table(resource), fn ->
      Reads.page!(resource, state, scope: scope)
    end)
  end

  defp index_of(resource) do
    {:ok, spec} = Samen.Indexing.spec(resource)
    spec.name
  end

  # -- person: ORDER BY display_name ASC, id ASC ---------------------------------------------

  @tag seed: :person
  test "person — the first page and the page after a cursor are ordered index scans (ASC, forward)", %{scope: scope} do
    index = index_of(Person)
    state = %ListState{sort: {:display_name, :asc}, page_size: 25}

    {%{items: items, next_cursor: cursor}, sql} = page(Person, scope, state)
    assert length(items) == 25
    assert_index_page!(explain(sql), "swp_person", index, "Forward")

    {%{items: second}, sql2} = page(Person, scope, %{state | cursor: cursor})
    assert length(second) == 25
    assert_index_page!(explain(sql2), "swp_person", index, "Forward")
  end

  @tag seed: :person
  test "person — DESC is the same index walked backward", %{scope: scope} do
    {_page, sql} = page(Person, scope, %ListState{sort: {:display_name, :desc}, page_size: 25})
    assert_index_page!(explain(sql), "swp_person", index_of(Person), "Backward")
  end

  @tag seed: :person
  test "POSITIVE CONTROL — drop the index and the same assertion fails (Seq Scan + Sort)", %{scope: scope} do
    index = index_of(Person)
    state = %ListState{sort: {:display_name, :asc}, page_size: 25}

    {_page, sql} = page(Person, scope, state)
    assert_index_page!(explain(sql), "swp_person", index, "Forward")

    Repo.query!(~s(DROP INDEX "#{index}"))
    Repo.query!("ANALYZE swp_person")

    {_page, sql_after} = page(Person, scope, state)
    nodes = explain(sql_after)

    assert_raise ExUnit.AssertionError, fn ->
      assert_index_page!(nodes, "swp_person", index, "Forward")
    end

    assert Enum.any?(nodes, &(&1["Node Type"] == "Seq Scan" and &1["Relation Name"] == "swp_person")),
           "without the index the page must fall back to a sequential scan: #{inspect(summary(nodes))}"
  end

  # -- ticket: ORDER BY subject ASC, id ASC ---------------------------------------------------

  @tag seed: :ticket
  test "ticket — the support list page is an ordered index scan", %{scope: scope} do
    index = index_of(Ticket)
    state = %ListState{sort: {:subject, :asc}, page_size: 25}

    {%{next_cursor: cursor}, sql} = page(Ticket, scope, state)
    assert_index_page!(explain(sql), "wsk_ticket", index, "Forward")

    {_page, sql2} = page(Ticket, scope, %{state | cursor: cursor})
    assert_index_page!(explain(sql2), "wsk_ticket", index, "Forward")
  end

  @tag seed: :ticket
  test "ticket — POSITIVE CONTROL: without the index the page seq-scans", %{scope: scope} do
    index = index_of(Ticket)
    Repo.query!(~s(DROP INDEX "#{index}"))
    Repo.query!("ANALYZE wsk_ticket")

    {_page, sql} = page(Ticket, scope, %ListState{sort: {:subject, :asc}, page_size: 25})
    nodes = explain(sql)

    assert_raise ExUnit.AssertionError, fn -> assert_index_page!(nodes, "wsk_ticket", index, "Forward") end
    assert Enum.any?(nodes, &(&1["Node Type"] == "Seq Scan" and &1["Relation Name"] == "wsk_ticket"))
  end

  # -- message: ORDER BY inserted_at DESC, id DESC (newest first) -----------------------------

  @tag seed: :message
  test "message — a newest-first page walks the (org_id, inserted_at, id) index backward", %{scope: scope} do
    index = index_of(Message)
    state = %ListState{sort: {:inserted_at, :desc}, page_size: 25}

    {%{items: items, next_cursor: cursor}, sql} = page(Message, scope, state)
    assert length(items) == 25
    assert_index_page!(explain(sql), "wsm_message", index, "Backward")

    {_page, sql2} = page(Message, scope, %{state | cursor: cursor})
    assert_index_page!(explain(sql2), "wsm_message", index, "Backward")
  end

  @tag seed: :message
  test "message — POSITIVE CONTROL: without the index the page seq-scans", %{scope: scope} do
    index = index_of(Message)
    Repo.query!(~s(DROP INDEX "#{index}"))
    Repo.query!("ANALYZE wsm_message")

    {_page, sql} = page(Message, scope, %ListState{sort: {:inserted_at, :desc}, page_size: 25})
    nodes = explain(sql)

    assert_raise ExUnit.AssertionError, fn -> assert_index_page!(nodes, "wsm_message", index, "Backward") end
    assert Enum.any?(nodes, &(&1["Node Type"] == "Seq Scan" and &1["Relation Name"] == "wsm_message"))
  end

  @tag seed: :person
  test "the other org's rows are not in the page (the index is walked under the org_id equality)", %{scope: scope, org: org} do
    {%{items: items}, _sql} =
      page(Ash.Query.ensure_selected(Person, [:org_id]), scope, %ListState{sort: {:display_name, :asc}, page_size: 50})
    assert items != [] and Enum.all?(items, &(&1.org_id == org))
  end
end
