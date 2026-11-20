defmodule Samen.RevealRequestBackfillTest do
  @moduledoc """
  The S6 reveal-request retrofit migrations (`20261118100000_reveal_request_org_id`, `20261118100001_reveal_request_backfill`,
  written by `mix samen.gen.reveal_requests`), run for real against a scratch database that holds the tables as they were
  BEFORE the change, with requests in every state the records can say something about.

    * `rvq_org_id` is derived from the request's engine approval only; a request with no approval keeps NULL (no guess);
    * `rvq_status` is derived from what is on record: approved / rejected / cancelled approval, a grant, a recorded
      denial; a request whose records DISAGREE and that has no grant, and one with none, stay `pending`; a grant is decisive (`approved`);
    * more rows than one batch (5,000) are all done and the loop ends (the `:where` predicate stops matching);
    * the index is built, the temporary approvals index is gone, the migration re-runs and rolls back cleanly;
    * the task's output for a prefix is byte-identical to the committed migration of the host that uses it.
  """
  use ExUnit.Case, async: false

  alias SamenCore.TestRepo, as: Repo

  @migrations Path.expand("../priv/test_repo/migrations", __DIR__)
  @expand "20261118100000_reveal_request_org_id.exs"
  @backfill "20261118100001_reveal_request_backfill.exs"

  defmodule ScratchRepo do
    use Ecto.Repo, otp_app: :samen_core, adapter: Ecto.Adapters.Postgres
  end

  @setup_version 20_261_118_090_000

  @setup """
  defmodule Samen.RevealRequestBackfillTest.PreChange do
    use Ecto.Migration

    def up do
      execute("CREATE TABLE rvq_reveal_request (rvq_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), rvq_subject_id text NOT NULL, rvq_requestor_id text NOT NULL, rvq_reason text NOT NULL, rvq_status text NOT NULL DEFAULT 'pending', rvq_inserted_at timestamp NOT NULL DEFAULT now(), rvq_updated_at timestamp NOT NULL DEFAULT now())")
      execute("CREATE TABLE rvg_reveal_grant (rvg_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), rvg_request_id uuid NOT NULL)")
      execute("CREATE TABLE rvl_reveal_audit (rvl_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), rvl_subject_id text NOT NULL, rvl_request_id uuid, rvl_event text NOT NULL, rvl_detail text)")
      execute("CREATE TABLE apv_approval (apv_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), apv_org_id uuid, apv_kind text NOT NULL, apv_subject_ref text NOT NULL, apv_state text NOT NULL, apv_requested_at timestamp)")
    end

    def down, do: :ok
  end
  """

  setup_all do
    base = Repo.config()
    db = "#{Keyword.fetch!(base, :database)}_rvbackfill_#{:rand.uniform(1_000_000)}"
    config = base |> Keyword.delete(:pool) |> Keyword.put(:pool_size, 5) |> Keyword.put(:database, db)
    :ok = Samen.TestDb.reset!(config)
    {:ok, _} = ScratchRepo.start_link(config)

    dir = Path.join(System.tmp_dir!(), "rvbackfill_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "#{@setup_version}_pre_change.exs"), @setup)
    File.cp!(Path.join(@migrations, @expand), Path.join(dir, @expand))
    File.cp!(Path.join(@migrations, @backfill), Path.join(dir, @backfill))

    on_exit(fn ->
      Supervisor.stop(ScratchRepo)
      Samen.TestDb.drop!(config)
      File.rm_rf!(dir)
    end)

    {:ok, dir: dir}
  end

  defp migrate(dir, direction, opts) do
    prev = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)

    try do
      Ecto.Migrator.run(ScratchRepo, dir, direction, [log: false, migration_lock: false] ++ opts)
    after
      Code.put_compiler_option(:ignore_module_conflict, prev || false)
    end
  end

  defp q(sql, params \\ []), do: ScratchRepo.query!(sql, params).rows
  defp uuid, do: Ecto.UUID.generate()
  defp ref(id), do: "samen:reveal.request:#{id}"

  defp request(tag) do
    id = uuid()
    q("INSERT INTO rvq_reveal_request (rvq_id, rvq_subject_id, rvq_requestor_id, rvq_reason) VALUES ($1, $2, 'op', $3)", [Ecto.UUID.dump!(id), "subj-#{tag}", tag])
    id
  end

  defp approval(id, state, org) do
    q("INSERT INTO apv_approval (apv_org_id, apv_kind, apv_subject_ref, apv_state, apv_requested_at) VALUES ($1, 'pii_reveal', $2, $3, now())", [org && Ecto.UUID.dump!(org), ref(id), state])
  end

  defp grant(id), do: q("INSERT INTO rvg_reveal_grant (rvg_request_id) VALUES ($1)", [Ecto.UUID.dump!(id)])

  defp denial(id, tag),
    do:
      q("INSERT INTO rvl_reveal_audit (rvl_subject_id, rvl_request_id, rvl_event, rvl_detail) VALUES ($1, $2, 'denied', 'reveal request denied by approver')", [
        "subj-#{tag}",
        Ecto.UUID.dump!(id)
      ])

  defp row(id) do
    [[status, org]] = q("SELECT rvq_status, rvq_org_id::text FROM rvq_reveal_request WHERE rvq_id = $1", [Ecto.UUID.dump!(id)])
    {status, org}
  end

  test "the retrofit derives org and status from the records, never guesses, and is repeatable", %{dir: dir} do
    migrate(dir, :up, to: @setup_version)

    [o1, o2, o3, o4] = [uuid(), uuid(), uuid(), uuid()]

    approved = request("approved") |> tap(&approval(&1, "approved", o1))
    rejected = request("rejected") |> tap(&approval(&1, "rejected", o2))
    cancelled = request("cancelled") |> tap(&approval(&1, "cancelled", o3))
    granted = request("granted") |> tap(&grant/1)
    denial_only = request("denial") |> tap(&denial(&1, "denial"))
    global_approved = request("global") |> tap(&approval(&1, "approved", nil))
    conflict = request("conflict") |> tap(&approval(&1, "approved", o1)) |> tap(&approval(&1, "rejected", o1))
    conflict_rejected_cancelled = request("conflict3") |> tap(&approval(&1, "rejected", o2)) |> tap(&approval(&1, "cancelled", o2))
    # a GRANT is decisive: access was given, so these are approved however the other records disagree (leaving them
    # pending would let an approver mint a second grant)
    conflict_grant_denial = request("conflict2") |> tap(&grant/1) |> tap(&denial(&1, "conflict2"))
    conflict_granted = request("conflict4") |> tap(&approval(&1, "approved", o1)) |> tap(&approval(&1, "rejected", o1)) |> tap(&grant/1)
    pending_with_approval = request("pending") |> tap(&approval(&1, "pending", o4))
    no_records = request("none")
    revived = request("revived") |> tap(&approval(&1, "approved", o1)) |> tap(&approval(&1, "pending", o1))

    # more rows than one batch of 5,000, all derivable: every one must be done, and the loop must end
    q("""
    WITH ids AS (SELECT gen_random_uuid() AS id FROM generate_series(1, 5001)),
         r AS (INSERT INTO rvq_reveal_request (rvq_id, rvq_subject_id, rvq_requestor_id, rvq_reason) SELECT id, 'bulk', 'op', 'bulk' FROM ids RETURNING rvq_id)
    INSERT INTO rvg_reveal_grant (rvg_request_id) SELECT rvq_id FROM r
    """)

    output = ExUnit.CaptureIO.capture_io(fn -> migrate(dir, :up, all: true) end)

    assert row(approved) == {"approved", o1}
    assert row(rejected) == {"denied", o2}
    assert row(cancelled) == {"cancelled", o3}
    assert row(granted) == {"approved", nil}
    assert row(denial_only) == {"denied", nil}
    assert row(global_approved) == {"approved", nil}
    assert row(revived) == {"approved", o1}

    assert row(conflict_grant_denial) == {"approved", nil}
    assert row(conflict_granted) == {"approved", o1}

    # nothing is guessed: grant-less records that disagree, no records, and a request that is truly pending stay pending
    assert row(conflict) == {"pending", o1}
    assert row(conflict_rejected_cancelled) == {"pending", o2}
    assert row(no_records) == {"pending", nil}
    assert row(pending_with_approval) == {"pending", o4}

    # ... and the two that disagree are SAID, with their count; the notice never tells the operator to approve
    assert output =~ "2 pending request(s) have records that disagree"
    refute output =~ "approve"
    refute output =~ "Grants.deny"

    assert [[5001]] = q("SELECT count(*) FROM rvq_reveal_request WHERE rvq_subject_id = 'bulk' AND rvq_status = 'approved'")

    # the scan index exists and is valid; the temporary approvals index is gone
    assert [[true]] =
             q("SELECT i.indisvalid FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid WHERE c.relname = 'rvq_reveal_request_org_inserted_at_id_idx'")

    assert [] = q("SELECT 1 FROM pg_class WHERE relname = 'apv_approval_reveal_ref_tmp_idx'")

    # repeatable: down, then up again, changes nothing it should not and does not fail
    before = q("SELECT rvq_id::text, rvq_status, rvq_org_id::text FROM rvq_reveal_request ORDER BY 1")
    ExUnit.CaptureIO.capture_io(fn -> migrate(dir, :down, step: 1) end)
    assert [] = q("SELECT 1 FROM pg_class WHERE relname = 'rvq_reveal_request_org_inserted_at_id_idx'")
    ExUnit.CaptureIO.capture_io(fn -> migrate(dir, :up, all: true) end)
    assert before == q("SELECT rvq_id::text, rvq_status, rvq_org_id::text FROM rvq_reveal_request ORDER BY 1")

    # the expand step rolls back (DownCheck's contract) and re-applies
    migrate(dir, :down, step: 2)
    assert [] = q("SELECT 1 FROM information_schema.columns WHERE table_name = 'rvq_reveal_request' AND column_name = 'rvq_org_id'")
  end

  test "the task's output for a prefix is the committed migration of the host that uses it (one source of truth)" do
    root = Path.expand("../..", __DIR__)

    for {repo, prefix, dir} <- [
          {Demo.Repo, "daa", "demo/priv/repo/migrations"},
          {Driftwood.Repo, "fap", "driftwood/priv/repo/migrations"},
          {SamenCore.TestRepo, "apv", "samen_core/priv/test_repo/migrations"},
          {PawChart.Repo, nil, "pawchart/priv/repo/migrations"},
          {Samen.WebTest.Repo, nil, "samen_web/priv/repo/migrations"}
        ] do
      {expand, backfill} = Mix.Tasks.Samen.Gen.RevealRequests.render(repo, prefix, "20261118100000", suffix: "")
      assert File.read!(Path.join([root, dir, @expand])) == expand, "#{dir}: #{@expand} drifted from the task"
      assert File.read!(Path.join([root, dir, @backfill])) == backfill, "#{dir}: #{@backfill} drifted from the task"
    end
  end
end
