defmodule Samen.Web.ReadsGroupByTest do
  @moduledoc """
  The GENERIC group-by read primitive (`Samen.Web.Reads.group_by!/3`, G4/WS-G) — the
  framework building block the WS-G grouped views (G1 kanban first) consume. Four proofs,
  each anti-tautology (a positive control paired with the guard so the assertion is refutable):

    * GROUPING — a seeded multi-group resource groups into ORDERED buckets (caller-ordered
      columns AND discovered columns), each bucket holding exactly its rows.
    * ORG-SCOPE — a 2-org seed: org B's rows NEVER appear in org A's groups (sabotage-
      refutable — org B genuinely holds same-key rows, proven absent from org A's board).
    * BOUNDING — a column with MORE than the cap returns the cap + `has_more` + the exact
      `count`, NEVER the whole set (positive control: an under-cap column returns everything).
    * MASKING (INV-1) — grouping a VAULT-ROUTED field is REFUSED (raises), never a plaintext
      or vault-token bucket; a non-vaulted field groups fine (the refutation control).
  """
  use Samen.WebTest.DataCase, async: false

  require Ash.Query

  alias Samen.Web.Board
  alias Samen.Web.Mount
  alias Samen.Web.Reads
  alias Samen.Web.Reads.MaskedGroupKeyError

  @person Samen.WebTest.Crm.Person

  defp create_person(org_id, title, name) do
    @person
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org_id,
        display_name: name,
        job_title: title,
        full_name: %Samen.Type.FullName{first: name, last: "X"}
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  defp seed_org(mount, spec) do
    org_id = Ash.UUID.generate()

    for {title, n} <- spec, i <- 1..n do
      create_person(org_id, title, "#{title}-#{i}")
    end

    {org_id, Mount.scope(mount, org_id)}
  end

  defp group_keys(%Board{groups: groups}), do: Enum.map(groups, & &1.key)
  defp group(%Board{groups: groups}, key), do: Enum.find(groups, &(&1.key == key))

  # -- GROUPING ----------------------------------------------------------------

  test "GROUPING: caller-ordered columns → ordered buckets, each with exactly its rows" do
    mount = build_mount(:crm)
    {_org, scope} = seed_org(mount, %{"Broker" => 3, "Dispatcher" => 2, "Clerk" => 1})

    # Columns in a caller-chosen order that is NOT alphabetical — proves the primitive
    # preserves the given order (the kanban stage-order case) rather than re-sorting.
    board =
      Mount.resource(mount, Person)
      |> Reads.group_by!(:job_title,
        scope: scope,
        groups: ["Clerk", "Broker", "Dispatcher"]
      )

    assert group_keys(board) == ["Clerk", "Broker", "Dispatcher"]
    assert group(board, "Clerk").count == 1
    assert group(board, "Broker").count == 3
    assert group(board, "Dispatcher").count == 2
    assert length(group(board, "Broker").rows) == 3
    # Non-vacuity: every row in the Broker bucket really has that job_title.
    assert Enum.all?(group(board, "Broker").rows, &(&1.job_title == "Broker"))
    assert board.group_field == :job_title
  end

  test "GROUPING: discovered columns (no :groups) → the distinct keys, bounded" do
    mount = build_mount(:crm)
    {_org, scope} = seed_org(mount, %{"Broker" => 2, "Dispatcher" => 1, "Clerk" => 1})

    board = Reads.group_by!(Mount.resource(mount, Person), :job_title, scope: scope)

    # Discovery yields the distinct keys (asc); each carries its own rows.
    assert group_keys(board) == ["Broker", "Clerk", "Dispatcher"]
    assert group(board, "Broker").count == 2
  end

  # -- ORG-SCOPE (sabotage-refutable) ------------------------------------------

  test "ORG-SCOPE: org B rows NEVER appear in org A's groups" do
    mount = build_mount(:crm)
    {org_a, scope_a} = seed_org(mount, %{"Broker" => 2})
    {org_b, scope_b} = seed_org(mount, %{"Broker" => 5})

    # Refutation setup: org B genuinely holds SAME-KEY ("Broker") rows — 5 of them.
    b_ids =
      @person
      |> Ash.Query.filter(org_id == ^org_b)
      |> Ash.read!(scope: scope_b)
      |> MapSet.new(& &1.id)

    assert MapSet.size(b_ids) == 5

    board =
      Mount.resource(mount, Person)
      |> Ash.Query.ensure_selected([:org_id, :job_title])
      |> Reads.group_by!(:job_title, scope: scope_a)

    broker = group(board, "Broker")

    # OrgScope narrows every column: only org A's 2 Brokers, none of org B's 5.
    assert broker.count == 2
    assert length(broker.rows) == 2
    assert Enum.all?(broker.rows, &(&1.org_id == org_a))
    assert MapSet.disjoint?(MapSet.new(broker.rows, & &1.id), b_ids)
  end

  test "ORG-SCOPE: NO caller opt disables scoping — authorize?: false is inert" do
    mount = build_mount(:crm)
    {org_a, scope_a} = seed_org(mount, %{"Broker" => 2})
    {org_b, scope_b} = seed_org(mount, %{"Broker" => 5})

    # Refutation setup: org B genuinely holds 5 same-key ("Broker") rows. Under the OLD
    # (defective) contract, authorize?: false dropped OrgScope and returned all 7 (2+5)
    # rows AND a count of 7 — a cross-org row + cardinality leak. There is now NO opt that
    # can do this: authorize?: false is ignored, org-scope is unconditional.
    b_ids =
      @person
      |> Ash.Query.filter(org_id == ^org_b)
      |> Ash.read!(scope: scope_b)
      |> MapSet.new(& &1.id)

    assert MapSet.size(b_ids) == 5

    # Pass EVERY boundary-relevant opt a caller could try, including the removed escape hatch.
    for opts <- [
          [scope: scope_a, authorize?: false],
          [scope: scope_a, authorize?: false, groups: ["Broker"]],
          [scope: scope_a, authorize?: false, count?: true, per_group_limit: 999]
        ] do
      board =
        Mount.resource(mount, Person)
        |> Ash.Query.ensure_selected([:org_id, :job_title])
        |> Reads.group_by!(:job_title, opts)

      broker = group(board, "Broker")
      # Org boundary HOLDS regardless of opts: org A's 2 only, count 2, no org-B ids/count.
      assert broker.count == 2, "authorize?: false must NOT leak cross-org count (got #{broker.count})"
      assert length(broker.rows) == 2
      assert Enum.all?(broker.rows, &(&1.org_id == org_a))
      assert MapSet.disjoint?(MapSet.new(broker.rows, & &1.id), b_ids)
    end
  end

  # -- BOUNDING ----------------------------------------------------------------

  test "BOUNDING: a hot column returns the cap + has_more + exact count, not the whole set" do
    mount = build_mount(:crm)
    # 7 in a hot column, 2 in a cold one; cap the column at 3.
    {_org, scope} = seed_org(mount, %{"Broker" => 7, "Clerk" => 2})

    board =
      Mount.resource(mount, Person)
      |> Reads.group_by!(:job_title, scope: scope, per_group_limit: 3)

    hot = group(board, "Broker")
    # Bounded: at most `cap` rows returned, NOT all 7 — the read did not leak the full set.
    assert length(hot.rows) == 3
    assert hot.has_more == true
    # But the exact total is still known (aggregate count — no row transfer): the "+N more".
    assert hot.count == 7
    assert board.per_group_limit == 3

    # Positive control: an UNDER-cap column returns everything, has_more false.
    cold = group(board, "Clerk")
    assert length(cold.rows) == 2
    assert cold.has_more == false
    assert cold.count == 2
  end

  # -- MASKING (INV-1) ---------------------------------------------------------

  test "MASKING: grouping a VAULT-ROUTED field is REFUSED; a non-vaulted field groups fine" do
    mount = build_mount(:crm)
    {_org, scope} = seed_org(mount, %{"Broker" => 2})

    # Refutation anchors: full_name IS vaulted, job_title is NOT — so the refusal below
    # is a real guard, not a no-op that would reject everything.
    assert Samen.Pii.Info.vault_routed?(@person, :full_name)
    refute Samen.Pii.Info.vault_routed?(@person, :job_title)

    # RED: grouping by the 🔒 field raises — never a plaintext/token bucket.
    err =
      assert_raise MaskedGroupKeyError, fn ->
        Reads.group_by!(Mount.resource(mount, Person), :full_name, scope: scope)
      end

    assert err.message =~ "vault-routed"
    refute err.message =~ "Broker-1"

    # GREEN control: the non-vaulted twin groups without raising (anti-tautology).
    board = Reads.group_by!(Mount.resource(mount, Person), :job_title, scope: scope)
    assert group(board, "Broker").count == 2
  end
end
