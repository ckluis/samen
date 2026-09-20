defmodule Samen.Hardening.SameOrgFkFailClosedTest do
  @moduledoc """
  Fail-closed PROOFS for the two `Samen.Policy.SameOrgFk.target_org_id/2` decisions the
  ADR-049 mutation gate found SURVIVING (ledgered ACCEPTED_GAP as MG-21/MG-22).

  | MG | construct (absolute line on `0216ce8`)                           | mutation     |
  |----|------------------------------------------------------------------|--------------|
  | 21 | line 174 `Info.repo(dest, :read) || Info.repo(dest)`             | `||` → `&&`  |
  | 22 | line 181 `is_nil(repo) or is_nil(table)`                         | `or` → `and` |

  Both are about the guard's own PLUMBING, and both are invisible to every shipped resource:
  in `samen_core` every `postgres do repo … end` is a static module, so `repo(dest, :read)`
  and `repo(dest)` return the SAME value and the fallback ORDER cannot be observed; and no
  shipped resource has a table without a repo, so the `or` never has to be an `or`. The
  destinations below are therefore purpose-built fixtures (the `same_org_fk_change_test.exs`
  `OrgLessTarget` precedent) that make each decision observable:

    * `ReadRepoTarget` declares a FUNCTION repo (`{:fun, 2}` — AshPostgres's own documented
      shape) that resolves for `:read` and NOT for `:mutate`, so a guard reading the mutate
      repo instead of the read repo sees nothing.
    * `NoRepoTarget` declares a function repo that never resolves while keeping a real
      `table`, so exactly ONE of `repo`/`table` is nil — the case `or` covers and `and` does
      not.

  Both point at the REAL `cpy_company` table, so the org lookups below are genuine queries
  against genuine rows, not stubs. Neither fixture is ever written through (the guard's
  `before_action` is run directly, the `same_org_fk_change_test.exs` technique), so no
  migration is needed for them.

  Verified RED-FIRST by hand, one mutation at a time: the named test fails under the mutant
  and passes again on the byte-exact restored source.
  """
  use ExUnit.Case, async: false

  alias SamenCore.Support.Crm.Company
  alias SamenCore.TestRepo, as: Repo

  defmodule ReadRepoTarget do
    @moduledoc false
    use Ash.Resource,
      domain: Samen.Hardening.SameOrgFkFailClosedTest.Domain,
      data_layer: AshPostgres.DataLayer

    postgres do
      table("cpy_company")

      repo(fn
        _resource, :read -> SamenCore.TestRepo
        _resource, _other -> nil
      end)
    end

    attributes do
      attribute(:id, :uuid, primary_key?: true, allow_nil?: false, public?: true, source: :cpy_id)
      attribute(:org_id, :uuid, public?: true, source: :cpy_org_id)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule NoRepoTarget do
    @moduledoc false
    use Ash.Resource,
      domain: Samen.Hardening.SameOrgFkFailClosedTest.Domain,
      data_layer: AshPostgres.DataLayer

    postgres do
      table("cpy_company")
      repo(fn _resource, _type -> nil end)
    end

    attributes do
      attribute(:id, :uuid, primary_key?: true, allow_nil?: false, public?: true, source: :cpy_id)
      attribute(:org_id, :uuid, public?: true, source: :cpy_org_id)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule Source do
    @moduledoc false
    use Ash.Resource,
      domain: Samen.Hardening.SameOrgFkFailClosedTest.Domain,
      data_layer: AshPostgres.DataLayer

    postgres do
      table("sofk_hardening_source")
      repo(SamenCore.TestRepo)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:org_id, :uuid, public?: true, allow_nil?: true)
    end

    relationships do
      belongs_to :read_repo_target, Samen.Hardening.SameOrgFkFailClosedTest.ReadRepoTarget do
        public?(true)
        attribute_type(:uuid)
        allow_nil?(true)
      end

      belongs_to :no_repo_target, Samen.Hardening.SameOrgFkFailClosedTest.NoRepoTarget do
        public?(true)
        attribute_type(:uuid)
        allow_nil?(true)
      end
    end

    actions do
      defaults([:read, :destroy, create: :*, update: :*])
    end
  end

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource(Samen.Hardening.SameOrgFkFailClosedTest.ReadRepoTarget)
      resource(Samen.Hardening.SameOrgFkFailClosedTest.NoRepoTarget)
      resource(Samen.Hardening.SameOrgFkFailClosedTest.Source)
      resource(SamenCore.Support.Crm.Company)
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  defp company!(org_id) do
    Company
    |> Ash.Changeset.for_create(:create, %{name: "co-#{org_id}", org_id: org_id})
    |> Ash.create!(authorize?: false)
  end

  # Apply the change and run its before_action hook — the exact path a real create takes.
  defp run_change(org_id, fk_attr, fk_value, rels) do
    cs =
      Source
      |> Ash.Changeset.for_create(:create, %{})
      |> Ash.Changeset.force_change_attributes(%{:org_id => org_id, fk_attr => fk_value})

    # A valid input is what makes the assertions non-vacuous: an already-invalid changeset
    # would short-circuit `run_before_actions/1` and never reach the arm under test.
    assert cs.valid?, "fixture changeset must be valid before the SameOrgFk hook runs"

    cs
    |> then(&Samen.Policy.SameOrgFk.change(&1, [relationships: rels], %{}))
    |> Ash.Changeset.run_before_actions()
    |> case do
      {%Ash.Changeset{} = c, _instructions} -> c
      %Ash.Changeset{} = c -> c
    end
  end

  defp error_messages(changeset), do: Enum.map(changeset.errors, &Exception.message/1)

  describe "MG-21 — the READ repo is tried FIRST, the default repo is the fallback (line 174)" do
    test "MG-21: a same-org FK PASSES against a target whose repo resolves only for :read" do
      org_a = Ash.UUID.generate()
      company = company!(org_a)

      # Positive controls for the fixture itself — without these the proof would be vacuous.
      assert AshPostgres.DataLayer.Info.repo(ReadRepoTarget, :read) == Repo
      assert AshPostgres.DataLayer.Info.repo(ReadRepoTarget, :mutate) == nil

      # `read_repo || default_repo` → `read_repo && default_repo` yields nil here, so the
      # mutant bails out with `{:error, :no_data_layer}` and REFUSES a legitimate same-org
      # write (a guard that cannot read its target must fail closed — so the mutation turns
      # every such write into a refusal).
      result = run_change(org_a, :read_repo_target_id, company.id, [:read_repo_target])

      assert result.valid?,
             "a same-org FK must PASS via the read repo, got: #{inspect(error_messages(result))}"

      assert result.errors == []
    end

    test "CONTROL (anti-tautology): a CROSS-org FK on the same target is still REFUSED" do
      org_a = Ash.UUID.generate()
      org_b = Ash.UUID.generate()
      company_b = company!(org_b)

      result = run_change(org_a, :read_repo_target_id, company_b.id, [:read_repo_target])

      refute result.valid?, "a genuine cross-org FK must STILL be refused"

      assert Enum.any?(error_messages(result), fn msg ->
               msg =~ "cross-org FK" and msg =~ "read_repo_target"
             end),
             "expected a cross-org refusal naming the relationship, got: #{inspect(error_messages(result))}"
    end
  end

  describe "MG-22 — the :no_data_layer bail-out needs EITHER repo OR table missing (line 181)" do
    test "MG-22: a target with a table but NO resolvable repo fails CLOSED with :no_data_layer" do
      org_a = Ash.UUID.generate()

      # Positive controls: exactly ONE of the pair is nil. `or` → `and` makes the bail-out
      # demand BOTH, so the mutant falls through to the query arm and calls `query/2` on
      # `nil` instead of refusing the write.
      assert AshPostgres.DataLayer.Info.repo(NoRepoTarget, :read) == nil
      assert AshPostgres.DataLayer.Info.repo(NoRepoTarget, :mutate) == nil
      assert AshPostgres.DataLayer.Info.table(NoRepoTarget) == "cpy_company"

      result = run_change(org_a, :no_repo_target_id, Ash.UUID.generate(), [:no_repo_target])

      refute result.valid?, "an unverifiable target must FAIL CLOSED, not pass"

      assert Enum.any?(error_messages(result), fn msg ->
               msg =~ "could not verify no_repo_target" and msg =~ "no_data_layer"
             end),
             "expected the :no_data_layer fail-closed refusal, got: #{inspect(error_messages(result))}"
    end
  end
end
