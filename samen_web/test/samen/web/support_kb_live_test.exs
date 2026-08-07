defmodule Samen.Web.SupportKbLiveTest do
  @moduledoc """
  T78 (spec §I5 helpdesk knowledge base) — the agent-facing `Samen.Web.Support.KbLive`:
  the `:kb_namespace` honest-not-adopted state, article authoring, and the
  done-criterion 1 CONTROL ("an internal article IS visible to agents").
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Support.KbLive
  alias Samen.Web.Support.KbReads
  alias Samen.Web.Mount

  defp mount_socket(org_id, plane_opts \\ []) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, build_mount(:support, plane_opts))
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> Phoenix.Component.assign(:return_to, nil)
    |> Phoenix.Component.assign(:org_id, org_id)
    |> KbLive.load(org_id)
  end

  defp html(socket), do: render_html(KbLive, socket.assigns)

  defp event(socket, name, params) do
    {:noreply, socket} = KbLive.handle_event(name, params, socket)
    socket
  end

  # ---------------------------------------------------------------------------
  describe "no :kb_namespace wired -> the honest not-set-up state" do
    test "renders the empty state, never a crash" do
      bare_mount = Mount.new(:support, Samen.WebTest.Support, Samen.WebTest.Repo)
      org_id = Ash.UUID.generate()

      socket =
        %Phoenix.LiveView.Socket{}
        |> Phoenix.Component.assign(:samen_mount, bare_mount)
        |> Phoenix.Component.assign(:samen_acting_as, false)
        |> Phoenix.Component.assign(:return_to, nil)
        |> Phoenix.Component.assign(:org_id, org_id)
        |> KbLive.load(org_id)

      rendered = html(socket)
      assert rendered =~ "Knowledge base not set up."
      refute rendered =~ "id=\"new-article\""
    end
  end

  # ---------------------------------------------------------------------------
  describe "empty state + article authoring" do
    test "no articles yet -> the honest empty state" do
      org_id = Ash.UUID.generate()
      socket = mount_socket(org_id)

      assert socket.assigns.articles == []
      assert html(socket) =~ "No articles yet."
    end

    test "creating a new article (default internal) appears in the agent list" do
      org_id = Ash.UUID.generate()
      socket = mount_socket(org_id)

      socket = event(socket, "new_article", %{})
      assert html(socket) =~ ~s(id="new-article-modal")

      socket =
        event(socket, "save_new", %{
          "form" => %{"title" => "Reset your password", "body" => "Go to settings and click reset.", "visibility" => "internal"}
        })

      assert length(socket.assigns.articles) == 1
      [article] = socket.assigns.articles
      assert article.title == "Reset your password"
      assert article.visibility == :internal
      assert article.status == :draft
      assert html(socket) =~ "Reset your password"
    end

    test "RED PATH: an invalid article (blank title) shows inline errors and persists nothing" do
      org_id = Ash.UUID.generate()
      socket = mount_socket(org_id)
      socket = event(socket, "new_article", %{})

      socket = event(socket, "save_new", %{"form" => %{"title" => "", "body" => "no title", "visibility" => "internal"}})

      assert html(socket) =~ "field-invalid"
      assert socket.assigns.articles == []
    end
  end

  # ---------------------------------------------------------------------------
  # Done-criterion 1, CONTROL half: "internal article... visible to agents."
  describe "CONTROL — an internal article is visible to the agent KB view" do
    test "an internal, unpublished article appears in the agent's article list" do
      org_id = Ash.UUID.generate()
      kb_mount = KbReads.kb_mount(build_mount(:support))
      scope = Mount.scope(kb_mount, org_id)

      article =
        Mount.resource(kb_mount, Post)
        |> Ash.Changeset.for_create(:create, %{title: "Internal escalation runbook", body: "…", visibility: :internal, org_id: org_id}, scope: scope)
        |> Ash.create!()

      socket = mount_socket(org_id)
      rendered = html(socket)

      assert Enum.any?(socket.assigns.articles, &(&1.id == article.id))
      assert rendered =~ "Internal escalation runbook"
      assert rendered =~ ~s(id="kb-article-#{article.id}")
    end
  end

  # ---------------------------------------------------------------------------
  describe "publish — admin-gated by the kernel, elevated via KbReads.write_scope/2" do
    test "publishing flips status to :published and reindexes (best-effort)" do
      org_id = Ash.UUID.generate()
      kb_mount = KbReads.kb_mount(build_mount(:support))
      scope = Mount.scope(kb_mount, org_id)

      article =
        Mount.resource(kb_mount, Post)
        |> Ash.Changeset.for_create(:create, %{title: "Draft article", body: "…", visibility: :public, org_id: org_id}, scope: scope)
        |> Ash.create!()

      socket = mount_socket(org_id)
      assert html(socket) =~ ~s(phx-click="publish")

      socket = event(socket, "publish", %{"id" => article.id})

      [published] = socket.assigns.articles
      assert published.status == :published
      assert html(socket) =~ "published"
    end
  end

  # ---------------------------------------------------------------------------
  describe "editing an article" do
    test "edit_article opens the edit modal prefilled, save_edit persists changes" do
      org_id = Ash.UUID.generate()
      kb_mount = KbReads.kb_mount(build_mount(:support))
      scope = Mount.scope(kb_mount, org_id)

      article =
        Mount.resource(kb_mount, Post)
        |> Ash.Changeset.for_create(:create, %{title: "Old title", body: "…", visibility: :internal, org_id: org_id}, scope: scope)
        |> Ash.create!()

      socket = mount_socket(org_id)
      socket = event(socket, "edit_article", %{"id" => article.id})
      assert html(socket) =~ ~s(id="edit-article-modal")

      socket =
        event(socket, "save_edit", %{"form" => %{"title" => "New title", "body" => "updated body", "visibility" => "public"}})

      [updated] = socket.assigns.articles
      assert updated.title == "New title"
      assert updated.visibility == :public
    end
  end
end
