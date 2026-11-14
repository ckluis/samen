defmodule Samen.Policy.OrgScopeTest do
  @moduledoc """
  ARCH-26 (ADR-049 watch-list): `Samen.Policy.OrgScope` is the org-scoping of EVERY tenant-plane read. Its two
  filters are the whole decision:

    * `filter/3` — `org_id == actor.org_id`; an actor with no org sees NOTHING (`false`, fail closed)
    * `reject/3` — the negation, with the NULL-org row INCLUDED (postgres `!=` is NULL for NULL); an org-less actor
      is rejected from EVERYTHING (`true`)

  Both are exercised as expressions evaluated per row (positive control = the actor's own row; the red side = a
  foreign row, a NULL-org row, an org-less actor, a non-map actor) AND end to end through a real Ash read.
  """
  use ExUnit.Case, async: false

  alias Samen.Policy.OrgScope

  @org Ash.UUID.generate()
  @other Ash.UUID.generate()

  setup do
    Samen.TestSandbox.shared!(SamenCore.TestRepo)
    :ok
  end

  defp matches?(expr, org_id) do
    case Ash.Expr.eval(expr, record: %{org_id: org_id}) do
      {:ok, v} -> v
      other -> flunk("expression did not evaluate: #{inspect(other)}")
    end
  end

  describe "filter/3 — which rows the actor MAY see" do
    test "an actor sees its own org's rows and no other org's, nor NULL-org rows" do
      expr = OrgScope.filter(%{org_id: @org}, nil, [])

      assert matches?(expr, @org) == true
      assert matches?(expr, @other) == false
      refute matches?(expr, nil) == true
    end

    test "an actor with no org sees NOTHING (fail closed), not everything" do
      for actor <- [%{org_id: nil}, %{}, nil, "not-a-map", :anon] do
        expr = OrgScope.filter(actor, nil, [])
        assert expr == false or matches?(expr, @org) == false, "actor #{inspect(actor)} must see no rows"
        refute matches?(expr, @org) == true
        refute matches?(expr, nil) == true
      end
    end
  end

  describe "reject/3 — which rows the actor may NOT touch" do
    test "a foreign-org row AND a NULL-org row are rejected; the actor's own row is not" do
      expr = OrgScope.reject(%{org_id: @org}, nil, [])

      assert matches?(expr, @org) == false
      assert matches?(expr, @other) == true
      assert matches?(expr, nil) == true
    end

    test "an actor with no org is rejected from EVERY row" do
      for actor <- [%{org_id: nil}, %{}, nil, "not-a-map"] do
        expr = OrgScope.reject(actor, nil, [])
        assert expr == true or matches?(expr, @org) == true, "actor #{inspect(actor)} must be rejected from all rows"
        assert matches?(expr, @org) == true
        assert matches?(expr, nil) == true
      end
    end

    test "filter and reject are exact complements for an org-bearing actor" do
      actor = %{org_id: @org}
      f = OrgScope.filter(actor, nil, [])
      r = OrgScope.reject(actor, nil, [])

      for row_org <- [@org, @other, nil] do
        assert matches?(f, row_org) == true != (matches?(r, row_org) == true)
      end
    end
  end

  describe "end to end through a real Ash read" do
    test "own org reads its row; a foreign org and an org-less actor read nothing" do
      act =
        Core.Ctx.Activity
        |> Ash.Changeset.for_create(:create, %{org_id: @org, kind: :visit}, authorize?: false)
        |> Ash.create!()

      read = fn actor -> Ash.read!(Core.Ctx.Activity, actor: actor) |> Enum.map(& &1.id) end

      assert act.id in read.(%{id: "u1", org_id: @org, role: :owner})
      refute act.id in read.(%{id: "u2", org_id: @other, role: :owner})
      assert read.(%{id: "u3", org_id: nil, role: :owner}) == []
    end
  end
end
