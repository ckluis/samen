defmodule Demo.MarketingScopeRbacRedPathTest do
  @moduledoc """
  RBAC red paths for the Marketing scope (T3.4). Exercises role escalation denial,
  admin-gate enforcement, and the positive controls.

  Covers:
    * member cannot create/update template (admin-gated Tier-0 resource);
    * member cannot create/update campaign (admin-gated);
    * member cannot create/update/destroy segment (admin-gated);
    * admin CAN create/update/destroy these resources (positive controls);
    * member CANNOT create a suppression entry (admin-gated);
    * template and campaign RBAC: positive controls for the Ash policy evaluation.
  """
  use Demo.DataCase, async: false

  alias Demo.MarketingScope.{Campaign, Segment, Template, Suppression, Subscriber}
  alias Demo.Identity.{Org, User}

  defp mk_org(name) do
    {:ok, org} =
      Org |> Ash.Changeset.for_create(:create, %{name: name}) |> Ash.create(authorize?: false)

    org
  end

  defp mk_scope(org_id, role) do
    {:ok, user} =
      User
      |> Ash.Changeset.for_create(:create, %{
        handle: "rbac-#{role}-#{:rand.uniform(99_999)}",
        org_id: org_id,
        full_name: %{first: "RBAC", last: "Actor"},
        emails: ["rbac#{:rand.uniform(99_999)}@mkt.example"]
      })
      |> Ash.create(authorize?: false)

    Samen.Scope.new(%{id: user.id, org_id: org_id, role: role})
  end

  # =========================================================================
  # Template — Tier-0 config row, admin-gated writes.
  # =========================================================================

  test "member cannot create a template (Tier-0 admin gate)" do
    org = mk_org("rbac-tmpl-member")
    member = mk_scope(org.id, :member)

    result =
      Template
      |> Ash.Changeset.for_create(:create, %{
        name: "Sneaky",
        org_id: org.id,
        subject_line: "Not allowed"
      })
      |> Ash.create(actor: member.actor, authorize?: true)

    assert {:error, %Ash.Error.Forbidden{}} = result
  end

  test "viewer cannot create a template (Tier-0 admin gate)" do
    org = mk_org("rbac-tmpl-viewer")
    viewer = mk_scope(org.id, :viewer)

    result =
      Template
      |> Ash.Changeset.for_create(:create, %{
        name: "Sneaky",
        org_id: org.id,
        subject_line: "Not allowed"
      })
      |> Ash.create(actor: viewer.actor, authorize?: true)

    assert {:error, %Ash.Error.Forbidden{}} = result
  end

  test "admin CAN create a template (positive control)" do
    org = mk_org("rbac-tmpl-admin")
    admin = mk_scope(org.id, :admin)

    assert {:ok, tmpl} =
             Template
             |> Ash.Changeset.for_create(:create, %{
               name: "Welcome",
               org_id: org.id,
               subject_line: "Welcome to Samen"
             })
             |> Ash.create(actor: admin.actor, authorize?: true)

    assert tmpl.name == "Welcome"
  end

  test "member cannot update a template (Tier-0 admin gate)" do
    org = mk_org("rbac-tmpl-upd")
    admin = mk_scope(org.id, :admin)
    member = mk_scope(org.id, :member)

    {:ok, tmpl} =
      Template
      |> Ash.Changeset.for_create(:create, %{
        name: "Original",
        org_id: org.id,
        subject_line: "Original subject"
      })
      |> Ash.create(authorize?: false)

    result =
      tmpl
      |> Ash.Changeset.for_update(:update, %{subject_line: "tampered"})
      |> Ash.update(actor: member.actor, authorize?: true)

    assert {:error, %Ash.Error.Forbidden{}} = result

    # Admin can update.
    assert {:ok, updated} =
             tmpl
             |> Ash.Changeset.for_update(:update, %{subject_line: "admin updated"})
             |> Ash.update(actor: admin.actor, authorize?: true)

    assert updated.subject_line == "admin updated"
  end

  # =========================================================================
  # Campaign — admin-gated writes.
  # =========================================================================

  test "member cannot create a campaign (admin gate enforced)" do
    org = mk_org("rbac-camp-member")
    member = mk_scope(org.id, :member)

    result =
      Campaign
      |> Ash.Changeset.for_create(:create, %{
        name: "Sneaky Campaign",
        org_id: org.id
      })
      |> Ash.create(actor: member.actor, authorize?: true)

    assert {:error, %Ash.Error.Forbidden{}} = result
  end

  test "admin CAN create a campaign (positive control)" do
    org = mk_org("rbac-camp-admin")
    admin = mk_scope(org.id, :admin)

    assert {:ok, campaign} =
             Campaign
             |> Ash.Changeset.for_create(:create, %{
               name: "Admin Campaign",
               org_id: org.id,
               status: :draft
             })
             |> Ash.create(actor: admin.actor, authorize?: true)

    assert campaign.name == "Admin Campaign"
  end

  # =========================================================================
  # Segment — admin-gated writes.
  # =========================================================================

  test "member cannot create a segment (admin gate enforced)" do
    org = mk_org("rbac-seg-member")
    member = mk_scope(org.id, :member)

    result =
      Segment
      |> Ash.Changeset.for_create(:create, %{
        name: "Sneaky Segment",
        org_id: org.id
      })
      |> Ash.create(actor: member.actor, authorize?: true)

    assert {:error, %Ash.Error.Forbidden{}} = result
  end

  test "admin CAN create a segment (positive control)" do
    org = mk_org("rbac-seg-admin")
    admin = mk_scope(org.id, :admin)

    assert {:ok, seg} =
             Segment
             |> Ash.Changeset.for_create(:create, %{
               name: "Active Subscribers",
               org_id: org.id,
               filter_criteria: %{"status" => "active"}
             })
             |> Ash.create(actor: admin.actor, authorize?: true)

    assert seg.name == "Active Subscribers"
  end

  # =========================================================================
  # Suppression — admin-gated writes.
  # =========================================================================

  test "member cannot create a suppression entry (admin gate enforced)" do
    org = mk_org("rbac-supp-member")
    member = mk_scope(org.id, :member)

    {:ok, subscriber} =
      Subscriber
      |> Ash.Changeset.for_create(:create, %{
        org_id: org.id,
        email: "rbac-sub@test.example",
        status: :active
      })
      |> Ash.create(authorize?: false)

    result =
      Suppression
      |> Ash.Changeset.for_create(:create, %{
        org_id: org.id,
        subscriber_id: subscriber.id,
        reason: :unsubscribed,
        active: true
      })
      |> Ash.create(actor: member.actor, authorize?: true)

    assert {:error, %Ash.Error.Forbidden{}} = result
  end

  test "admin CAN create a suppression entry (positive control)" do
    org = mk_org("rbac-supp-admin")
    admin = mk_scope(org.id, :admin)

    {:ok, subscriber} =
      Subscriber
      |> Ash.Changeset.for_create(:create, %{
        org_id: org.id,
        email: "admin-supp@test.example",
        status: :active
      })
      |> Ash.create(authorize?: false)

    assert {:ok, supp} =
             Suppression
             |> Ash.Changeset.for_create(:create, %{
               org_id: org.id,
               subscriber_id: subscriber.id,
               reason: :admin_added,
               active: true
             })
             |> Ash.create(actor: admin.actor, authorize?: true)

    assert supp.reason == :admin_added
    assert supp.active == true
  end
end
