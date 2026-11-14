defmodule Samen.AuditChain.BranchesTest do
  @moduledoc """
  ARCH-26 (ADR-049 watch-list): branches of `Samen.AuditChain` whose silent weakening reads a tampered chain as
  intact or appends to the wrong org, beyond what `audit_chain_test.exs` already proves:

    * `repo/0` — `:audit_chain_repo` → `:reveal_grant_repo`, and a raise (never a guess) when neither is set
    * `append/2` — no org (atom or string key) rides the reserved `__global__` chain
    * `verify_chain/2` — a junk `:batch_size` degrades to the default instead of verifying a window of nothing
    * the resume cursor accepts only `{integer, binary}`
    * `verify_against_anchor/2` — a sealed seq the live chain no longer holds is `:truncated_below_anchor` even
      when rows BEYOND it survive (a deleted middle row), and a rewritten hash is `:anchor_divergence`
  """
  use ExUnit.Case, async: false

  alias Samen.AuditChain
  alias Samen.AuditChain.Entry

  @repo SamenCore.TestRepo

  setup do
    Samen.TestSandbox.shared!(@repo)
    {:ok, org: "org-#{System.unique_integer([:positive])}"}
  end

  defp append!(org, attrs \\ %{}) do
    base = %{
      org_id: org,
      event_type: "reveal",
      subject_id: "subj-#{System.unique_integer([:positive])}",
      actor_id: "op-1",
      detail: "event=granted"
    }

    {:ok, %Entry{} = e} = AuditChain.append(Map.merge(base, attrs), repo: @repo)
    e
  end

  describe "repo/0" do
    defmodule A do
      @moduledoc false
    end

    defmodule B do
      @moduledoc false
    end

    setup do
      prior = for k <- [:audit_chain_repo, :reveal_grant_repo], do: {k, Application.get_env(:samen_core, k)}

      on_exit(fn ->
        for {k, v} <- prior do
          if v == nil, do: Application.delete_env(:samen_core, k), else: Application.put_env(:samen_core, k, v)
        end
      end)

      for {k, _} <- prior, do: Application.delete_env(:samen_core, k)
      :ok
    end

    test "audit_chain_repo wins, reveal_grant_repo is the fallback, and neither set raises" do
      assert_raise RuntimeError, ~r/needs a repo/, fn -> AuditChain.repo() end

      Application.put_env(:samen_core, :reveal_grant_repo, B)
      assert AuditChain.repo() == B

      Application.put_env(:samen_core, :audit_chain_repo, A)
      assert AuditChain.repo() == A

      Application.delete_env(:samen_core, :reveal_grant_repo)
      assert AuditChain.repo() == A
    end
  end

  describe "append/2 with no org" do
    test "rides the reserved __global__ chain, whether the org key is absent, an atom or a string" do
      subject = "subj-#{System.unique_integer([:positive])}"
      base = %{event_type: "reveal", subject_id: subject, actor_id: "op-1", detail: "event=granted"}

      {:ok, e} = AuditChain.append(base, repo: @repo)
      assert e.org_id == AuditChain.global_org()

      org = "org-str-#{System.unique_integer([:positive])}"
      {:ok, s} = AuditChain.append(Map.put(base, "org_id", org), repo: @repo)
      assert s.org_id == org
    end
  end

  describe "verify_chain/2 :batch_size" do
    test "a zero, negative, non-integer or missing batch size verifies the whole chain (default window)", %{org: org} do
      for _ <- 1..3, do: append!(org)

      assert {:ok, %{entries: 3}} = AuditChain.verify_chain(org, repo: @repo, batch_size: 2)

      for bad <- [0, -1, "2", nil, 1.5] do
        assert {:ok, %{entries: 3}} = AuditChain.verify_chain(org, repo: @repo, batch_size: bad),
               "batch_size #{inspect(bad)} must fall back to the default"
      end
    end
  end

  describe "verify_chain_batch/4 cursor" do
    test "{integer, binary} resumes; any other shape is refused by function clause", %{org: org} do
      e0 = append!(org)
      append!(org)

      assert {:done, %{entries: 2}} = AuditChain.verify_chain_batch(@repo, org, {1, e0.hash}, 10)

      for bad <- [{"1", e0.hash}, {1, 5}, {:x, :y}, :nope] do
        assert_raise FunctionClauseError, fn -> AuditChain.verify_chain_batch(@repo, org, bad, 10) end
      end
    end
  end

  describe "verify_against_anchor/2" do
    defmodule Anchor do
      @moduledoc false
      def read_head(_org) do
        case Process.get(:sealed_head) do
          nil -> {:ok, :none}
          head -> {:ok, head}
        end
      end
    end

    defp anchored(org, head) do
      Process.put(:sealed_head, head)
      AuditChain.verify_against_anchor(org, repo: @repo, anchor: Anchor)
    end

    test "verified / no anchor / diverged / truncated (sealed seq beyond the head, empty chain, deleted middle row)",
         %{org: org} do
      e0 = append!(org)
      e1 = append!(org)
      e2 = append!(org)

      assert {:ok, :no_anchor} = anchored(org, nil)
      assert {:ok, :verified} = anchored(org, %{seq: 1, hash: e1.hash})
      assert {:error, :anchor_divergence} = anchored(org, %{seq: 1, hash: e0.hash})

      # the sealed seq is beyond the live head
      assert {:error, :truncated_below_anchor} = anchored(org, %{seq: 9, hash: e2.hash})

      # a chain that was emptied (no rows at all)
      assert {:error, :truncated_below_anchor} = anchored("org-empty-#{System.unique_integer([:positive])}", %{seq: 0, hash: e0.hash})

      # a sealed row that was DELETED while rows beyond it survive
      @repo.query!("ALTER TABLE aud_chain DISABLE TRIGGER aud_chain_append_only_tg")
      @repo.query!("DELETE FROM aud_chain WHERE ach_id = $1", [Ecto.UUID.dump!(e1.id)])
      @repo.query!("ALTER TABLE aud_chain ENABLE TRIGGER aud_chain_append_only_tg")

      assert {:error, :truncated_below_anchor} = anchored(org, %{seq: 1, hash: e1.hash})
      # POSITIVE CONTROL: the surviving tail is still anchored fine
      assert {:ok, :verified} = anchored(org, %{seq: 2, hash: e2.hash})
    end
  end
end
