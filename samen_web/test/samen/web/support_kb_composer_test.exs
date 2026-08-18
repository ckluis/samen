defmodule Samen.Web.SupportKbComposerTest do
  @moduledoc """
  T78 (spec §I5 helpdesk knowledge base + composer suggestion + deflection) —
  done-criterion 2: "Composer suggestion: relevant articles surfaced for a
  ticket (via D5/T68 path, fake provider fixture); insertion into reply works
  (test)."

  The "fake provider fixture" IS the AI plane's own keyless CI lane
  (`Samen.AI.Embedder.Deterministic`, T152) — the ONLY embedder `:test`
  resolves to (`Samen.AI.Embeddings.embedder_for/1`), so these are real,
  non-mocked assertions against the shipped fail-honest substrate.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Support.TicketLive
  alias Samen.Web.Support.KbReads
  alias Samen.Web.Mount

  defp mount_socket(org_id, ticket_id, plane_opts \\ []) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, build_mount(:support, plane_opts))
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> Phoenix.Component.assign(:return_to, nil)
    |> Phoenix.Component.assign(:org_id, org_id)
    |> Phoenix.Component.assign(:ticket_id, ticket_id)
    |> Phoenix.Component.assign(:active_tab, "conversation")
    |> TicketLive.load(org_id, ticket_id)
  end

  defp html(socket), do: render_html(TicketLive, socket.assigns)

  defp event(socket, name, params) do
    {:noreply, socket} = TicketLive.handle_event(name, params, socket)
    socket
  end

  defp seed_matching_article(org_id) do
    kb_mount = KbReads.kb_mount(build_mount(:support))
    scope = Mount.scope(kb_mount, org_id)

    article =
      Mount.resource(kb_mount, Post)
      |> Ash.Changeset.for_create(
        :create,
        %{
          title: "Rate confirmation FAQ",
          slug: "rate-confirmation-faq-#{System.unique_integer([:positive])}",
          body: "Rate confirmation documents: resend from the load detail page, under Documents.",
          org_id: org_id
        },
        scope: scope
      )
      |> Ash.create!()

    {:ok, published} = KbReads.publish_article(kb_mount, org_id, article.id)
    published
  end

  # ---------------------------------------------------------------------------
  describe "composer suggestion — relevant articles surfaced for a ticket" do
    test "a semantically-relevant published article renders in the suggestion panel, signposted SIMULATED" do
      %{org_id: org_id, support: %{ticket: ticket}} = Seeds.seed_all()
      article = seed_matching_article(org_id)

      socket = mount_socket(org_id, ticket.id)
      rendered = html(socket)

      assert socket.assigns.kb_suggestion.state == :ok
      assert socket.assigns.kb_suggestion.simulated == true
      assert rendered =~ ~s(id="kb-suggestion-panel")
      assert rendered =~ ~s(id="kb-suggestion-simulated-badge")
      assert rendered =~ "SIMULATED"
      assert rendered =~ article.title
      assert rendered =~ ~s(id="kb-suggestion-#{article.id}")
      assert rendered =~ ~s(phx-click="insert_suggestion")
    end

    test "no matching articles indexed yet -> the panel renders nothing (honest empty, not an error)" do
      %{org_id: org_id, support: %{ticket: ticket}} = Seeds.seed_all()
      socket = mount_socket(org_id, ticket.id)

      assert socket.assigns.kb_suggestion.state == :empty
      refute html(socket) =~ ~s(id="kb-suggestion-panel")
    end

    test "AI plane keyless-honest: env forced to :prod -> :not_configured panel with configuration_hint" do
      %{org_id: org_id, support: %{ticket: ticket}} = Seeds.seed_all()
      _article = seed_matching_article(org_id)

      socket = mount_socket(org_id, ticket.id)

      # `load/3` doesn't accept opts, so force the honest not-configured state directly
      # through the SAME KbReads seam the LiveView calls, proving the panel renders it.
      scope = Mount.scope(socket.assigns.samen_mount, org_id)
      kb_mount = KbReads.kb_mount(socket.assigns.samen_mount)
      not_configured = KbReads.suggest_for_agent(kb_mount, scope, ticket.subject, env_reader: fn -> :prod end)
      socket = Phoenix.Component.assign(socket, :kb_suggestion, not_configured)

      rendered = html(socket)
      assert not_configured.state == :not_configured
      assert rendered =~ ~s(id="kb-suggestion-not-configured")
      # The full hint round-trips through HEEx HTML-escaping (its embedded double
      # quotes become `&quot;`), so assert on a quote-free substring instead.
      assert rendered =~ "No AI provider is wired"
      assert rendered =~ "mix samen.ai.smoke"
      refute rendered =~ "SIMULATED"
    end
  end

  # ---------------------------------------------------------------------------
  describe "insertion into reply works" do
    test "clicking Insert appends the suggested article's title + snippet to the draft reply body" do
      %{org_id: org_id, support: %{ticket: ticket, conversation: conversation}} = Seeds.seed_all()
      article = seed_matching_article(org_id)

      socket = mount_socket(org_id, ticket.id)
      assert socket.assigns.kb_suggestion.state == :ok

      # Agent has already started typing a reply.
      socket = event(socket, "validate_reply", %{"form" => %{"body" => "Hi there,", "message_type" => "reply"}})
      assert AshPhoenix.Form.value(socket.assigns.reply_form, :body) == "Hi there,"

      socket = event(socket, "insert_suggestion", %{"article_id" => to_string(article.id)})

      new_body = AshPhoenix.Form.value(socket.assigns.reply_form, :body)
      assert new_body =~ "Hi there,"
      assert new_body =~ article.title
      assert new_body =~ "Rate confirmation documents"

      # The inserted draft actually SUBMITS through the real write path (MC-2 — the
      # vaulted body still routes through Samen.Vault.Change on send).
      before_count =
        Samen.WebTest.Support.Message
        |> Ash.Query.ensure_selected([:conversation_id])
        |> Ash.read!(authorize?: false)
        |> Enum.count(&(&1.conversation_id == conversation.id))

      socket = event(socket, "save_reply", %{"form" => %{"body" => new_body, "message_type" => "reply"}})

      after_count =
        Samen.WebTest.Support.Message
        |> Ash.Query.ensure_selected([:conversation_id])
        |> Ash.read!(authorize?: false)
        |> Enum.count(&(&1.conversation_id == conversation.id))

      assert after_count == before_count + 1
      assert html(socket) =~ article.title
    end

    test "insert_suggestion with an unknown article_id is a safe no-op" do
      %{org_id: org_id, support: %{ticket: ticket}} = Seeds.seed_all()
      _article = seed_matching_article(org_id)

      socket = mount_socket(org_id, ticket.id)
      socket = event(socket, "validate_reply", %{"form" => %{"body" => "unchanged", "message_type" => "reply"}})

      socket = event(socket, "insert_suggestion", %{"article_id" => Ash.UUID.generate()})

      assert AshPhoenix.Form.value(socket.assigns.reply_form, :body) == "unchanged"
    end
  end
end
