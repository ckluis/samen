defmodule Demo.CmsScopeRbacRedPathTest do
  @moduledoc """
  RBAC red paths for the CMS scope (T3.5).

  Exercises:
    * escalation denied (member cannot create blocks/media/navigation — admin-gated)
    * positive controls (an admin CAN write to admin-gated resources)
    * the pure Samen.Scope.Role decision functions (no DB)
    * E7 content history: a member's allowed content edit records a version (versioning
      is a side effect of the tracked write, not a separately role-gated action)
    * non-PII classification: csm_description is deliberately registered as non-PII
      with distinct reviewers (mask-unknown-by-default proof)
  """
  use Demo.DataCase, async: false

  alias Demo.CmsScope.{Page, Block, Media, Navigation, SeoMeta}
  alias Demo.Identity.{Org, User}

  defp mk_org(name) do
    {:ok, org} =
      Org |> Ash.Changeset.for_create(:create, %{name: name}) |> Ash.create(authorize?: false)
    org
  end

  defp mk_actor(org_id, role) do
    {:ok, user} =
      User
      |> Ash.Changeset.for_create(:create, %{
        handle: "rbac-#{:rand.uniform(999_999)}",
        org_id: org_id,
        full_name: %{first: "RBAC", last: "Test"},
        emails: ["rbac#{:rand.uniform(999_999)}@example.com"]
      })
      |> Ash.create(authorize?: false)

    Samen.Scope.new(%{id: user.id, org_id: org_id, role: role})
  end

  defp mk_page(org_id) do
    {:ok, page} =
      Page
      |> Ash.Changeset.for_create(:create, %{
        title: "RBAC Test Page",
        org_id: org_id
      })
      |> Ash.create(authorize?: false)
    page
  end

  # =========================================================================
  # Member cannot use admin-gated CMS actions.
  # =========================================================================

  test "member cannot create a block (admin-gated)" do
    org = mk_org("rbac-blk-member")
    member = mk_actor(org.id, :member)
    page = mk_page(org.id)

    result =
      Block
      |> Ash.Changeset.for_create(:create, %{
        name: "Hacked Block",
        org_id: org.id,
        page_id: page.id
      })
      |> Ash.create(actor: member.actor, authorize?: true)

    assert {:error, %Ash.Error.Forbidden{}} = result
  end

  test "member cannot create media (admin-gated)" do
    org = mk_org("rbac-media-member")
    member = mk_actor(org.id, :member)

    result =
      Media
      |> Ash.Changeset.for_create(:create, %{
        file_name: "hack.jpg",
        org_id: org.id
      })
      |> Ash.create(actor: member.actor, authorize?: true)

    assert {:error, %Ash.Error.Forbidden{}} = result
  end

  test "member cannot create a navigation item (admin-gated)" do
    org = mk_org("rbac-nav-member")
    member = mk_actor(org.id, :member)

    result =
      Navigation
      |> Ash.Changeset.for_create(:create, %{
        label: "Hacked Nav",
        url: "/hacked",
        org_id: org.id
      })
      |> Ash.create(actor: member.actor, authorize?: true)

    assert {:error, %Ash.Error.Forbidden{}} = result
  end

  test "member cannot create SEO meta (admin-gated)" do
    org = mk_org("rbac-seo-member")
    member = mk_actor(org.id, :member)
    page = mk_page(org.id)

    result =
      SeoMeta
      |> Ash.Changeset.for_create(:create, %{
        meta_title: "Hacked SEO",
        org_id: org.id,
        page_id: page.id
      })
      |> Ash.create(actor: member.actor, authorize?: true)

    assert {:error, %Ash.Error.Forbidden{}} = result
  end

  # =========================================================================
  # Admin CAN use admin-gated actions (positive controls).
  # =========================================================================

  test "admin can create a block (positive control)" do
    org = mk_org("rbac-blk-admin")
    admin = mk_actor(org.id, :admin)
    page = mk_page(org.id)

    assert {:ok, block} =
             Block
             |> Ash.Changeset.for_create(:create, %{
               name: "Admin Block",
               block_type: :hero,
               org_id: org.id,
               page_id: page.id
             })
             |> Ash.create(actor: admin.actor, authorize?: true)

    assert block.name == "Admin Block"
  end

  test "admin can create media (positive control)" do
    org = mk_org("rbac-media-admin")
    admin = mk_actor(org.id, :admin)

    assert {:ok, media} =
             Media
             |> Ash.Changeset.for_create(:create, %{
               file_name: "hero.jpg",
               content_type: "image/jpeg",
               org_id: org.id
             })
             |> Ash.create(actor: admin.actor, authorize?: true)

    assert media.file_name == "hero.jpg"
  end

  # =========================================================================
  # E7 content history (ADR-040 §6.5, T119): content versions are recorded
  # AUTOMATICALLY by the E7 mechanism on any tracked write — they are NOT a
  # user-invoked, role-gated create (the retired ContentVersion's `:create_version`
  # was admin-gated; there is no such user action now). A member who edits content
  # they are allowed to edit records a version as a side effect — the RBAC gate is on
  # the CONTENT action (publish/mark_archived are admin-gated), not on versioning.
  # =========================================================================

  test "a member's allowed content edit records a version (versioning is not separately role-gated)" do
    org = mk_org("rbac-ver-member")
    member = mk_actor(org.id, :member)
    page = mk_page(org.id)

    # A member may edit draft content (the CMS member-level :update, F3.4). This
    # records a Block/Page.Version automatically; there is no separate version RBAC.
    assert {:ok, _} =
             page
             |> Ash.Changeset.for_update(:update, %{body: "member edit"})
             |> Ash.update(actor: member.actor, authorize?: true)

    {:ok, versions} =
      Demo.CmsScope.Page.Version
      |> Ash.Query.select([:id, :version_source_id])
      |> Ash.read(actor: member.actor, authorize?: true)

    assert Enum.any?(versions, &(&1.version_source_id == page.id))
  end

  # =========================================================================
  # Non-PII classification: csm_description registration (mask-unknown-by-default).
  # =========================================================================

  test "csm_description can be registered as non-PII with distinct reviewers" do
    # This test proves the mask-unknown-by-default discipline (D9) was applied.
    # The registration requires distinct reviewers (fail closed on self-review).
    result =
      Samen.NonPii.register(%{
        table_name: "csm_seo_meta",
        column_name: "csm_description",
        cleared_by: "test-scope-author",
        reviewed_by: "test-gate-reviewer",
        reason:
          "SEO description is authored marketing copy, not subject PII (T3.5 non-PII proof).",
        subject_column: "csm_org_id",
        redaction: "[REDACTED_CONTENT]"
      })

    assert {:ok, entry} = result
    assert entry.table_name == "csm_seo_meta"
    assert entry.column_name == "csm_description"
  end

  test "csm_description non-PII registration fails on self-review (distinct-party discipline)" do
    # The distinct-party invariant: the same person cannot both request and review.
    result =
      Samen.NonPii.register(%{
        table_name: "csm_seo_meta",
        column_name: "csm_description",
        cleared_by: "same-person",
        reviewed_by: "same-person",
        reason: "self-review attempt",
        subject_column: "csm_org_id"
      })

    assert {:error, :self_review} = result
  end

  # =========================================================================
  # Samen.Scope.Role decision functions (pure, no DB).
  # =========================================================================

  test "CMS RBAC role ordering: owner > admin > member > viewer (pure decision functions)" do
    alias Samen.Scope.Role

    # Role rank ordering.
    assert Role.rank(:owner) > Role.rank(:admin)
    assert Role.rank(:admin) > Role.rank(:member)
    assert Role.rank(:member) > Role.rank(:viewer)

    # at_least?/2: admin at_least :admin = true; member at_least :admin = false.
    assert Role.at_least?(:admin, :admin)
    assert Role.at_least?(:owner, :admin)
    refute Role.at_least?(:member, :admin)
    refute Role.at_least?(:viewer, :admin)

    # may_manage?/2: an actor can only manage roles STRICTLY BELOW their own rank.
    assert Role.may_manage?(:admin, :member)
    assert Role.may_manage?(:admin, :viewer)
    refute Role.may_manage?(:admin, :admin)
    refute Role.may_manage?(:admin, :owner)
    refute Role.may_manage?(:member, :member)
  end
end
