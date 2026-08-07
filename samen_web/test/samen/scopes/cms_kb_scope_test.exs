defmodule Samen.Scopes.CmsKbScopeTest do
  @moduledoc """
  T78 (spec §I5 helpdesk knowledge base + composer suggestion + deflection) —
  the resource-level proof that `Samen.WebTest.Cms.Post` doubles as the KB
  article (no parallel article resource): the `visibility` attribute + the
  `:read_public` action are the ENTIRE delta.

  Done-criterion 1: "KB tests: public article visible on portal unauthenticated;
  internal article NEVER on portal (red) but visible to agents (control)."
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.WebTest.Cms.Post

  require Ash.Query

  defp mk_post(org_id, attrs) do
    Post
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{title: "Untitled", slug: "s-#{System.unique_integer([:positive])}", body: "body", org_id: org_id},
        attrs
      )
    )
    |> Ash.create!(authorize?: false)
  end

  defp publish!(post) do
    post
    |> Ash.Changeset.for_update(:publish, %{})
    |> Ash.update!(authorize?: false)
  end

  defp agent_scope(org_id), do: %Samen.Scope{actor: %{id: "a", org_id: org_id, role: :member, kind: :tenant, plane: :tenant}}

  defp read_public(org_id) do
    Post
    |> Ash.Query.for_read(:read_public, %{org_id: org_id})
    |> Ash.read!(actor: nil, authorize?: true)
  end

  # ---------------------------------------------------------------------------------------
  describe "CMS reuse probe — the KB article IS Cms.Post, no parallel resource" do
    test "no Article/KnowledgeBase/KbArticle resource exists anywhere in the compiled tree" do
      refute Code.ensure_loaded?(Samen.WebTest.Cms.Article)
      refute Code.ensure_loaded?(Samen.WebTest.Cms.KbArticle)
      refute Code.ensure_loaded?(Samen.WebTest.Cms.KnowledgeBaseArticle)
    end

    test "Post carries the visibility attribute + the read_public action" do
      assert Ash.Resource.Info.attribute(Post, :visibility)
      assert Ash.Resource.Info.action(Post, :read_public)
    end

    test "Post is embeddable on :title/:body (the AI-plane retrieval seam)" do
      assert Post.embeddable_fields() == [:body, :title] or Post.embeddable_fields() == [:title, :body]
    end
  end

  # ---------------------------------------------------------------------------------------
  describe "GREEN — a public+published article is visible on the portal unauthenticated" do
    test "read_public returns a public, published article with no actor at all" do
      org_id = Ash.UUID.generate()

      post =
        mk_post(org_id, %{title: "How to reset your password", visibility: :public})
        |> publish!()

      [found] = read_public(org_id)
      assert found.id == post.id
      assert found.visibility == :public
      assert found.status == :published
    end
  end

  # ---------------------------------------------------------------------------------------
  describe "RED — an internal article NEVER appears on the portal, even published" do
    test "a published but INTERNAL article is invisible to read_public" do
      org_id = Ash.UUID.generate()
      _internal = mk_post(org_id, %{title: "Internal runbook: incident response", visibility: :internal}) |> publish!()

      assert read_public(org_id) == []
    end

    test "a public but UNPUBLISHED (draft) article is invisible to read_public" do
      org_id = Ash.UUID.generate()
      _draft = mk_post(org_id, %{title: "Draft public article", visibility: :public})

      assert read_public(org_id) == []
    end
  end

  # ---------------------------------------------------------------------------------------
  describe "CONTROL — an internal article IS visible to an agent (default org-scoped :read)" do
    test "an internal article is readable by an org-scoped agent actor via the default :read" do
      org_id = Ash.UUID.generate()
      internal = mk_post(org_id, %{title: "Internal runbook", visibility: :internal}) |> publish!()

      rows =
        Post
        |> Ash.Query.filter(id == ^internal.id)
        |> Ash.read!(scope: agent_scope(org_id))

      assert [%{id: id, visibility: :internal}] = rows
      assert id == internal.id
    end

    test "an agent sees BOTH internal and public articles in the org (unlike the portal)" do
      org_id = Ash.UUID.generate()
      internal = mk_post(org_id, %{title: "Internal one", visibility: :internal}) |> publish!()
      public_one = mk_post(org_id, %{title: "Public one", visibility: :public}) |> publish!()

      ids =
        Post
        |> Ash.Query.filter(org_id == ^org_id)
        |> Ash.read!(scope: agent_scope(org_id))
        |> Enum.map(& &1.id)
        |> Enum.sort()

      assert ids == Enum.sort([internal.id, public_one.id])
    end
  end

  # ---------------------------------------------------------------------------------------
  # The T74-T77 lesson: every new read gets a two-org pin test — "drop the filter must flip
  # a named test". This is that pin: org B's public+published article must NEVER appear in
  # org A's portal read, and org A's own public+published article must (positive control).
  describe "ORG-SCOPE PIN — read_public never crosses orgs (drop-the-filter-must-flip proof)" do
    test "org A's portal read shows ONLY org A's public article, never org B's" do
      org_a = Ash.UUID.generate()
      org_b = Ash.UUID.generate()

      post_a = mk_post(org_a, %{title: "Org A help article", visibility: :public}) |> publish!()
      _post_b = mk_post(org_b, %{title: "Org B help article", visibility: :public}) |> publish!()

      [found] = read_public(org_a)
      assert found.id == post_a.id
      refute found.title == "Org B help article"
    end

    test "org B's portal read shows its OWN article, not org A's (both sides proven live)" do
      org_a = Ash.UUID.generate()
      org_b = Ash.UUID.generate()

      _post_a = mk_post(org_a, %{title: "Org A help article", visibility: :public}) |> publish!()
      post_b = mk_post(org_b, %{title: "Org B help article", visibility: :public}) |> publish!()

      [found] = read_public(org_b)
      assert found.id == post_b.id
    end
  end
end
