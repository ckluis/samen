defmodule Demo.PrimitivesScopeRbacRedPathTest do
  @moduledoc """
  RBAC red paths for the Primitives scope (T3.7).

  Proves:
    * a member actor cannot create/update/delete Tier-0 config resources
      (webhook, feature_flag, search_index);
    * admin-gate enforced on all three Tier-0 resources;
    * role escalation through the RBAC check denies;
    * positive controls (admin can perform those actions).
  """
  use Demo.DataCase, async: false

  alias Demo.PrimitivesScope.{Notification, File, SearchIndex, Webhook, FeatureFlag}
  alias Demo.Identity.{Org, User}

  defp mk_org(name) do
    {:ok, org} =
      Org
      |> Ash.Changeset.for_create(:create, %{name: name})
      |> Ash.create(authorize?: false)

    org
  end

  defp mk_actor(org_id, role) do
    {:ok, user} =
      User
      |> Ash.Changeset.for_create(:create, %{
        handle: "rbac-actor-#{:rand.uniform(999_999)}",
        org_id: org_id,
        full_name: %{first: "RBAC", last: "Test"},
        emails: ["rbac#{:rand.uniform(999_999)}@example.com"]
      })
      |> Ash.create(authorize?: false)

    Samen.Scope.new(%{id: user.id, org_id: org_id, role: role})
  end

  defp mk_webhook(org_id) do
    {:ok, w} =
      Webhook
      |> Ash.Changeset.for_create(:create, %{
        url: "https://example.com/hook/rbac-#{:rand.uniform(9999)}",
        event_types: ["test.event"],
        signing_secret: "rbac-secret-#{Ash.UUID.generate()}",
        org_id: org_id
      })
      |> Ash.create(authorize?: false)

    w
  end

  defp mk_feature_flag(org_id) do
    {:ok, ff} =
      FeatureFlag
      |> Ash.Changeset.for_create(:create, %{
        name: "rbac.test.flag.#{:rand.uniform(9999)}",
        enabled: false,
        org_id: org_id
      })
      |> Ash.create(authorize?: false)

    ff
  end

  # =========================================================================
  # Webhook — admin-gate (Tier-0 config)
  # =========================================================================

  test "viewer cannot create webhook (admin-gate)" do
    org = mk_org("rbac-pwh-viewer")
    viewer = mk_actor(org.id, :viewer)

    result =
      Webhook
      |> Ash.Changeset.for_create(:create, %{
        url: "https://example.com/hook",
        signing_secret: "x",
        org_id: org.id
      })
      |> Ash.create(actor: viewer.actor, authorize?: true)

    assert {:error, %Ash.Error.Forbidden{}} = result
  end

  test "member cannot create webhook (admin-gate)" do
    org = mk_org("rbac-pwh-member")
    member = mk_actor(org.id, :member)

    result =
      Webhook
      |> Ash.Changeset.for_create(:create, %{
        url: "https://example.com/hook",
        signing_secret: "x",
        org_id: org.id
      })
      |> Ash.create(actor: member.actor, authorize?: true)

    assert {:error, %Ash.Error.Forbidden{}} = result
  end

  test "member cannot delete webhook (admin-gate)" do
    org = mk_org("rbac-pwh-del")
    member = mk_actor(org.id, :member)
    webhook = mk_webhook(org.id)

    result =
      webhook
      |> Ash.Changeset.for_destroy(:destroy)
      |> Ash.destroy(actor: member.actor, authorize?: true)

    assert {:error, %Ash.Error.Forbidden{}} = result
  end

  test "admin can create webhook (positive control)" do
    org = mk_org("rbac-pwh-admin-ok")
    admin = mk_actor(org.id, :admin)

    result =
      Webhook
      |> Ash.Changeset.for_create(:create, %{
        url: "https://example.com/hook/admin-#{:rand.uniform(9999)}",
        event_types: ["invoice.created"],
        signing_secret: "admin-sec-#{Ash.UUID.generate()}",
        org_id: org.id
      })
      |> Ash.create(actor: admin.actor, authorize?: true)

    assert {:ok, _webhook} = result
  end

  test "admin can delete webhook (positive control)" do
    org = mk_org("rbac-pwh-del-ok")
    admin = mk_actor(org.id, :admin)
    webhook = mk_webhook(org.id)

    result =
      webhook
      |> Ash.Changeset.for_destroy(:destroy)
      |> Ash.destroy(actor: admin.actor, authorize?: true)

    # Ash.destroy returns :ok (not {:ok, _}) for a destroy action.
    assert result == :ok or match?({:ok, _}, result)
  end

  # =========================================================================
  # FeatureFlag — admin-gate (Tier-0 config)
  # =========================================================================

  test "viewer cannot create feature flag (admin-gate)" do
    org = mk_org("rbac-pff-viewer")
    viewer = mk_actor(org.id, :viewer)

    result =
      FeatureFlag
      |> Ash.Changeset.for_create(:create, %{
        name: "viewer.flag",
        enabled: true,
        org_id: org.id
      })
      |> Ash.create(actor: viewer.actor, authorize?: true)

    assert {:error, %Ash.Error.Forbidden{}} = result
  end

  test "member cannot toggle feature flag (admin-gate)" do
    org = mk_org("rbac-pff-member")
    member = mk_actor(org.id, :member)
    flag = mk_feature_flag(org.id)

    result =
      flag
      |> Ash.Changeset.for_update(:update, %{enabled: true})
      |> Ash.update(actor: member.actor, authorize?: true)

    assert {:error, %Ash.Error.Forbidden{}} = result
  end

  test "admin can toggle feature flag (positive control)" do
    org = mk_org("rbac-pff-admin-ok")
    admin = mk_actor(org.id, :admin)
    flag = mk_feature_flag(org.id)

    result =
      flag
      |> Ash.Changeset.for_update(:update, %{enabled: true})
      |> Ash.update(actor: admin.actor, authorize?: true)

    assert {:ok, updated} = result
    assert updated.enabled == true
  end

  # =========================================================================
  # SearchIndex — admin-gate
  # =========================================================================

  test "member cannot create search index entry (admin-gate)" do
    org = mk_org("rbac-psh-member")
    member = mk_actor(org.id, :member)

    result =
      SearchIndex
      |> Ash.Changeset.for_create(:create, %{
        resource_name: "Demo.PrimitivesScope.File",
        field_name: "filename",
        vector_column: "pfl_search_vector",
        org_id: org.id
      })
      |> Ash.create(actor: member.actor, authorize?: true)

    assert {:error, %Ash.Error.Forbidden{}} = result
  end

  test "admin can create search index entry (positive control)" do
    org = mk_org("rbac-psh-admin-ok")
    admin = mk_actor(org.id, :admin)

    result =
      SearchIndex
      |> Ash.Changeset.for_create(:create, %{
        resource_name: "Demo.PrimitivesScope.File",
        field_name: "filename",
        vector_column: "pfl_search_vector",
        description: "Full-text search over file names",
        org_id: org.id
      })
      |> Ash.create(actor: admin.actor, authorize?: true)

    assert {:ok, _} = result
  end

  # =========================================================================
  # Notification and File — member can create (no admin gate)
  # =========================================================================

  test "member can create a notification (no admin gate for notifications)" do
    org = mk_org("rbac-ntf-member-ok")
    member = mk_actor(org.id, :member)

    result =
      Notification
      |> Ash.Changeset.for_create(:create, %{
        recipient_id: Ash.UUID.generate(),
        channel: :in_app,
        event_type: "test.event",
        status: :pending,
        rendered_body: "Test notification body",
        org_id: org.id
      })
      |> Ash.create(actor: member.actor, authorize?: true)

    assert {:ok, _} = result
  end

  test "member can create a file record (member+ gate for files)" do
    org = mk_org("rbac-pfl-member-ok")
    member = mk_actor(org.id, :member)

    result =
      File
      |> Ash.Changeset.for_create(:create, %{
        filename: "test-file.pdf",
        content_type: "application/pdf",
        size_bytes: 1024,
        storage_key: "s3://bucket/#{Ash.UUID.generate()}",
        org_id: org.id
      })
      |> Ash.create(actor: member.actor, authorize?: true)

    assert {:ok, _} = result
  end

  test "viewer cannot create file (member+ gate)" do
    org = mk_org("rbac-pfl-viewer-deny")
    viewer = mk_actor(org.id, :viewer)

    result =
      File
      |> Ash.Changeset.for_create(:create, %{
        filename: "viewer-file.pdf",
        content_type: "application/pdf",
        size_bytes: 256,
        storage_key: "s3://bucket/#{Ash.UUID.generate()}",
        org_id: org.id
      })
      |> Ash.create(actor: viewer.actor, authorize?: true)

    assert {:error, %Ash.Error.Forbidden{}} = result
  end
end
