defmodule Samen.Policy.OrgScopeTest do
  @moduledoc """
  ARCH-26 (ADR-049 watch-list): `Samen.Policy.OrgScope` is the org-scoping of EVERY tenant-plane read. Its two
  filters are the whole decision:

    * `filter/3` — `org_id == actor.org_id`; an actor with no org sees NOTHING (`false`, fail closed)
    * `reject/3` — the negation, with the NULL-org row INCLUDED (postgres `!=` is NULL for NULL); an org-less actor
      is rejected from EVERYTHING (`true`)

  Each filter is pinned structurally AND applied to real rows (positive control = the actor's own row; the red
  side = a foreign row, an org-less actor, a non-map actor), then exercised end to end through a real Ash read.
  """
  use ExUnit.Case, async: false

  alias Samen.Policy.OrgScope

  @org Ash.UUID.generate()
  @other Ash.UUID.generate()

  setup do
    Samen.TestSandbox.shared!(SamenCore.TestRepo)
    :ok
  end

  require Ash.Expr
  require Ash.Query

  # The expression a FilterCheck returns, applied as a real filter to real rows: the ids it keeps.
  defp kept(expr, ids) do
    Core.Ctx.Activity
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.filter(^expr)
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.id)
    |> Enum.sort()
  end

  defp activity!(org_id) do
    Core.Ctx.Activity
    |> Ash.Changeset.for_create(:create, %{org_id: org_id, kind: :visit}, authorize?: false)
    |> Ash.create!()
  end

  # The fixture column is NOT NULL, so no NULL-org row can exist by default. Relax it INSIDE the sandbox transaction
  # (postgres DDL is transactional; this module is async: false) and insert a genuine NULL-org row, then read it back
  # through Ash exactly like any other row.
  defp orphan_activity! do
    SamenCore.TestRepo.query!("ALTER TABLE cea_activity ALTER COLUMN cea_org_id DROP NOT NULL")

    %{rows: [[id]]} =
      SamenCore.TestRepo.query!(
        "INSERT INTO cea_activity (cea_kind, cea_org_id, cea_inserted_at, cea_updated_at) " <>
          "VALUES ('visit', NULL, now(), now()) RETURNING cea_id"
      )

    %{id: Ecto.UUID.load!(id)}
  end

  describe "filter/3 — which rows the actor MAY see" do
    test "an org-bearing actor keeps ITS org's rows and no other org's" do
      mine = activity!(@org)
      theirs = activity!(@other)
      ids = Enum.sort([mine.id, theirs.id])

      assert kept(OrgScope.filter(%{org_id: @org}, nil, []), ids) == [mine.id]
      assert kept(OrgScope.filter(%{org_id: @other}, nil, []), ids) == [theirs.id]
      assert OrgScope.filter(%{org_id: @org}, nil, []) == Ash.Expr.expr(org_id == ^@org)
    end

    test "an actor with no org sees NOTHING (fail closed), not everything" do
      mine = activity!(@org)

      for actor <- [%{org_id: nil}, %{}, nil, "not-a-map", :anon] do
        assert kept(OrgScope.filter(actor, nil, []), [mine.id]) == [], "actor #{inspect(actor)} must see no rows"
        assert OrgScope.filter(actor, nil, []) == false
      end
    end
  end

  describe "reject/3 — which rows the actor may NOT touch" do
    test "a foreign-org row is rejected and the actor's own row is not" do
      mine = activity!(@org)
      theirs = activity!(@other)
      ids = Enum.sort([mine.id, theirs.id])

      assert kept(OrgScope.reject(%{org_id: @org}, nil, []), ids) == [theirs.id]
      assert OrgScope.reject(%{org_id: @org}, nil, []) == Ash.Expr.expr(org_id != ^@org or is_nil(org_id))
    end

    test "a NULL-org row is returned to NO org's actor by filter/3 and rejected for EVERY actor by reject/3" do
      mine = activity!(@org)
      theirs = activity!(@other)
      orphan = orphan_activity!()
      ids = Enum.sort([mine.id, theirs.id, orphan.id])

      # The row really has no org (guards the setup: otherwise this proves nothing).
      assert %{rows: [[nil]]} =
               SamenCore.TestRepo.query!("SELECT cea_org_id FROM cea_activity WHERE cea_id = $1", [Ecto.UUID.dump!(orphan.id)])

      for {org, own} <- [{@org, mine.id}, {@other, theirs.id}] do
        actor = %{org_id: org}
        # positive control: the actor's own row IS visible and NOT rejected ...
        assert own in kept(OrgScope.filter(actor, nil, []), ids)
        refute own in kept(OrgScope.reject(actor, nil, []), ids)
        # ... while the NULL-org row is never visible, and is rejected (postgres `!=` alone would give NULL).
        refute orphan.id in kept(OrgScope.filter(actor, nil, []), ids)
        assert orphan.id in kept(OrgScope.reject(actor, nil, []), ids)
      end
    end

    test "an actor with no org is rejected from EVERY row" do
      mine = activity!(@org)

      for actor <- [%{org_id: nil}, %{}, nil, "not-a-map"] do
        assert kept(OrgScope.reject(actor, nil, []), [mine.id]) == [mine.id], "actor #{inspect(actor)} rejected from all"
        assert OrgScope.reject(actor, nil, []) == true
      end
    end

    test "filter and reject partition the rows for an org-bearing actor" do
      mine = activity!(@org)
      theirs = activity!(@other)
      ids = Enum.sort([mine.id, theirs.id])
      actor = %{org_id: @org}

      assert Enum.sort(kept(OrgScope.filter(actor, nil, []), ids) ++ kept(OrgScope.reject(actor, nil, []), ids)) == ids
    end
  end

  describe "end to end through a real Ash read" do
    test "own org reads its row; a foreign org reads nothing and an org-less actor is forbidden" do
      act =
        Core.Ctx.Activity
        |> Ash.Changeset.for_create(:create, %{org_id: @org, kind: :visit}, authorize?: false)
        |> Ash.create!()

      read = fn actor -> Ash.read!(Core.Ctx.Activity, actor: actor) |> Enum.map(& &1.id) end

      assert act.id in read.(%{id: "u1", org_id: @org, role: :owner})
      refute act.id in read.(%{id: "u2", org_id: @other, role: :owner})
      # No org → the filter is `false`: Ash refuses the read outright, it never returns a tenant row.
      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.read(Core.Ctx.Activity, actor: %{id: "u3", org_id: nil, role: :owner})
    end
  end
end
