defmodule Samen.SameOrgFkChangeTest do
  @moduledoc """
  RUNTIME behaviour of the `Samen.Policy.SameOrgFk` change (as opposed to the
  structural verifier, which `same_org_fk_verifier_test.exs` covers).

  D2 / ADR-046 §4.6 — the org-less-TARGET arm must **pass**, not refuse. A
  `belongs_to` whose destination table carries no `org_id` (an org-less anchor like
  `Identity.Org`, or a shared cross-org Credential) has no org to mismatch against,
  so the same-org check has nothing to enforce. Before the fix that arm returned
  `{:error, :target_has_no_org_id}`, which `validate_relationship/3` routed into
  `add_error` — refusing every create on a resource with such an FK, contradicting
  both this module's own inline comment and the verifier's moduledoc.

  Anti-tautology (the load-bearing pair): the **genuine cross-org guard is
  untouched** — an FK pointing at an org-scoped target owned by a DIFFERENT org is
  still refused (proven against the real `cpy_company` table). So "org-less passes"
  is a real relaxation of an inapplicable check, never a hole in the actual guard.

  The change wraps its work in a `before_action` hook; we exercise it exactly as an
  action would — `run_before_actions/1` — so this is the real code path, not a
  reimplementation.
  """
  use ExUnit.Case, async: false

  alias SamenCore.TestRepo, as: Repo
  alias SamenCore.Support.Crm.Company

  # ── Plain-Ash fixtures (NOT Samen.Resource → no abbrev/catalog needed) ──────
  #
  # `OrgLessTarget` — an AshPostgres resource with NO org_id (the org-less anchor).
  # Its table need not physically exist: the org-less arm returns BEFORE any query
  # (it short-circuits on `attribute_source(dest, :org_id) == nil`). The postgres
  # block only has to make `repo`/`table` introspectable (non-nil), which it is at
  # compile time regardless of whether the table was migrated.

  defmodule OrgLessTarget do
    use Ash.Resource,
      domain: Samen.SameOrgFkChangeTest.Domain,
      data_layer: AshPostgres.DataLayer

    postgres do
      table("sofk_orgless_target")
      repo(SamenCore.TestRepo)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:label, :string, public?: true)
    end

    actions do
      defaults([:read, :destroy, create: :*, update: :*])
    end
  end

  defmodule Source do
    @moduledoc "Org-scoped source with two belongs_to: an org-less target and the real org-scoped Company."
    use Ash.Resource,
      domain: Samen.SameOrgFkChangeTest.Domain,
      data_layer: AshPostgres.DataLayer

    postgres do
      table("sofk_source")
      repo(SamenCore.TestRepo)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:org_id, :uuid, public?: true, allow_nil?: true)
    end

    relationships do
      belongs_to :orgless, Samen.SameOrgFkChangeTest.OrgLessTarget do
        public?(true)
        attribute_type(:uuid)
        allow_nil?(true)
      end

      belongs_to :company, SamenCore.Support.Crm.Company do
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
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource(Samen.SameOrgFkChangeTest.OrgLessTarget)
      resource(Samen.SameOrgFkChangeTest.Source)
      resource(SamenCore.Support.Crm.Company)
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  # Build a create changeset for Source, force the org + FK, apply the SameOrgFk
  # change, and run its before_action hook — the exact path a real create takes.
  defp run_change(org_id, fk_attr, fk_value, rels) do
    cs =
      Source
      |> Ash.Changeset.for_create(:create, %{})
      |> Ash.Changeset.force_change_attributes(%{:org_id => org_id, fk_attr => fk_value})

    # Guard: the changeset MUST be valid BEFORE the hook runs, else
    # run_before_actions/1 short-circuits and would never exercise the arm under
    # test (a valid input is what makes the assertions non-vacuous).
    assert cs.valid?, "fixture changeset must be valid before the SameOrgFk hook runs"

    cs
    |> then(&Samen.Policy.SameOrgFk.change(&1, [relationships: rels], %{}))
    |> Ash.Changeset.run_before_actions()
    |> case do
      {%Ash.Changeset{} = c, _instructions} -> c
      %Ash.Changeset{} = c -> c
    end
  end

  describe "D2 — org-less-target FK PASSES (ADR-046 §4.6)" do
    test "a write whose FK targets an org-less row is NOT refused" do
      org_a = Ash.UUID.generate()

      # The org-less target row need not exist — the arm short-circuits before any
      # query, precisely because the destination table carries no org_id.
      result = run_change(org_a, :orgless_id, Ash.UUID.generate(), [:orgless])

      assert result.valid?, "an org-less-target FK must PASS, not add a cross-org error"
      assert result.errors == [], "no changeset error expected, got: #{inspect(result.errors)}"
    end
  end

  describe "CONTROL — the real cross-org guard is untouched (anti-tautology)" do
    test "an FK targeting an org-scoped row owned by a DIFFERENT org is still REFUSED" do
      org_a = Ash.UUID.generate()
      org_b = Ash.UUID.generate()

      # A real Company in org B (real cpy_company row → the guard's bare repo query
      # sees org B's org_id and refuses the org-A write).
      company_b =
        Company
        |> Ash.Changeset.for_create(:create, %{name: "org-b co", org_id: org_b})
        |> Ash.create!(authorize?: false)

      result = run_change(org_a, :company_id, company_b.id, [:company])

      refute result.valid?, "a genuine cross-org FK must STILL be refused"

      assert Enum.any?(result.errors, fn err ->
               msg = Exception.message(err)
               msg =~ "cross-org FK" and msg =~ "company"
             end),
             "expected a cross-org FK refusal naming the relationship, got: #{inspect(result.errors)}"
    end

    test "CONTROL: a same-org Company FK PASSES (proves the guard is not always-fail)" do
      org_a = Ash.UUID.generate()

      company_a =
        Company
        |> Ash.Changeset.for_create(:create, %{name: "org-a co", org_id: org_a})
        |> Ash.create!(authorize?: false)

      result = run_change(org_a, :company_id, company_a.id, [:company])

      assert result.valid?, "a same-org FK must pass"
      assert result.errors == []
    end
  end
end
