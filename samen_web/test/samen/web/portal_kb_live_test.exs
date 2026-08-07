defmodule Samen.Web.PortalKbLiveTest do
  @moduledoc """
  T78 (spec §I5 helpdesk knowledge base + composer suggestion + deflection) —
  `Samen.Web.Support.PortalKbLive`, the UNAUTHENTICATED tenant portal:

    * Done-criterion 1: "public article visible on portal unauthenticated
      (green); internal article NEVER on portal (red)."
    * Done-criterion 3: "Deflection: portal ticket form surfaces matching
      articles pre-submit."

  Mounted with NO actor/scope at all — the LiveView is driven directly through
  `mount/3`/`load/2`, never `Mount.scope/2` (there is no session to derive one
  from), proving the surface is genuinely reachable unauthenticated.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Support.PortalKbLive
  alias Samen.Web.Support.KbReads
  alias Samen.Web.Mount

  defp portal_mount, do: build_mount(:kb)

  defp mk_article(org_id, attrs) do
    kb_mount = portal_mount()
    scope = Mount.scope(kb_mount, org_id)

    Mount.resource(kb_mount, Post)
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(%{title: "Untitled", slug: "s-#{System.unique_integer([:positive])}", body: "body", org_id: org_id}, attrs),
      scope: scope
    )
    |> Ash.create!()
  end

  defp publish!(org_id, article) do
    {:ok, published} = KbReads.publish_article(portal_mount(), org_id, article.id)
    published
  end

  defp mount_socket(org_id) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, portal_mount())
    |> PortalKbLive.load(org_id)
  end

  defp html(socket), do: render_html(PortalKbLive, socket.assigns)

  defp event(socket, name, params) do
    {:noreply, socket} = PortalKbLive.handle_event(name, params, socket)
    socket
  end

  # ---------------------------------------------------------------------------
  describe "GREEN — a public+published article is visible on the portal unauthenticated" do
    test "the article renders in the browse list with NO actor/scope at all" do
      org_id = Ash.UUID.generate()
      article = mk_article(org_id, %{title: "How to reset your password", body: "Go to settings, click reset.", visibility: :public}) |> then(&publish!(org_id, &1))

      socket = mount_socket(org_id)
      rendered = html(socket)

      assert Enum.any?(socket.assigns.articles, &(&1.id == article.id))
      assert rendered =~ "How to reset your password"
      assert rendered =~ ~s(id="portal-article-#{article.id}")
    end
  end

  # ---------------------------------------------------------------------------
  describe "RED — an internal article NEVER appears on the portal" do
    test "a published but INTERNAL article is absent from the browse list" do
      org_id = Ash.UUID.generate()
      internal = mk_article(org_id, %{title: "Internal runbook: incident response", visibility: :internal}) |> then(&publish!(org_id, &1))

      socket = mount_socket(org_id)
      rendered = html(socket)

      refute Enum.any?(socket.assigns.articles, &(&1.id == internal.id))
      refute rendered =~ "Internal runbook: incident response"
    end

    test "no org param at all -> the honest empty state, never a crash" do
      socket = mount_socket(nil)
      assert html(socket) =~ "No organization specified."
    end
  end

  # ---------------------------------------------------------------------------
  # Done-criterion 3: deflection — pre-submit article matches on the draft ticket form.
  describe "Deflection — the portal ticket form surfaces matching articles pre-submit" do
    test "typing a matching subject/description surfaces the relevant article BEFORE any submit" do
      org_id = Ash.UUID.generate()
      article =
        mk_article(org_id, %{title: "How to reset your password", body: "Reset steps: settings, click reset password, check email.", visibility: :public})
        |> then(&publish!(org_id, &1))

      socket = mount_socket(org_id)
      refute html(socket) =~ ~s(id="deflect-suggestions")

      socket =
        event(socket, "deflect", %{"deflect" => %{"subject" => "forgot password", "description" => "need to reset it"}})

      rendered = html(socket)
      assert socket.assigns.suggestion.state == :ok
      assert rendered =~ ~s(id="deflect-suggestions")
      assert rendered =~ article.title
      assert rendered =~ ~s(id="deflect-simulated-badge")
      assert rendered =~ "Sign in"
    end

    test "no match -> the honest empty deflection state (never a fabricated suggestion)" do
      org_id = Ash.UUID.generate()

      socket = mount_socket(org_id)
      socket = event(socket, "deflect", %{"deflect" => %{"subject" => "completely unrelated topic zzz", "description" => ""}})

      assert socket.assigns.suggestion.state == :empty
      assert html(socket) =~ "No matching help articles found"
    end

    test "an internal article never surfaces in deflection even if it would rank well" do
      org_id = Ash.UUID.generate()
      internal =
        mk_article(org_id, %{title: "Internal payroll rotation runbook", body: "rotate payroll secrets: revoke, mint, update", visibility: :internal})
        |> then(&publish!(org_id, &1))

      socket = mount_socket(org_id)
      socket = event(socket, "deflect", %{"deflect" => %{"subject" => "rotate payroll secrets", "description" => "revoke mint update"}})

      refute html(socket) =~ internal.title
    end

    test "AI plane keyless-honest: forcing :not_configured renders the honest not-configured panel" do
      org_id = Ash.UUID.generate()
      _article = mk_article(org_id, %{title: "Matches nothing important", body: "reset password", visibility: :public}) |> then(&publish!(org_id, &1))

      socket = mount_socket(org_id)
      kb_mount = socket.assigns.kb_mount
      not_configured = KbReads.suggest_for_portal(kb_mount, org_id, "reset password", env_reader: fn -> :prod end)
      socket = Phoenix.Component.assign(socket, :suggestion, not_configured)

      rendered = html(socket)
      assert not_configured.state == :not_configured
      assert rendered =~ ~s(id="deflect-not-configured")
      refute rendered =~ "SIMULATED"
    end

    test "blank subject/description clears the suggestion panel" do
      org_id = Ash.UUID.generate()
      socket = mount_socket(org_id)
      socket = event(socket, "deflect", %{"deflect" => %{"subject" => "", "description" => ""}})

      assert socket.assigns.suggestion == nil
      refute html(socket) =~ ~s(id="deflect-suggestions")
    end
  end

  # ---------------------------------------------------------------------------
  # ORG-SCOPE PIN — the T74-T77 discipline, applied to the new unauthenticated read.
  describe "ORG-SCOPE PIN — the portal never crosses orgs" do
    test "org A's portal never shows org B's public article, browse OR deflect" do
      org_a = Ash.UUID.generate()
      org_b = Ash.UUID.generate()

      _a = mk_article(org_a, %{title: "Org A password help", body: "reset password org A", visibility: :public}) |> then(&publish!(org_a, &1))
      b = mk_article(org_b, %{title: "Org B password help", body: "reset password org B", visibility: :public}) |> then(&publish!(org_b, &1))

      socket = mount_socket(org_a)
      refute Enum.any?(socket.assigns.articles, &(&1.id == b.id))

      socket = event(socket, "deflect", %{"deflect" => %{"subject" => "reset password", "description" => ""}})
      refute html(socket) =~ "Org B password help"
    end
  end
end
