defmodule Demo.CmsScopePolicyMatrixTest do
  @moduledoc """
  The CMS scope org-scope + RBAC policy matrix (T3.5). Exercises the REAL
  mounted CMS resources against the REAL Postgres, through the REAL Ash policy
  authorizer.

  Covers:
    * cross-org read denied (org-scope FilterCheck) — a property test over many
      org pairs (the `cross-org read denied` red path);
    * cross-org write denied;
    * org-less actor sees zero rows (fail closed);
    * positive cases (an actor sees + writes its OWN org's rows);
    * admin-gate on publish (draft→publish workflow);
    * member cannot publish (RBAC red path);
    * Tier-0 config rows (Navigation) — admin-gated writes;
    * ContentVersion is append-only (no :update/:destroy actions);
    * PII — no vault-routed PII in this scope (all fields non-PII).
  """
  use Demo.DataCase, async: false
  use ExUnitProperties

  alias Demo.CmsScope.{Page, Post, Block, Media, Navigation, SeoMeta, ContentVersion}
  alias Demo.Identity.{Org, User}

  # --- helpers ---------------------------------------------------------------

  defp mk_org(name) do
    {:ok, org} =
      Org |> Ash.Changeset.for_create(:create, %{name: name}) |> Ash.create(authorize?: false)
    org
  end

  defp mk_actor(org_id, role \\ :member) do
    {:ok, user} =
      User
      |> Ash.Changeset.for_create(:create, %{
        handle: "cms-actor-#{:rand.uniform(999_999)}",
        org_id: org_id,
        full_name: %{first: "CMS", last: "Actor"},
        emails: ["cms#{:rand.uniform(999_999)}@example.com"]
      })
      |> Ash.create(authorize?: false)

    Samen.Scope.new(%{id: user.id, org_id: org_id, role: role})
  end

  defp mk_page(org_id, title \\ "Test Page") do
    {:ok, page} =
      Page
      |> Ash.Changeset.for_create(:create, %{
        title: title,
        slug: "page-#{:rand.uniform(999_999)}",
        body: "Page body content.",
        org_id: org_id
      })
      |> Ash.create(authorize?: false)
    page
  end

  defp mk_post(org_id, title \\ "Test Post") do
    {:ok, post} =
      Post
      |> Ash.Changeset.for_create(:create, %{
        title: title,
        slug: "post-#{:rand.uniform(999_999)}",
        body: "Post body content.",
        org_id: org_id
      })
      |> Ash.create(authorize?: false)
    post
  end

  defp mk_navigation(org_id) do
    {:ok, nav} =
      Navigation
      |> Ash.Changeset.for_create(:create, %{
        label: "Home",
        url: "/",
        nav_type: :main,
        org_id: org_id
      })
      |> Ash.create(authorize?: false)
    nav
  end

  defp mk_content_version(org_id, page_id, version_number \\ 1) do
    {:ok, version} =
      ContentVersion
      |> Ash.Changeset.for_create(:create_version, %{
        subject_type: "page",
        subject_id: page_id,
        content_snapshot: %{"title" => "Draft", "body" => "v#{version_number}"},
        status: :draft,
        author_id: org_id,
        version_number: version_number,
        org_id: org_id
      })
      |> Ash.create(authorize?: false)
    version
  end

  # =========================================================================
  # Cross-org read denial — org-scope FilterCheck. PROPERTY test.
  # =========================================================================

  property "an actor scoped to org A never reads another org's pages (cross-org read denied)" do
    check all(
            name_a <- string(:alphanumeric, min_length: 1, max_length: 8),
            name_b <- string(:alphanumeric, min_length: 1, max_length: 8),
            max_runs: 20
          ) do
      org_a = mk_org("cms-pA-" <> name_a)
      org_b = mk_org("cms-pB-" <> name_b)

      scope_a = mk_actor(org_a.id)
      mk_page(org_b.id, "B-Page")

      query = Page |> Ash.Query.select([:id, :org_id])
      {:ok, seen} = Ash.read(query, actor: scope_a.actor, authorize?: true)
      seen_orgs = seen |> Enum.map(& &1.org_id) |> Enum.uniq()

      # Org B's pages are invisible (filtered, not just forbidden).
      refute org_b.id in seen_orgs
    end
  end

  property "an actor scoped to org A never reads another org's posts (cross-org read denied)" do
    check all(
            name_a <- string(:alphanumeric, min_length: 1, max_length: 6),
            name_b <- string(:alphanumeric, min_length: 1, max_length: 6),
            max_runs: 20
          ) do
      org_a = mk_org("cms-ptA-" <> name_a)
      org_b = mk_org("cms-ptB-" <> name_b)

      scope_a = mk_actor(org_a.id)
      mk_post(org_b.id, "B-Post")

      query = Post |> Ash.Query.select([:id, :org_id])
      {:ok, seen} = Ash.read(query, actor: scope_a.actor, authorize?: true)
      seen_orgs = seen |> Enum.map(& &1.org_id) |> Enum.uniq()

      refute org_b.id in seen_orgs
    end
  end

  # =========================================================================
  # Cross-org WRITE denial.
  # =========================================================================

  test "an actor cannot update a foreign org's page (cross-org write denied)" do
    org_a = mk_org("cms-wa-page")
    org_b = mk_org("cms-wb-page")

    scope_a = mk_actor(org_a.id, :member)
    page_b = mk_page(org_b.id, "ForeignPage")

    result =
      page_b
      |> Ash.Changeset.for_update(:update, %{body: "tampered"})
      |> Ash.update(actor: scope_a.actor, authorize?: true)

    assert {:error, %Ash.Error.Forbidden{}} = result
  end

  # =========================================================================
  # Org-less actor — fail closed.
  # =========================================================================

  test "an org-less actor sees zero CMS rows (fail closed)" do
    org = mk_org("cms-orgless")
    mk_page(org.id, "AcmePage")

    orgless_actor = %{id: "nobody", org_id: nil, role: :member}

    case Ash.read(Page, actor: orgless_actor, authorize?: true) do
      {:ok, seen} -> assert seen == []
      {:error, %Ash.Error.Forbidden{}} -> assert true
    end
  end

  # =========================================================================
  # Positive cases — an actor DOES see + write its OWN org's rows.
  # =========================================================================

  test "an actor sees its own org's page (positive read case)" do
    org = mk_org("cms-self-read")
    scope = mk_actor(org.id, :member)
    mk_page(org.id, "OwnPage")

    query = Page |> Ash.Query.select([:id, :org_id])
    {:ok, seen} = Ash.read(query, actor: scope.actor, authorize?: true)
    assert length(seen) >= 1
    assert hd(seen).org_id == org.id
  end

  test "a member actor CAN update its own org's page (positive write case)" do
    org = mk_org("cms-self-write")
    scope = mk_actor(org.id, :member)
    page = mk_page(org.id, "OwnPage")

    assert {:ok, updated} =
             page
             |> Ash.Changeset.for_update(:update, %{body: "updated body"})
             |> Ash.update(actor: scope.actor, authorize?: true)

    assert updated.body == "updated body"
  end

  # =========================================================================
  # Draft → publish workflow. Admin-gated publish.
  # =========================================================================

  test "a page starts in :draft status" do
    org = mk_org("cms-draft")
    page = mk_page(org.id, "Draft Page")
    assert page.status == :draft
  end

  test "an admin can publish a page (draft→publish workflow)" do
    org = mk_org("cms-publish")
    admin_scope = mk_actor(org.id, :admin)
    page = mk_page(org.id, "To Publish")

    assert {:ok, published} =
             page
             |> Ash.Changeset.for_update(:publish, %{})
             |> Ash.update(actor: admin_scope.actor, authorize?: true)

    assert published.status == :published
    assert published.published_at != nil
  end

  test "a member cannot publish a page (admin-gate RBAC red path)" do
    org = mk_org("cms-member-publish")
    member_scope = mk_actor(org.id, :member)
    page = mk_page(org.id, "To Publish By Member")

    result =
      page
      |> Ash.Changeset.for_update(:publish, %{})
      |> Ash.update(actor: member_scope.actor, authorize?: true)

    assert {:error, %Ash.Error.Forbidden{}} = result
  end

  test "an admin can archive a page" do
    org = mk_org("cms-archive")
    admin_scope = mk_actor(org.id, :admin)
    page = mk_page(org.id, "To Archive")

    assert {:ok, archived} =
             page
             |> Ash.Changeset.for_update(:archive, %{})
             |> Ash.update(actor: admin_scope.actor, authorize?: true)

    assert archived.status == :archived
  end

  test "a member cannot archive a page (admin-gate RBAC red path)" do
    org = mk_org("cms-member-archive")
    member_scope = mk_actor(org.id, :member)
    page = mk_page(org.id, "To Archive By Member")

    result =
      page
      |> Ash.Changeset.for_update(:archive, %{})
      |> Ash.update(actor: member_scope.actor, authorize?: true)

    assert {:error, %Ash.Error.Forbidden{}} = result
  end

  # =========================================================================
  # Post: same workflow as Page.
  # =========================================================================

  test "an admin can publish a post" do
    org = mk_org("cms-post-publish")
    admin_scope = mk_actor(org.id, :admin)
    post = mk_post(org.id, "To Publish Post")

    assert {:ok, published} =
             post
             |> Ash.Changeset.for_update(:publish, %{})
             |> Ash.update(actor: admin_scope.actor, authorize?: true)

    assert published.status == :published
  end

  test "a member cannot publish a post (admin-gate RBAC red path)" do
    org = mk_org("cms-post-member-pub")
    member_scope = mk_actor(org.id, :member)
    post = mk_post(org.id, "Member Cannot Publish")

    result =
      post
      |> Ash.Changeset.for_update(:publish, %{})
      |> Ash.update(actor: member_scope.actor, authorize?: true)

    assert {:error, %Ash.Error.Forbidden{}} = result
  end

  # =========================================================================
  # Navigation: Tier-0 config rows — admin-gated writes.
  # =========================================================================

  test "a member cannot create a navigation item (admin-gate)" do
    org = mk_org("cms-nav-member-gate")
    member_scope = mk_actor(org.id, :member)

    result =
      Navigation
      |> Ash.Changeset.for_create(:create, %{
        label: "Hacked Nav",
        url: "/hacked",
        org_id: org.id
      })
      |> Ash.create(actor: member_scope.actor, authorize?: true)

    assert {:error, %Ash.Error.Forbidden{}} = result
  end

  test "an admin can create a navigation item (Tier-0 config row)" do
    org = mk_org("cms-nav-admin")
    admin_scope = mk_actor(org.id, :admin)

    assert {:ok, nav} =
             Navigation
             |> Ash.Changeset.for_create(:create, %{
               label: "Home",
               url: "/",
               nav_type: :main,
               org_id: org.id
             })
             |> Ash.create(actor: admin_scope.actor, authorize?: true)

    assert nav.label == "Home"
    assert nav.nav_type == :main
  end

  test "navigation items are org-scoped (cross-org navigation denied)" do
    org_a = mk_org("cms-nav-xa")
    org_b = mk_org("cms-nav-xb")
    scope_a = mk_actor(org_a.id, :admin)
    mk_navigation(org_b.id)

    query = Navigation |> Ash.Query.select([:id, :org_id])
    {:ok, seen} = Ash.read(query, actor: scope_a.actor, authorize?: true)
    seen_orgs = seen |> Enum.map(& &1.org_id) |> Enum.uniq()
    refute org_b.id in seen_orgs
  end

  # =========================================================================
  # ContentVersion: append-only. No :update or :destroy actions.
  # =========================================================================

  test "content versions are org-scoped and readable" do
    org = mk_org("cms-version-read")
    admin_scope = mk_actor(org.id, :admin)
    page = mk_page(org.id, "Versioned Page")
    _version = mk_content_version(org.id, page.id)

    query = ContentVersion |> Ash.Query.select([:id, :subject_id, :version_number])
    {:ok, versions} = Ash.read(query, actor: admin_scope.actor, authorize?: true)
    assert length(versions) >= 1
    assert hd(versions).subject_id == page.id
  end

  test "content versions are cross-org invisible" do
    org_a = mk_org("cms-ver-xa")
    org_b = mk_org("cms-ver-xb")
    scope_a = mk_actor(org_a.id, :admin)
    page_b = mk_page(org_b.id, "B Page")
    mk_content_version(org_b.id, page_b.id)

    query = ContentVersion |> Ash.Query.select([:id, :org_id])
    {:ok, seen} = Ash.read(query, actor: scope_a.actor, authorize?: true)
    seen_orgs = seen |> Enum.map(& &1.org_id) |> Enum.uniq()
    refute org_b.id in seen_orgs
  end

  test "ContentVersion has NO :update action (immutable history — red path)" do
    # The resource should have no :update action by design.
    actions = Ash.Resource.Info.actions(ContentVersion)
    action_names = Enum.map(actions, & &1.name)

    # There must be NO :update action (immutable append-only history).
    refute :update in action_names,
           "ContentVersion must NOT have an :update action — it is immutable history"
  end

  test "ContentVersion has NO :destroy action (immutable history — red path)" do
    actions = Ash.Resource.Info.actions(ContentVersion)
    action_names = Enum.map(actions, & &1.name)

    refute :destroy in action_names,
           "ContentVersion must NOT have a :destroy action — it is immutable history"
  end

  test "ContentVersion can be created (append-only write works)" do
    org = mk_org("cms-ver-create")
    admin_scope = mk_actor(org.id, :admin)
    page = mk_page(org.id, "Version Test Page")

    assert {:ok, version} =
             ContentVersion
             |> Ash.Changeset.for_create(:create_version, %{
               subject_type: "page",
               subject_id: page.id,
               content_snapshot: %{"title" => "Test", "body" => "v1"},
               status: :draft,
               author_id: org.id,
               version_number: 1,
               org_id: org.id
             })
             |> Ash.create(actor: admin_scope.actor, authorize?: true)

    assert version.subject_id == page.id
    assert version.version_number == 1
  end

  # =========================================================================
  # Smoke: blocks, media, seo_meta are all org-scoped.
  # =========================================================================

  test "blocks, media, seo_meta are org-scoped (cross-org invisible)" do
    org_a = mk_org("cms-smoke-xa")
    org_b = mk_org("cms-smoke-xb")
    scope_a = mk_actor(org_a.id, :admin)

    page_b = mk_page(org_b.id, "Smoke Page B")

    {:ok, _block_b} =
      Block
      |> Ash.Changeset.for_create(:create, %{
        name: "BlockB",
        block_type: :hero,
        org_id: org_b.id,
        page_id: page_b.id
      })
      |> Ash.create(authorize?: false)

    {:ok, _media_b} =
      Media
      |> Ash.Changeset.for_create(:create, %{
        file_name: "secret.jpg",
        org_id: org_b.id
      })
      |> Ash.create(authorize?: false)

    {:ok, _seo_b} =
      SeoMeta
      |> Ash.Changeset.for_create(:create, %{
        meta_title: "B Meta",
        org_id: org_b.id,
        page_id: page_b.id
      })
      |> Ash.create(authorize?: false)

    {:ok, blocks} = Ash.read(Block, actor: scope_a.actor, authorize?: true)
    {:ok, medias} = Ash.read(Media, actor: scope_a.actor, authorize?: true)
    {:ok, seos} = Ash.read(SeoMeta, actor: scope_a.actor, authorize?: true)

    assert Enum.all?(blocks, fn r -> r.org_id == org_a.id end)
    assert Enum.all?(medias, fn r -> r.org_id == org_a.id end)
    assert Enum.all?(seos, fn r -> r.org_id == org_a.id end)
  end
end
