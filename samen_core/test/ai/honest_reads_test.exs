defmodule Samen.AI.HonestReadsTest do
  @moduledoc """
  Honest reads for the AI / agent area: a read or probe that FAILED is a tagged error, a raise or a failure on record —
  never "absent", "empty", "not vault-routed" or "nothing to reject". Every red is paired with a positive control on
  the same call (the anti-tautology rule), and the failure is injected through `Samen.FaultRepo` (a real
  `DBConnection.ConnectionError`) or a malformed input the read genuinely rejects, never a stub of the code under test.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Samen.AI.Agent.{Breaker, FoldSource, Health}
  alias Samen.AI.{Embeddings, ToolSurface}
  alias Samen.OperatorPlane.Actor
  alias SamenCore.Support.EmbeddingsDomain.Article
  alias SamenCore.TestRepo

  setup do
    Samen.TestSandbox.shared!(TestRepo)
    on_exit(&Samen.FaultRepo.heal/0)
    :ok
  end

  defp scope(org_id) do
    %Samen.Scope{actor: %{id: "u:#{org_id}", org_id: org_id, role: :member, plane: :tenant}}
  end

  describe "FoldSource: a failed existence probe is not an absent table" do
    test "RED: withdraw_subject / withdrawn? / run_ids_citing RAISE when the probe fails (they answered :absent / false / [])" do
      run_id = Ash.UUID.generate()

      # POSITIVE CONTROL: the probe works, the table is there, nothing to withdraw
      assert %{table: :present, rows_withdrawn: 0} = FoldSource.withdraw_subject("sref-honest", TestRepo)
      assert FoldSource.withdrawn?(run_id, TestRepo) == false
      assert FoldSource.run_ids_citing("sref-honest", TestRepo) == []

      Samen.FaultRepo.fail([:query])

      assert_raise RuntimeError, ~r/could not be probed/, fn -> FoldSource.withdraw_subject("sref-honest", Samen.FaultRepo) end
      assert_raise RuntimeError, ~r/could not be probed/, fn -> FoldSource.withdrawn?(run_id, Samen.FaultRepo) end
      assert_raise RuntimeError, ~r/could not be probed/, fn -> FoldSource.run_ids_citing("sref-honest", Samen.FaultRepo) end
    end
  end

  describe "Embeddings" do
    test "RED: a failed nearest-neighbour read is {:error, :unavailable} (it answered {:ok, []} = no matches); healthy it answers" do
      org = Ash.UUID.generate()

      assert {:ok, []} = Embeddings.search(scope(org), "anything", repo: TestRepo)

      Samen.FaultRepo.fail([:query])

      log = capture_log(fn -> assert {:error, :unavailable} = Embeddings.search(scope(org), "anything", repo: Samen.FaultRepo) end)
      assert log =~ "read=embeddings_knn"
    end

    test "RED: a failed stale read is {:error, :unavailable} / a raise, and reembed_stale does not claim {:ok, 0 re-embedded}" do
      assert {:ok, _rows} = Embeddings.stale_rows_result(TestRepo, "det-honest")
      assert is_list(Embeddings.stale_rows(TestRepo, "det-honest"))
      assert {:ok, %{reembedded: _, errors: []}} = Embeddings.reembed_stale(repo: TestRepo)

      Samen.FaultRepo.fail([:query])

      capture_log(fn ->
        assert {:error, :unavailable} = Embeddings.stale_rows_result(Samen.FaultRepo, "det-honest")
        assert_raise RuntimeError, ~r/could not be read/, fn -> Embeddings.stale_rows(Samen.FaultRepo, "det-honest") end
        assert {:error, :unavailable} = Embeddings.reembed_stale(repo: Samen.FaultRepo)
      end)
    end

    defmodule NoDslEmbeddable do
      @moduledoc false
      # Declares a field embeddable but is not a Samen/Ash resource: its vault-routing cannot be introspected.
      def embeddable_fields, do: [:body]
    end

    test "RED: a resource whose vault routing cannot be introspected is NOT embeddable (it read as 'routes nothing'); a declared non-PII field embeds (control)" do
      org = Ash.UUID.generate()
      id = Ash.UUID.generate()

      assert {:ok, _vector} = Embeddings.embed_field(scope(org), Article, id, :body, "a plain body", repo: TestRepo)

      log =
        capture_log(fn ->
          assert {:error, :field_not_embeddable} =
                   Embeddings.embed_field(scope(org), NoDslEmbeddable, id, :body, "a plain body", repo: TestRepo)
        end)

      assert log =~ "read=embeddings_vault_routed"
    end
  end

  describe "agent Breaker.kills/1" do
    test "RED: an org whose kill rows cannot be READ raises (it answered [] = 'no kills'); kills_status stays tagged; nil org is []" do
      org = Ash.UUID.generate()

      # POSITIVE CONTROL
      assert Breaker.kills(org) == []
      assert Breaker.kills(nil) == []

      capture_log(fn ->
        assert {:error, :unavailable} = Breaker.kills_status("not-a-uuid")
        assert_raise RuntimeError, ~r/could not be read/, fn -> Breaker.kills("not-a-uuid") end
      end)
    end
  end

  describe "AI agent Health" do
    test "RED: a run / turn log that cannot be READ is {:error, :unavailable} (it answered an empty fleet); healthy control" do
      operator = Actor.new("op-honest", :operator_admin)
      org = Ash.UUID.generate()
      run_id = Ash.UUID.generate()

      assert {:ok, []} = Health.summary(operator, org)
      assert {:ok, []} = Health.runs(operator, org)
      assert {:ok, []} = Health.turns(operator, org, run_id)

      capture_log(fn ->
        assert {:error, :unavailable} = Health.summary(operator, org, limit: :bad)
        assert {:error, :unavailable} = Health.runs(operator, org, limit: :bad)
        assert {:error, :unavailable} = Health.turns(operator, org, run_id, limit: :bad)
      end)
    end
  end

  describe "Agent.reject_proposal/3" do
    test "RED: a turn that cannot be READ rolls the rejection back ({:error, :unavailable}); a turn that is gone is :ok (control)" do
      # POSITIVE CONTROL: no such turn -> nothing to reject, never blocks the rejection
      turn_id = Ash.UUID.generate()
      assert :ok = Samen.AI.Agent.reject_proposal(turn_id, %{}, %{})

      # A REAL read failure of a well-formed id (the Turn table is unreadable inside this sandbox transaction, which
      # rolls back with the test) is an outage, not "no such turn".
      TestRepo.query!("ALTER TABLE ai_agent_turn RENAME TO ai_agent_turn_unreadable")

      capture_log(fn ->
        assert {:error, :unavailable} = Samen.AI.Agent.reject_proposal(turn_id, %{}, %{})
      end)
    end

    test "RED: a MALFORMED turn id is 'no such turn' (:ok) - a garbled approval can still be rejected - not an outage" do
      assert :ok = Samen.AI.Agent.reject_proposal(Ash.UUID.generate(), %{}, %{})
      assert :ok = Samen.AI.Agent.reject_proposal("not-a-uuid", %{}, %{})
      assert :ok = Samen.AI.Agent.reject_proposal("samen:atn:garbled", %{}, %{})
    end
  end

  describe "ReembedWorker" do
    test "RED: a failed stale read is {:error, :unavailable} so Oban retries (it crashed with a CaseClauseError); healthy it is :ok" do
      job = %Oban.Job{id: 4242, args: %{}}

      # POSITIVE CONTROL
      assert :ok = Samen.AI.Embeddings.ReembedWorker.perform(job)

      previous = Application.get_env(:samen_core, :vault_repo)
      Application.put_env(:samen_core, :vault_repo, Samen.FaultRepo)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:samen_core, :vault_repo, previous),
          else: Application.delete_env(:samen_core, :vault_repo)
      end)

      Samen.FaultRepo.fail([:query])

      capture_log(fn ->
        assert {:error, :unavailable} = Samen.AI.Embeddings.ReembedWorker.perform(job)
      end)
    end
  end

  describe "Embeddings.embedder_simulated?/1" do
    defmodule RaisingSimulated do
      @moduledoc false
      def simulated?, do: raise("boom")
    end

    defmodule RealProvider do
      @moduledoc false
      def simulated?, do: false
    end

    test "RED: a provider whose simulated?/0 raises is NOT claimed real (true = not verified real); a declared-real one is false (control)" do
      assert {:ok, false} = Embeddings.embedder_simulated?(embedder: {RealProvider, %{}})

      log = capture_log(fn -> assert {:ok, true} = Embeddings.embedder_simulated?(embedder: {RaisingSimulated, %{}}) end)
      assert log =~ "read=embeddings_simulated_provider"
    end
  end

  describe "ToolSurface.surfaces_for/1" do
    defmodule RaisingSurfaces do
      @moduledoc false
      def tool_surfaces, do: raise("boom")
    end

    test "a surface declaration that raises is fail-closed [] AND on record; a clean one is untouched (control)" do
      assert ToolSurface.surfaces_for(String) == [:tenant]

      log = capture_log(fn -> assert ToolSurface.surfaces_for(RaisingSurfaces) == [] end)
      assert log =~ "read=tool_surface_surfaces_for"
    end
  end
end
