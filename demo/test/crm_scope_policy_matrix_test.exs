defmodule Demo.CrmScopePolicyMatrixTest do
  @moduledoc """
  The CRM scope org-scope + RBAC policy matrix (T3.2). Exercises the REAL
  mounted CRM resources against the REAL Postgres, through the REAL Ash policy
  authorizer.

  Covers:
    * cross-org read denied (org-scope FilterCheck) — a property test over many
      org pairs (the `cross-org read denied` red path);
    * cross-org write denied;
    * PII masked-by-default on the tenant-plane read (person🔒);
    * the positive cases (an actor sees + writes its OWN org's rows);
    * pipeline stage (Tier-0 config row) org-scope + admin-gate.
  """
  use Demo.DataCase, async: false
  use ExUnitProperties

  # Activity removed (ADR-041 §5, ruling M5) — migrated into the canonical Work-scope
  # Task (`Demo.WorkScope.Task`); the cross-org red paths below move to the Task anchor.
  alias Demo.CrmScope.{Company, Person, Pipeline, Opportunity, Attachment}
  alias Demo.WorkScope.Task
  alias Demo.Identity.{Org, User}

  # --- helpers ---------------------------------------------------------------

  defp mk_org(name) do
    {:ok, org} =
      Org
      |> Ash.Changeset.for_create(:create, %{name: name})
      |> Ash.create(authorize?: false)

    org
  end

  defp mk_actor(org_id, role \\ :member) do
    {:ok, user} =
      User
      |> Ash.Changeset.for_create(:create, %{
        handle: "actor-#{:rand.uniform(999_999)}",
        org_id: org_id,
        full_name: %{first: "Test", last: "Actor"},
        emails: ["actor#{:rand.uniform(999_999)}@example.com"]
      })
      |> Ash.create(authorize?: false)

    Samen.Scope.new(%{id: user.id, org_id: org_id, role: role})
  end

  defp mk_company(org_id, name) do
    {:ok, c} =
      Company
      |> Ash.Changeset.for_create(:create, %{name: name, org_id: org_id})
      |> Ash.create(authorize?: false)

    c
  end

  defp mk_person(org_id, display_name) do
    {:ok, p} =
      Person
      |> Ash.Changeset.for_create(:create, %{
        org_id: org_id,
        display_name: display_name,
        full_name: %{first: display_name, last: "Lastname"},
        emails: ["#{String.downcase(display_name)}@example.com"],
        phones: ["+15551234567"]
      })
      |> Ash.create(authorize?: false)

    p
  end

  defp mk_pipeline_stage(org_id, name, stage_type \\ :open) do
    {:ok, p} =
      Pipeline
      |> Ash.Changeset.for_create(:create, %{
        name: name,
        org_id: org_id,
        stage_type: stage_type,
        stage_order: 1
      })
      |> Ash.create(authorize?: false)

    p
  end

  # =========================================================================
  # Cross-org read denial — the org-scope FilterCheck. PROPERTY test.
  # =========================================================================

  property "an actor scoped to org A never reads another org's companies (cross-org read denied)" do
    check all(
            name_a <- string(:alphanumeric, min_length: 1, max_length: 8),
            name_b <- string(:alphanumeric, min_length: 1, max_length: 8),
            max_runs: 20
          ) do
      org_a = mk_org("crm-A-" <> name_a)
      org_b = mk_org("crm-B-" <> name_b)

      scope_a = mk_actor(org_a.id)
      mk_company(org_b.id, "CompanyB")

      query = Company |> Ash.Query.select([:id, :org_id])
      {:ok, seen} = Ash.read(query, actor: scope_a.actor, authorize?: true)
      seen_orgs = seen |> Enum.map(& &1.org_id) |> Enum.uniq()

      # Org B's company is invisible (filtered, not just forbidden).
      refute org_b.id in seen_orgs
    end
  end

  property "an actor scoped to org A never reads another org's persons (person🔒 cross-org)" do
    check all(
            name_a <- string(:alphanumeric, min_length: 1, max_length: 6),
            name_b <- string(:alphanumeric, min_length: 1, max_length: 6),
            max_runs: 20
          ) do
      org_a = mk_org("pA-" <> name_a)
      org_b = mk_org("pB-" <> name_b)

      scope_a = mk_actor(org_a.id)
      mk_person(org_b.id, "Bob")

      query = Person |> Ash.Query.select([:id, :org_id])
      {:ok, seen} = Ash.read(query, actor: scope_a.actor, authorize?: true)
      seen_orgs = seen |> Enum.map(& &1.org_id) |> Enum.uniq()

      refute org_b.id in seen_orgs
    end
  end

  # =========================================================================
  # Cross-org WRITE denial.
  # =========================================================================

  test "an actor cannot update a foreign org's company (cross-org write denied)" do
    org_a = mk_org("wa-cmp")
    org_b = mk_org("wb-cmp")

    scope_a = mk_actor(org_a.id, :member)
    company_b = mk_company(org_b.id, "ForeignCo")

    result =
      company_b
      |> Ash.Changeset.for_update(:update, %{notes: "tampered"})
      |> Ash.update(actor: scope_a.actor, authorize?: true)

    assert {:error, %Ash.Error.Forbidden{}} = result
  end

  test "an actor cannot update a foreign org's person (cross-org write denied)" do
    org_a = mk_org("wa-per")
    org_b = mk_org("wb-per")

    scope_a = mk_actor(org_a.id, :member)
    person_b = mk_person(org_b.id, "ForeignPerson")

    result =
      person_b
      |> Ash.Changeset.for_update(:update, %{display_name: "tampered"})
      |> Ash.update(actor: scope_a.actor, authorize?: true)

    assert {:error, %Ash.Error.Forbidden{}} = result
  end

  # =========================================================================
  # Org-less actor — fail closed.
  # =========================================================================

  test "an org-less actor sees zero CRM rows (fail closed)" do
    org = mk_org("orgless-crm")
    mk_company(org.id, "AcmeCo")

    orgless_actor = %{id: "nobody", org_id: nil, role: :member}

    case Ash.read(Company, actor: orgless_actor, authorize?: true) do
      {:ok, seen} -> assert seen == []
      {:error, %Ash.Error.Forbidden{}} -> assert true
    end
  end

  # =========================================================================
  # Positive cases — an actor DOES see + write its OWN org's rows.
  # =========================================================================

  test "an actor sees its own org's company (positive read case)" do
    org = mk_org("self-read-cmp")
    scope = mk_actor(org.id, :member)
    mk_company(org.id, "OwnCo")

    query = Company |> Ash.Query.select([:id, :org_id])
    {:ok, seen} = Ash.read(query, actor: scope.actor, authorize?: true)
    assert length(seen) == 1
    assert hd(seen).org_id == org.id
  end

  test "an actor CAN update its own org's company (positive write case)" do
    org = mk_org("self-write-cmp")
    scope = mk_actor(org.id, :member)
    company = mk_company(org.id, "OwnCo")

    assert {:ok, updated} =
             company
             |> Ash.Changeset.for_update(:update, %{notes: "legit update"})
             |> Ash.update(actor: scope.actor, authorize?: true)

    assert updated.notes == "legit update"
  end

  # =========================================================================
  # PII masked-by-default on the tenant-plane read (person🔒).
  # =========================================================================

  test "person PII (full_name, emails, phones) is %Masked{} by default on a tenant-plane read" do
    org = mk_org("mask-per")
    scope = mk_actor(org.id, :member)
    mk_person(org.id, "masked")

    query = Person |> Ash.Query.select([:id, :full_name, :emails, :phones])
    {:ok, [person]} = Ash.read(query, actor: scope.actor, authorize?: true)

    assert %Samen.Masked{} = person.full_name
    assert %Samen.Masked{} = person.emails
    assert %Samen.Masked{} = person.phones

    # The masked value renders as bullets.
    assert Phoenix.HTML.Safe.to_iodata(person.full_name) |> IO.iodata_to_binary() =~ "•"
  end

  # =========================================================================
  # Tier-0 config rows: Pipeline stages — admin-gated writes.
  # =========================================================================

  test "a member actor cannot create a pipeline stage (admin-gate)" do
    org = mk_org("pip-member-gate")
    member_scope = mk_actor(org.id, :member)

    result =
      Pipeline
      |> Ash.Changeset.for_create(:create, %{name: "LeadStage", org_id: org.id, stage_order: 1})
      |> Ash.create(actor: member_scope.actor, authorize?: true)

    assert {:error, %Ash.Error.Forbidden{}} = result
  end

  test "an admin actor CAN create a pipeline stage (Tier-0 config row)" do
    org = mk_org("pip-admin-gate")
    admin_scope = mk_actor(org.id, :admin)

    assert {:ok, stage} =
             Pipeline
             |> Ash.Changeset.for_create(:create, %{
               name: "LeadStage",
               org_id: org.id,
               stage_order: 1,
               stage_type: :open
             })
             |> Ash.create(actor: admin_scope.actor, authorize?: true)

    assert stage.name == "LeadStage"
    assert stage.stage_type == :open
  end

  test "pipeline stages are org-scoped (cross-org pipeline denied)" do
    org_a = mk_org("pip-xa")
    org_b = mk_org("pip-xb")
    scope_a = mk_actor(org_a.id, :admin)
    mk_pipeline_stage(org_b.id, "B-Lead")

    query = Pipeline |> Ash.Query.select([:id, :org_id])
    {:ok, seen} = Ash.read(query, actor: scope_a.actor, authorize?: true)
    seen_orgs = seen |> Enum.map(& &1.org_id) |> Enum.uniq()
    refute org_b.id in seen_orgs
  end

  # =========================================================================
  # Smoke: opportunities, activities, attachments are all org-scoped.
  # =========================================================================

  test "opportunities, tasks, attachments are org-scoped (cross-org invisible)" do
    org_a = mk_org("smoke-xa")
    org_b = mk_org("smoke-xb")
    scope_a = mk_actor(org_a.id, :member)

    company_b = mk_company(org_b.id, "SmokeCoB")
    person_b = mk_person(org_b.id, "SmokePerson")

    # Create opportunity in org_b.
    {:ok, opp_b} =
      Opportunity
      |> Ash.Changeset.for_create(:create, %{
        name: "OppB",
        org_id: org_b.id,
        company_id: company_b.id
      })
      |> Ash.create(authorize?: false)

    # Work Task (former Activity, ADR-041 §5) anchored to org_b's person + attachment in org_b.
    {:ok, _task_b} =
      Task
      |> Ash.Changeset.for_create(:create, %{
        kind: :note,
        org_id: org_b.id,
        subject_key: "crm.person",
        subject_id: person_b.id
      })
      |> Ash.create(authorize?: false)

    {:ok, _att_b} =
      Attachment
      |> Ash.Changeset.for_create(:create, %{
        file_name: "secret.pdf",
        org_id: org_b.id,
        company_id: company_b.id
      })
      |> Ash.create(authorize?: false)

    # org_a actor sees ZERO of org_b's rows across all three resources.
    {:ok, opps} = Ash.read(Opportunity, actor: scope_a.actor, authorize?: true)
    {:ok, tasks} = Ash.read(Task, actor: scope_a.actor, authorize?: true)
    {:ok, atts} = Ash.read(Attachment, actor: scope_a.actor, authorize?: true)

    assert Enum.all?(opps, fn r -> r.org_id == org_a.id end)
    assert Enum.all?(tasks, fn r -> r.org_id == org_a.id end)
    assert Enum.all?(atts, fn r -> r.org_id == org_a.id end)

    # Specifically, org_b's rows are absent.
    refute Enum.any?(opps, fn r -> r.id == opp_b.id end)

    _ = opp_b
  end

  # =========================================================================
  # Cross-org protection at the Task anchor (ADR-041 §6.1) — the SameOrgFk
  # replacement. The canonical Task's subject is a GENERIC object-ref
  # `(subject_key, subject_id)`, NOT a belongs_to — so SameOrgFk cannot target it
  # and a cross-org anchor is not DB-rejected. Instead the reference is INERT:
  # OrgScope narrows every read to the actor's org, so org-A can never RESOLVE
  # (reach) org-B's person through the anchor. This is exactly the OrgScope filter
  # the org-scoped `Samen.Web.ObjectRef.resolve/3` boundary relies on in samen_web
  # (unavailable to this samen_core-only demo host, so tested at the OrgScope layer).
  # NOT weakened: the cross-tenant reach is still refused; the positive control
  # (same-org resolves) is retained (anti-tautology).
  # =========================================================================

  test "an org-A task anchoring an org-B person is INERT — org-A cannot resolve the cross-org reference (ADR-041 §6.1)" do
    org_a = mk_org("xfk-a")
    org_b = mk_org("xfk-b")
    scope_a = mk_actor(org_a.id, :member)
    person_b = mk_person(org_b.id, "ForeignPerson")

    {:ok, task} =
      Task
      |> Ash.Changeset.for_create(:create, %{
        kind: :note,
        org_id: org_a.id,
        subject_key: "crm.person",
        subject_id: person_b.id
      })
      |> Ash.create(authorize?: false)

    # RED PATH: org-A, reading persons under authorization, can NOT see org-B's person —
    # so the anchored id is unresolvable and the reference is inert (no cross-tenant reach).
    {:ok, visible} = Ash.read(Person, actor: scope_a.actor, authorize?: true)

    refute Enum.any?(visible, &(&1.id == task.subject_id)),
           "org-A must NOT resolve org-B's person through a task anchor (cross-org reach)"
  end

  test "a same-org task anchoring a same-org person RESOLVES (positive control)" do
    org = mk_org("xfk-ok")
    scope = mk_actor(org.id, :member)
    person = mk_person(org.id, "SameOrgPerson")

    {:ok, task} =
      Task
      |> Ash.Changeset.for_create(:create, %{
        kind: :note,
        org_id: org.id,
        subject_key: "crm.person",
        subject_id: person.id
      })
      |> Ash.create(authorize?: false)

    {:ok, visible} = Ash.read(Person, actor: scope.actor, authorize?: true)

    assert Enum.any?(visible, &(&1.id == task.subject_id)),
           "same-org person must resolve through the anchor (positive control)"
  end
end
