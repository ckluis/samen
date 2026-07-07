defmodule Samen.ContextRedPathTest do
  @moduledoc """
  T3.10 RED PATHS (must-fail tests) for `Samen.Context`.

  Three guarantees, each with a red path + an anti-tautology control:

    1. **An alias cannot widen policies** — an aliased read is still org-scoped;
       a foreign-org actor gets zero rows through the alias, exactly as it would
       against the kernel resource. The alias offers NO policy-widening surface
       (it is not a second Ash resource). Control: same-org actor DOES see the row.

    2. **A reshape cannot touch storage** — a reshape calc that collides with a
       physical column, or whose `expr` references a raw abbrev-prefixed storage
       column, fails the context's COMPILE (a `Spark.Error.DslError`). Control:
       the same reshape against LOGICAL fields compiles cleanly.

    3. **Calculations must be correct** — a deliberately-wrong reshape expression
       fails the worked-example assertion (proving the assertion is a real
       discriminator, not a tautology that would pass on any expression).
  """
  use ExUnit.Case, async: false

  require Ash.Query

  alias SamenCore.TestRepo, as: Repo
  alias Samen.Context

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  defp purge(mod) do
    :code.purge(mod)
    :code.delete(mod)
  end

  # ==========================================================================
  # RED PATH 1 — an alias cannot widen policies (org-scope rides underneath)
  # ==========================================================================

  describe "RED PATH: an alias cannot widen policies" do
    test "an aliased read from a FOREIGN org returns zero rows (org-scope holds)" do
      owner_org = Ash.UUID.generate()
      attacker_org = Ash.UUID.generate()

      act =
        Core.Ctx.Activity
        |> Ash.Changeset.for_create(:create, %{org_id: owner_org, kind: :visit}, authorize?: false)
        |> Ash.create!()

      # Read THROUGH the vertical's alias as an actor from a different org.
      results =
        Ctx.Toy
        |> Context.query(Ctx.Toy.Encounter)
        |> Ash.Query.filter(id == ^act.id)
        |> Ash.read!(actor: %{id: "attacker", org_id: attacker_org, role: :owner})

      # MUST be empty — the alias routes to the kernel resource, whose OrgScope
      # FilterCheck makes the foreign row invisible. An :owner role does not widen it.
      assert results == []
    end

    test "control (anti-tautology): the OWNER org DOES see the row through the alias" do
      owner_org = Ash.UUID.generate()

      act =
        Core.Ctx.Activity
        |> Ash.Changeset.for_create(:create, %{org_id: owner_org, kind: :visit}, authorize?: false)
        |> Ash.create!()

      [seen] =
        Ctx.Toy
        |> Context.query(Ctx.Toy.Encounter)
        |> Ash.Query.filter(id == ^act.id)
        |> Ash.read!(actor: %{id: "owner", org_id: owner_org, role: :viewer})

      # Proves RED PATH 1 fails because of the ORG mismatch, not because the alias
      # is broken for everyone. Even a lowly :viewer of the OWNING org sees it.
      assert seen.id == act.id
    end
  end

  # ==========================================================================
  # RED PATH 2 — a reshape cannot touch storage (compile-time)
  # ==========================================================================

  @collide_name """
  defmodule Samen.ContextRedPath.CollideCtx do
    use Samen.Context

    context do
      domain Core.Ctx

      # `total` is a PHYSICAL column of Core.Ctx.Invoice — a reshape may only ADD a
      # derived field, never redefine/shadow a stored column.
      reshape Core.Ctx.Invoice do
        calculate :total, :money, expr(total - covered_amount)
      end
    end
  end
  """

  @collide_storage_name """
  defmodule Samen.ContextRedPath.CollideStorageCtx do
    use Samen.Context

    context do
      domain Core.Ctx

      # `cei_total` is the ABBREV-PREFIXED storage source of Core.Ctx.Invoice's
      # `total` — naming a derived field after the physical column is touching storage.
      reshape Core.Ctx.Invoice do
        calculate :cei_total, :money, expr(total - covered_amount)
      end
    end
  end
  """

  @storage_ref_expr """
  defmodule Samen.ContextRedPath.StorageRefCtx do
    use Samen.Context

    context do
      domain Core.Ctx

      # The expr references the RAW STORAGE column name `cei_total` instead of the
      # logical `total` — reaching into the physical storage layer is refused.
      reshape Core.Ctx.Invoice do
        calculate :split, :money, expr(cei_total - covered_amount)
      end
    end
  end
  """

  @good_reshape """
  defmodule Samen.ContextRedPath.GoodCtx do
    use Samen.Context

    context do
      domain Core.Ctx

      reshape Core.Ctx.Invoice do
        calculate :split, :money, expr(total - covered_amount)
      end
    end
  end
  """

  test "RED PATH: a reshape calc that collides with a physical column fails compile" do
    purge(Samen.ContextRedPath.CollideCtx)

    err = assert_raise Spark.Error.DslError, fn -> Code.compile_string(@collide_name) end
    msg = Exception.message(err)
    assert msg =~ "collides with a physical column"
    assert msg =~ ~r/cannot touch storage/i
  after
    purge(Samen.ContextRedPath.CollideCtx)
  end

  test "RED PATH: a reshape calc named after the abbrev-prefixed storage source fails compile" do
    purge(Samen.ContextRedPath.CollideStorageCtx)

    err =
      assert_raise Spark.Error.DslError, fn -> Code.compile_string(@collide_storage_name) end

    assert Exception.message(err) =~ "collides with a physical column"
  after
    purge(Samen.ContextRedPath.CollideStorageCtx)
  end

  test "RED PATH: a reshape expr referencing a raw storage column name fails compile" do
    purge(Samen.ContextRedPath.StorageRefCtx)

    err = assert_raise Spark.Error.DslError, fn -> Code.compile_string(@storage_ref_expr) end
    msg = Exception.message(err)
    assert msg =~ "references raw"
    assert msg =~ "cei_total"
    assert msg =~ ~r/touching storage/i
  after
    purge(Samen.ContextRedPath.StorageRefCtx)
  end

  test "control (anti-tautology): the SAME reshape over LOGICAL fields compiles cleanly" do
    # Proves the red paths fail because of the storage violation, not because a
    # reshape/calculate is broken in general.
    purge(Samen.ContextRedPath.GoodCtx)

    modules = Code.compile_string(@good_reshape)
    assert Enum.any?(modules, fn {m, _} -> m == Samen.ContextRedPath.GoodCtx end)

    [%{calculations: [calc]}] = Samen.Context.Info.reshapes(Samen.ContextRedPath.GoodCtx)
    assert calc.name == :split
  after
    purge(Samen.ContextRedPath.GoodCtx)
  end

  # ==========================================================================
  # RED PATH 3 — calculations must be correct (the assertion is a discriminator)
  # ==========================================================================

  describe "RED PATH: the worked-example assertion is a real discriminator" do
    test "a WRONG money split does NOT reconstitute the gross total" do
      org = Ash.UUID.generate()

      inv =
        Core.Ctx.Invoice
        |> Ash.Changeset.for_create(
          :create,
          %{org_id: org, total: Decimal.new("100.00"), covered_amount: Decimal.new("70.00")},
          authorize?: false
        )
        |> Ash.create!()

      # A DELIBERATELY WRONG reshape: payer_claim = total (not covered_amount).
      # If the calc engine were a tautology (returned anything / ignored the expr),
      # this test could not distinguish it. It CAN: the wrong split over-counts.
      q =
        Core.Ctx.Invoice
        |> Ash.Query.new()
        |> Ash.Query.calculate(:responsibility, :decimal, Ash.Expr.expr(total - covered_amount))
        |> Ash.Query.calculate(:wrong_claim, :decimal, Ash.Expr.expr(total))
        |> Ash.Query.filter(id == ^inv.id)

      [rec] = Ash.read!(q, actor: %{id: "u1", org_id: org, role: :admin})

      wrong_sum =
        Decimal.add(rec.calculations.responsibility, rec.calculations.wrong_claim)

      # The correct invariant is responsibility + claim == total (100.00). The WRONG
      # split yields 30.00 + 100.00 = 130.00 — the red path: it must NOT equal 100.
      refute Decimal.equal?(wrong_sum, Decimal.new("100.00"))
      assert Decimal.equal?(wrong_sum, Decimal.new("130.00"))
    end
  end
end
