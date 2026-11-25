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

  # ── Update-path fixtures: the stored org_id read ───────────────────────────
  #
  # `UnreplicatedRepo` stands in for a read replica that has not received the row yet: it answers
  # every query with no rows. A write's security read must never go through it.
  defmodule UnreplicatedRepo do
    @moduledoc false
    def query(sql, _params) do
      send(self(), {:replica_query, sql})
      {:ok, %{rows: [], num_rows: 0}}
    end
  end

  defmodule UpdSource do
    @moduledoc "Single-PK update fixture: its READ repo is the unreplicated stand-in, its MUTATE repo is real."
    use Ash.Resource,
      domain: Samen.SameOrgFkChangeTest.Domain,
      data_layer: AshPostgres.DataLayer

    postgres do
      table("sofk_upd_source")

      repo(fn
        _resource, :read -> Samen.SameOrgFkChangeTest.UnreplicatedRepo
        _resource, _mutate -> SamenCore.TestRepo
      end)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:org_id, :uuid, public?: true, allow_nil?: true)
      attribute(:note, :string, public?: true)
    end

    relationships do
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

  defmodule CompositeSource do
    @moduledoc "Composite-PK update fixture (the stored org_id must be found by BOTH key columns)."
    use Ash.Resource,
      domain: Samen.SameOrgFkChangeTest.Domain,
      data_layer: AshPostgres.DataLayer

    postgres do
      table("sofk_composite_source")
      repo(SamenCore.TestRepo)
    end

    attributes do
      attribute(:a, :uuid, primary_key?: true, allow_nil?: false, public?: true)
      attribute(:b, :uuid, primary_key?: true, allow_nil?: false, public?: true)
      attribute(:org_id, :uuid, public?: true, allow_nil?: true)
    end

    relationships do
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
      resource(Samen.SameOrgFkChangeTest.UpdSource)
      resource(Samen.SameOrgFkChangeTest.CompositeSource)
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
  describe "the stored org_id of an UPDATE is read through the WRITE repo, only when a foreign key is written" do
    setup do
      Repo.query!("""
      CREATE TABLE sofk_upd_source (
        id uuid PRIMARY KEY, org_id uuid, note text, company_id uuid)
      """)

      Repo.query!("""
      CREATE TABLE sofk_composite_source (
        a uuid NOT NULL, b uuid NOT NULL, org_id uuid, company_id uuid, PRIMARY KEY (a, b))
      """)

      :ok
    end

    defp company!(org_id) do
      Company
      |> Ash.Changeset.for_create(:create, %{name: "co-#{org_id}", org_id: org_id})
      |> Ash.create!(authorize?: false)
    end

    defp upd_row!(org_id) do
      id = Ash.UUID.generate()
      Repo.query!("INSERT INTO sofk_upd_source (id, org_id) VALUES ($1, $2)", [Ecto.UUID.dump!(id), Ecto.UUID.dump!(org_id)])
      id
    end

    defp run_update(record, params) do
      cs = Ash.Changeset.for_update(record, :update, params)
      assert cs.valid?

      cs
      |> then(&Samen.Policy.SameOrgFk.change(&1, [], %{}))
      |> Ash.Changeset.run_before_actions()
      |> case do
        {%Ash.Changeset{} = c, _} -> c
        %Ash.Changeset{} = c -> c
      end
    end

    test "RED/GREEN: a same-org FK write passes even though the replica has no copy of the row yet" do
      org_a = Ash.UUID.generate()
      id = upd_row!(org_a)
      record = %{struct(UpdSource, id: id) | org_id: %Ash.NotLoaded{type: :attribute, field: :org_id}}

      result = run_update(record, %{company_id: company!(org_a).id})

      refute_received {:replica_query, _}, "the stored org_id must never be read through the read repo"

      assert result.valid?, "the stored org_id must come from the write repo: #{inspect(Enum.map(result.errors, &Exception.message/1))}"
    end

    test "CONTROL: a cross-org FK write on the same row is still refused (the read is real, not a pass-through)" do
      org_a = Ash.UUID.generate()
      id = upd_row!(org_a)
      record = %{struct(UpdSource, id: id) | org_id: %Ash.NotLoaded{type: :attribute, field: :org_id}}

      result = run_update(record, %{company_id: company!(Ash.UUID.generate()).id})

      refute result.valid?
      assert Enum.any?(result.errors, &(Exception.message(&1) =~ "cross-org FK"))
    end

    test "an update that writes no foreign key issues NO query for the stored org_id" do
      org_a = Ash.UUID.generate()
      id = upd_row!(org_a)
      record = %{struct(UpdSource, id: id) | org_id: %Ash.NotLoaded{type: :attribute, field: :org_id}}
      me = self()

      :telemetry.attach(
        "sofk-count-#{inspect(me)}",
        [:samen_core, :test_repo, :query],
        fn _event, _m, meta, _c -> send(me, {:query, meta.query}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("sofk-count-#{inspect(me)}") end)

      result = run_update(record, %{note: "no foreign key here"})

      assert result.valid?
      refute_received {:query, _}, "an update writing no FK must not read the stored org_id"
      refute_received {:replica_query, _}
    end

    test "a name that is not a belongs_to relationship is never 'written': no read, no refusal" do
      # No stored row exists for this id, so ANY read of the stored org_id would be refused. The
      # configured name is not a relationship at all, so nothing is being written and nothing is read.
      record = %{struct(UpdSource, id: Ash.UUID.generate()) | org_id: %Ash.NotLoaded{type: :attribute, field: :org_id}}

      cs = Ash.Changeset.for_update(record, :update, %{note: "x"})

      result =
        cs
        |> then(&Samen.Policy.SameOrgFk.change(&1, [relationships: [:not_a_relationship]], %{}))
        |> Ash.Changeset.run_before_actions()
        |> case do
          {%Ash.Changeset{} = c, _} -> c
          %Ash.Changeset{} = c -> c
        end

      assert result.valid?, inspect(Enum.map(result.errors, &Exception.message/1))
    end

    test "CONTROL: a row whose stored org_id cannot be found refuses a write that sets a foreign key" do
      record = %{struct(UpdSource, id: Ash.UUID.generate()) | org_id: %Ash.NotLoaded{type: :attribute, field: :org_id}}

      result = run_update(record, %{company_id: company!(Ash.UUID.generate()).id})

      refute result.valid?
      assert Enum.any?(result.errors, &(Exception.message(&1) =~ "could not read this record's org_id"))
    end

    test "a composite primary key is read by every key column (no refusal, no wrong row)" do
      org_a = Ash.UUID.generate()
      org_b = Ash.UUID.generate()
      {a, b} = {Ash.UUID.generate(), Ash.UUID.generate()}

      # A sibling sharing the first key column but owned by another org must never be the row that is read.
      for {x, y, o} <- [{a, b, org_a}, {a, Ash.UUID.generate(), org_b}] do
        Repo.query!("INSERT INTO sofk_composite_source (a, b, org_id) VALUES ($1, $2, $3)", [
          Ecto.UUID.dump!(x),
          Ecto.UUID.dump!(y),
          Ecto.UUID.dump!(o)
        ])
      end

      record = %{struct(CompositeSource, a: a, b: b) | org_id: %Ash.NotLoaded{type: :attribute, field: :org_id}}

      assert run_update(record, %{company_id: company!(org_a).id}).valid?

      refuted = run_update(record, %{company_id: company!(org_b).id})
      refute refuted.valid?
      assert Enum.any?(refuted.errors, &(Exception.message(&1) =~ "cross-org FK"))
    end
  end
end
