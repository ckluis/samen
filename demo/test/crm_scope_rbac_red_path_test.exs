defmodule Demo.CrmScopeRbacRedPathTest do
  @moduledoc """
  CRM scope RBAC red paths (T3.2; scope-authoring guide §9 "RBAC red paths"):

    * a member actor cannot create/modify Tier-0 pipeline stages (admin-gate);
    * an org-less actor cannot read any CRM resource (fail closed);
    * cross-org destroy is forbidden even for admins;
    * positive controls (admin CAN create/modify Tier-0 rows);
    * PII field reads are %Masked{} for any role (no vault bypass via RBAC);
    * person reveal action is default-deny (no grant = denied, any role).

  Tier-0 seed verification: confirms the pipeline stage types seeded by
  the test helper (admin-created) are org-scoped and accessible within the org.
  """
  use Demo.DataCase, async: false

  alias Demo.CrmScope.{Company, Person, Pipeline, Opportunity}
  alias Demo.Identity.{Org, User}

  # --- helpers ---------------------------------------------------------------

  defp mk_org(name) do
    {:ok, org} =
      Org |> Ash.Changeset.for_create(:create, %{name: name}) |> Ash.create(authorize?: false)

    org
  end

  defp mk_actor(org_id, role) do
    {:ok, user} =
      User
      |> Ash.Changeset.for_create(:create, %{
        handle: "rbac-#{role}-#{:rand.uniform(999_999)}",
        org_id: org_id,
        full_name: %{first: "#{role}", last: "Test"},
        emails: ["#{role}#{:rand.uniform(99_999)}@rbac.example"]
      })
      |> Ash.create(authorize?: false)

    Samen.Scope.new(%{id: user.id, org_id: org_id, role: role})
  end

  defp seed_pipeline_stages(org_id) do
    # Seed Tier-0 pipeline stages for an org (admin must be the actor).
    admin_scope = mk_actor(org_id, :admin)

    stages = [
      %{name: "Lead", stage_type: :open, stage_order: 1},
      %{name: "Qualified", stage_type: :qualified, stage_order: 2},
      %{name: "Proposal", stage_type: :proposal, stage_order: 3},
      %{name: "Closed Won", stage_type: :won, stage_order: 4},
      %{name: "Closed Lost", stage_type: :lost, stage_order: 5}
    ]

    Enum.map(stages, fn attrs ->
      {:ok, stage} =
        Pipeline
        |> Ash.Changeset.for_create(:create, Map.put(attrs, :org_id, org_id))
        |> Ash.create(actor: admin_scope.actor, authorize?: true)

      stage
    end)
  end

  # =========================================================================
  # Pipeline / Tier-0 admin gate: member cannot create/update/delete.
  # =========================================================================

  test "member actor cannot create a pipeline stage (Tier-0 admin-gate, red path)" do
    org = mk_org("rbac-pip-create")
    member_scope = mk_actor(org.id, :member)

    result =
      Pipeline
      |> Ash.Changeset.for_create(:create, %{name: "Lead", org_id: org.id, stage_order: 1})
      |> Ash.create(actor: member_scope.actor, authorize?: true)

    assert {:error, %Ash.Error.Forbidden{}} = result
  end

  test "viewer actor cannot create a pipeline stage (Tier-0 admin-gate, red path)" do
    org = mk_org("rbac-pip-viewer")
    viewer_scope = mk_actor(org.id, :viewer)

    result =
      Pipeline
      |> Ash.Changeset.for_create(:create, %{name: "Lead", org_id: org.id, stage_order: 1})
      |> Ash.create(actor: viewer_scope.actor, authorize?: true)

    assert {:error, %Ash.Error.Forbidden{}} = result
  end

  test "member actor cannot update a pipeline stage (Tier-0 admin-gate, red path)" do
    org = mk_org("rbac-pip-upd")
    admin_scope = mk_actor(org.id, :admin)
    member_scope = mk_actor(org.id, :member)

    {:ok, stage} =
      Pipeline
      |> Ash.Changeset.for_create(:create, %{name: "Lead", org_id: org.id, stage_order: 1})
      |> Ash.create(actor: admin_scope.actor, authorize?: true)

    result =
      stage
      |> Ash.Changeset.for_update(:update, %{label: "tampered"})
      |> Ash.update(actor: member_scope.actor, authorize?: true)

    assert {:error, %Ash.Error.Forbidden{}} = result
  end

  test "admin actor CAN create a pipeline stage (positive control)" do
    org = mk_org("rbac-pip-admin")
    admin_scope = mk_actor(org.id, :admin)

    assert {:ok, stage} =
             Pipeline
             |> Ash.Changeset.for_create(:create, %{
               name: "Lead",
               org_id: org.id,
               stage_order: 1,
               stage_type: :open
             })
             |> Ash.create(actor: admin_scope.actor, authorize?: true)

    assert stage.name == "Lead"
  end

  # =========================================================================
  # Tier-0 config rows seed verification.
  # =========================================================================

  test "seeded Tier-0 pipeline stages are org-scoped and admin-readable" do
    org = mk_org("rbac-tier0-seed")
    stages = seed_pipeline_stages(org.id)
    admin_scope = mk_actor(org.id, :admin)

    # All seeded stages are readable by the admin.
    query = Pipeline |> Ash.Query.select([:id, :name, :stage_type, :org_id])
    {:ok, loaded} = Ash.read(query, actor: admin_scope.actor, authorize?: true)

    assert length(loaded) == length(stages)
    assert Enum.all?(loaded, fn s -> s.org_id == org.id end)

    # Stage types are bounded enum values.
    loaded_types = Enum.map(loaded, & &1.stage_type) |> Enum.sort()
    expected_types = [:lost, :open, :proposal, :qualified, :won]
    assert loaded_types == expected_types
  end

  # =========================================================================
  # Org-less actor fail closed.
  # =========================================================================

  test "an org-less actor cannot read CRM companies (fail closed)" do
    org = mk_org("orgless-cmp")

    {:ok, _company} =
      Company
      |> Ash.Changeset.for_create(:create, %{name: "AcmeCo", org_id: org.id})
      |> Ash.create(authorize?: false)

    orgless_actor = %{id: "nobody", org_id: nil, role: :admin}

    case Ash.read(Company, actor: orgless_actor, authorize?: true) do
      {:ok, seen} -> assert seen == []
      {:error, %Ash.Error.Forbidden{}} -> assert true
    end
  end

  # =========================================================================
  # Cross-org destroy: even an admin cannot destroy a foreign org's resource.
  # =========================================================================

  test "an admin of org A cannot destroy org B's company (cross-org destroy denied)" do
    org_a = mk_org("dest-xa")
    org_b = mk_org("dest-xb")

    admin_a = mk_actor(org_a.id, :admin)

    {:ok, company_b} =
      Company
      |> Ash.Changeset.for_create(:create, %{name: "ForeignCo", org_id: org_b.id})
      |> Ash.create(authorize?: false)

    result = Ash.destroy(company_b, actor: admin_a.actor, authorize?: true)
    assert {:error, %Ash.Error.Forbidden{}} = result
  end

  # =========================================================================
  # PII is %Masked{} regardless of the actor's role.
  # =========================================================================

  test "person PII is %Masked{} even for an admin actor (no RBAC vault bypass)" do
    org = mk_org("rbac-pii-mask")
    admin_scope = mk_actor(org.id, :admin)

    {:ok, person} =
      Person
      |> Ash.Changeset.for_create(:create, %{
        org_id: org.id,
        display_name: "SecretPerson",
        full_name: %{first: "Secret", last: "Person"},
        emails: ["secret@rbac.example"],
        phones: ["+15550000001"]
      })
      |> Ash.create(authorize?: false)

    query = Person |> Ash.Query.select([:id, :full_name, :emails, :phones])
    {:ok, [loaded]} = Ash.read(query, actor: admin_scope.actor, authorize?: true)

    assert %Samen.Masked{} = loaded.full_name
    assert %Samen.Masked{} = loaded.emails
    assert %Samen.Masked{} = loaded.phones

    # No plaintext even for admin.
    refute inspect(loaded) =~ "Secret"

    _ = person
  end

  test "person reveal action is denied without a grant (default-deny, any role)" do
    org = mk_org("rbac-reveal-deny")
    admin_scope = mk_actor(org.id, :admin)

    {:ok, person} =
      Person
      |> Ash.Changeset.for_create(:create, %{
        org_id: org.id,
        display_name: "SecretReveal",
        full_name: %{first: "Secret", last: "Reveal"},
        emails: ["sr@rbac.example"]
      })
      |> Ash.create(authorize?: false)

    # The reveal action is default-deny: no grant exists, so it must fail.
    result =
      Person
      |> Ash.ActionInput.for_action(:reveal_person, %{
        actor_id: admin_scope.actor.id,
        subject_id: person.id
      })
      |> Ash.run_action(actor: admin_scope.actor, authorize?: true)

    # The action returns {:error, :denied} from run/2; Ash wraps it in an Unknown error.
    assert {:error, _} = result
    assert match?({:error, %Ash.Error.Unknown{}}, result) or match?({:error, :denied}, result)
  end

  # =========================================================================
  # Opportunity, activity: member can create/read, viewer cannot write.
  # =========================================================================

  test "a viewer cannot create an opportunity (write requires member+)" do
    org = mk_org("rbac-opp-viewer")
    viewer_scope = mk_actor(org.id, :viewer)

    result =
      Opportunity
      |> Ash.Changeset.for_create(:create, %{name: "BigDeal", org_id: org.id})
      |> Ash.create(actor: viewer_scope.actor, authorize?: true)

    assert {:error, %Ash.Error.Forbidden{}} = result
  end

  test "a member CAN create an opportunity (positive control)" do
    org = mk_org("rbac-opp-member")
    member_scope = mk_actor(org.id, :member)

    assert {:ok, opp} =
             Opportunity
             |> Ash.Changeset.for_create(:create, %{name: "BigDeal", org_id: org.id})
             |> Ash.create(actor: member_scope.actor, authorize?: true)

    assert opp.name == "BigDeal"
  end
end
