defmodule Samen.Web.CrmRefsIndexPlanTest do
  @moduledoc """
  ARCH-4 item 6 — the CRM detail timelines (`Samen.Web.CRM.Reads.activities_for_person/3` and
  `activities_for_company/3`) read the Work `Task` by
  `(subject_key = 'crm.person' AND subject_id = $) OR get_path(custom, ["crm_refs", "person_id"]) = $`.

  AshPostgres renders the second arm as `jsonb_extract_path_text(custom::jsonb, $1::text, $2::text) = $3`.
  No btree on `custom` can serve a computed value, so the OR forced a sequential scan of the org's tasks.
  The partial expression indexes `…_custom_crm_refs_{person,company}_id_idx` match that exact expression
  once the path and value are bound, so the planner can `BitmapOr` them with the `(subject_key,
  subject_id)` index.

  The SQL is captured from the repo's telemetry while the REAL read function runs, then re-sent under
  `EXPLAIN (FORMAT JSON)` with the same parameters. Positive control: drop the expression index inside the
  test transaction and the same assertion goes red (the plan reads every task of the org through the plain `org_id` index and filters).
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.CRM.Reads
  alias Samen.Web.Mount
  alias Samen.WebTest.Repo

  @rows_per_org 20_000
  @person_idx "wwt_task_wwt_custom_crm_refs_person_id_idx"
  @company_idx "wwt_task_wwt_custom_crm_refs_company_id_idx"
  @anchor_idx "wwt_task_wwt_subject_key_wwt_subject_id_index"

  setup do
    org = Ash.UUID.generate()
    other = Ash.UUID.generate()
    person = Ash.UUID.generate()
    company = Ash.UUID.generate()

    Repo.query!(
      """
      INSERT INTO wwt_task (wwt_org_id, wwt_title, wwt_inserted_at, wwt_updated_at)
      SELECT o, md5(i::text), now(), now()
        FROM unnest($1::uuid[]) AS o, generate_series(1, $2) AS i
      """,
      [[Ecto.UUID.dump!(org), Ecto.UUID.dump!(other)], @rows_per_org]
    )

    # A migrated multi-anchor task (the preservation bag), a primary-anchor task, in the target org.
    Repo.query!(
      """
      INSERT INTO wwt_task (wwt_org_id, wwt_title, wwt_custom, wwt_inserted_at, wwt_updated_at)
      VALUES ($1, 'via-refs', jsonb_build_object('crm_refs', jsonb_build_object('person_id', $2::text, 'company_id', $3::text)), now(), now())
      """,
      [Ecto.UUID.dump!(org), person, company]
    )

    Repo.query!(
      """
      INSERT INTO wwt_task (wwt_org_id, wwt_title, wwt_subject_key, wwt_subject_id, wwt_inserted_at, wwt_updated_at)
      VALUES ($1, 'via-anchor', 'crm.person', $2, now(), now())
      """,
      [Ecto.UUID.dump!(org), Ecto.UUID.dump!(person)]
    )

    Repo.query!("ANALYZE wwt_task")

    mount = build_mount(:crm)
    {:ok, mount: mount, scope: Mount.scope(mount, org), person: person, company: company}
  end

  defp capture_sql(fun) do
    ref = make_ref()
    id = {__MODULE__, ref}
    :telemetry.attach(id, Repo.config()[:telemetry_prefix] ++ [:query], &__MODULE__.handle_query/4, {self(), ref})

    try do
      result = fun.()
      {result, drain(ref, nil)}
    after
      :telemetry.detach(id)
    end
  end

  @doc false
  def handle_query(_event, _measurements, metadata, {pid, ref}),
    do: send(pid, {ref, metadata.query, metadata.params})

  defp drain(ref, last) do
    receive do
      {^ref, sql, params} ->
        if sql =~ ~s(FROM "wwt_task") and sql =~ "LIMIT", do: drain(ref, {sql, params}), else: drain(ref, last)
    after
      0 -> last || flunk("no wwt_task read was captured")
    end
  end

  defp nodes({sql, params}) do
    %{rows: [[[%{"Plan" => root}]]]} = Repo.query!("EXPLAIN (FORMAT JSON) " <> sql, params)
    flatten(root)
  end

  defp flatten(node), do: [node | Enum.flat_map(node["Plans"] || [], &flatten/1)]
  defp summary(nodes), do: Enum.map(nodes, &{&1["Node Type"], &1["Index Name"]})

  # Both arms of the OR are index-served and no seq scan of the table remains.
  defp assert_or_served!(nodes, expression_idx) do
    names = for n <- nodes, n["Index Name"], do: n["Index Name"]

    assert expression_idx in names and @anchor_idx in names,
           "expected a BitmapOr of #{expression_idx} and #{@anchor_idx}: #{inspect(summary(nodes))}"

    assert Enum.any?(nodes, &(&1["Node Type"] == "BitmapOr")), inspect(summary(nodes))

    refute Enum.any?(nodes, &(&1["Node Type"] == "Seq Scan" and &1["Relation Name"] == "wwt_task")),
           "wwt_task was sequentially scanned: #{inspect(summary(nodes))}"
  end

  test "the person timeline reads both arms through an index (BitmapOr), and returns both rows", ctx do
    {rows, sql} = capture_sql(fn -> Reads.activities_for_person(ctx.mount, ctx.scope, ctx.person) end)

    assert rows |> Enum.map(& &1.title) |> Enum.sort() == ["via-anchor", "via-refs"]
    assert_or_served!(nodes(sql), @person_idx)
  end

  test "the company timeline reads both arms through an index (BitmapOr)", ctx do
    {rows, sql} = capture_sql(fn -> Reads.activities_for_company(ctx.mount, ctx.scope, ctx.company) end)

    assert Enum.map(rows, & &1.title) == ["via-refs"]
    assert_or_served!(nodes(sql), @company_idx)
  end

  test "POSITIVE CONTROL — drop the expression index and the person plan reads the whole org", ctx do
    {_rows, sql} = capture_sql(fn -> Reads.activities_for_person(ctx.mount, ctx.scope, ctx.person) end)
    assert_or_served!(nodes(sql), @person_idx)

    Repo.query!(~s(DROP INDEX "#{@person_idx}"))
    Repo.query!("ANALYZE wwt_task")

    {_rows, sql_after} = capture_sql(fn -> Reads.activities_for_person(ctx.mount, ctx.scope, ctx.person) end)
    after_nodes = nodes(sql_after)

    assert_raise ExUnit.AssertionError, fn -> assert_or_served!(after_nodes, @person_idx) end

    # No expression index, so the OR cannot be BitmapOr'd: the planner walks the WHOLE org's tasks
    # (the plain org_id index, or a seq scan) and filters every row.
    assert Enum.any?(
             after_nodes,
             &(&1["Node Type"] == "Seq Scan" or &1["Index Name"] == "wwt_task_wwt_org_id_index")
           ),
           "without the expression index the OR must read the whole org: #{inspect(summary(after_nodes))}"

    refute Enum.any?(after_nodes, &(&1["Node Type"] == "BitmapOr"))
  end
end
