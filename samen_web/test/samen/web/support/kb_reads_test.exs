defmodule Samen.Web.Support.KbReadsTest do
  @moduledoc """
  T78 (spec §I5 helpdesk knowledge base + composer suggestion + deflection) —
  the `KbReads` read/write layer: the `:kb_namespace` sibling-mount seam, the
  agent-vs-portal read split, and the AI-plane suggestion/deflection honesty
  states (`:ok`/`simulated`, `:empty`, `:not_configured`).
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Support.KbReads
  alias Samen.Web.Mount

  defp support_mount, do: build_mount(:support)


  defp mk_article(kb_mount, scope, org_id, attrs) do
    Mount.resource(kb_mount, Post)
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(%{title: "Untitled", slug: "s-#{System.unique_integer([:positive])}", body: "body", org_id: org_id}, attrs),
      scope: scope
    )
    |> Ash.create!()
  end

  defp publish!(kb_mount, %Samen.Scope{actor: %{org_id: org_id}}, article) do
    {:ok, published} = KbReads.publish_article(kb_mount, org_id, article.id)
    published
  end

  # ---------------------------------------------------------------------------------------
  describe "kb_mount/1 — the :kb_namespace sibling-mount seam" do
    test "nil when the host never wired the label (honest 'not adopted' state)" do
      bare = Mount.new(:support, Samen.WebTest.Support, Samen.WebTest.Repo)
      assert KbReads.kb_mount(bare) == nil
    end

    test "resolves the CMS namespace when :kb_namespace is wired" do
      kb_mount = KbReads.kb_mount(support_mount())
      assert kb_mount.namespace == Samen.WebTest.Cms
      assert kb_mount.scope_kind == :kb
      # repo + plane carry over from the ORIGINATING mount (the flags_mount precedent).
      assert kb_mount.repo == Samen.WebTest.Repo
    end

    test "nil in, nil out" do
      assert KbReads.kb_mount(nil) == nil
    end
  end

  # ---------------------------------------------------------------------------------------
  describe "articles/2 — the agent view sees BOTH internal and public articles" do
    test "an org-scoped agent reads internal + public articles, any status" do
      org_id = Ash.UUID.generate()
      kb_mount = KbReads.kb_mount(support_mount())
      scope = Mount.scope(support_mount(), org_id)

      internal = mk_article(kb_mount, scope, org_id, %{title: "Internal draft", visibility: :internal})
      public = mk_article(kb_mount, scope, org_id, %{title: "Public draft", visibility: :public})

      ids = KbReads.articles(kb_mount, scope) |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == Enum.sort([internal.id, public.id])
    end
  end

  # ---------------------------------------------------------------------------------------
  describe "public_articles/2 — the portal view sees ONLY public+published articles" do
    test "an internal article and a draft public article are both excluded" do
      org_id = Ash.UUID.generate()
      kb_mount = KbReads.kb_mount(support_mount())
      scope = Mount.scope(support_mount(), org_id)

      _internal = mk_article(kb_mount, scope, org_id, %{title: "Internal", visibility: :internal}) |> then(&publish!(kb_mount, scope, &1))
      _draft_public = mk_article(kb_mount, scope, org_id, %{title: "Draft public", visibility: :public})
      published_public = mk_article(kb_mount, scope, org_id, %{title: "Published public", visibility: :public}) |> then(&publish!(kb_mount, scope, &1))

      found = KbReads.public_articles(kb_mount, org_id)
      assert Enum.map(found, & &1.id) == [published_public.id]
    end
  end

  # ---------------------------------------------------------------------------------------
  # Done-criterion 2: composer suggestion — relevant articles surfaced for a ticket, via the
  # fake/deterministic AI-plane fixture (T152's keyless embedder — the ONLY embedder
  # resolved in :test, per Samen.AI.Embeddings' own fail-honest contract).
  describe "suggest_for_agent/4 — composer suggestion (D5/T68 AI-plane path)" do
    test "a semantically-relevant published article ranks first and is signposted simulated" do
      org_id = Ash.UUID.generate()
      kb_mount = KbReads.kb_mount(support_mount())
      scope = Mount.scope(support_mount(), org_id)

      relevant =
        mk_article(kb_mount, scope, org_id, %{
          title: "How to reset your password",
          body: "Reset password steps: go to settings, click reset password, check your email."
        })
        |> then(&publish!(kb_mount, scope, &1))

      _unrelated =
        mk_article(kb_mount, scope, org_id, %{title: "Shipping rates", body: "International shipping rates and customs."})
        |> then(&publish!(kb_mount, scope, &1))

      result = KbReads.suggest_for_agent(kb_mount, scope, "I forgot my password and need to reset it")

      assert result.state == :ok
      # T152 honesty: the keyless deterministic embedder self-declares simulated.
      assert result.simulated == true
      assert [%{article: %{id: id}, snippet: snippet} | _] = result.hits
      assert id == relevant.id
      assert is_binary(snippet) or is_nil(snippet)
    end

    test "an INTERNAL article surfaces for the agent (agents see internal + public)" do
      org_id = Ash.UUID.generate()
      kb_mount = KbReads.kb_mount(support_mount())
      scope = Mount.scope(support_mount(), org_id)

      internal =
        mk_article(kb_mount, scope, org_id, %{
          title: "Internal escalation runbook",
          body: "Escalation runbook: page on-call, open incident channel.",
          visibility: :internal
        })
        |> then(&publish!(kb_mount, scope, &1))

      result = KbReads.suggest_for_agent(kb_mount, scope, "need to escalate an incident, page on-call")

      assert result.state == :ok
      assert Enum.any?(result.hits, &(&1.article.id == internal.id))
    end

    test "no KB namespace wired -> the honest :no_kb_namespace state, never a crash" do
      bare = Mount.new(:support, Samen.WebTest.Support, Samen.WebTest.Repo)
      scope = Mount.scope(bare, Ash.UUID.generate())
      assert KbReads.suggest_for_agent(nil, scope, "anything") == %{state: :no_kb_namespace, hits: []}
      assert KbReads.suggest_for_agent(KbReads.kb_mount(bare), scope, "anything") == %{state: :no_kb_namespace, hits: []}
    end

    test "no matching articles at all -> the honest :empty state (never a match-all default)" do
      org_id = Ash.UUID.generate()
      kb_mount = KbReads.kb_mount(support_mount())
      scope = Mount.scope(support_mount(), org_id)

      assert KbReads.suggest_for_agent(kb_mount, scope, "anything, nothing is indexed yet") == %{state: :empty, hits: []}
    end

    test "AI plane keyless-honest: env forced to :prod -> {:not_configured} with the T152 configuration_hint" do
      org_id = Ash.UUID.generate()
      kb_mount = KbReads.kb_mount(support_mount())
      scope = Mount.scope(support_mount(), org_id)

      result = KbReads.suggest_for_agent(kb_mount, scope, "password reset", env_reader: fn -> :prod end)

      assert result.state == :not_configured
      assert result.hits == []
      assert result.configuration_hint == Samen.AI.configuration_hint()
      refute result.configuration_hint =~ "SIMULATED", "never claim a keyless fallback ran when it did not"
    end
  end

  # ---------------------------------------------------------------------------------------
  # Done-criterion 3: deflection — matching articles pre-submit, and defense in depth: a
  # vector still referencing an article whose visibility flipped internal must NEVER surface.
  describe "suggest_for_portal/4 — deflection (unauthenticated, org_id only)" do
    test "a public+published article surfaces for a matching draft-ticket description" do
      org_id = Ash.UUID.generate()
      kb_mount = KbReads.kb_mount(support_mount())
      scope = Mount.scope(support_mount(), org_id)

      article =
        mk_article(kb_mount, scope, org_id, %{
          title: "How to reset your password",
          body: "Reset password steps: go to settings, click reset password, check your email.",
          visibility: :public
        })
        |> then(&publish!(kb_mount, scope, &1))

      result = KbReads.suggest_for_portal(kb_mount, org_id, "I forgot my password, help me reset it")

      assert result.state == :ok
      assert Enum.any?(result.hits, &(&1.article.id == article.id))
    end

    test "DEFENSE IN DEPTH — an article embedded while public, then flipped to internal, never surfaces on the portal" do
      org_id = Ash.UUID.generate()
      kb_mount = KbReads.kb_mount(support_mount())
      scope = Mount.scope(support_mount(), org_id)

      article =
        mk_article(kb_mount, scope, org_id, %{
          title: "Payroll integration secrets rotation",
          body: "Rotate payroll integration secrets: revoke old key, mint new key, update vault.",
          visibility: :public
        })
        |> then(&publish!(kb_mount, scope, &1))

      # Flip visibility AFTER the vector was stored (the vector is now stale/over-broad —
      # exactly the scenario `read_public` re-verification exists to catch).
      article
      |> Ash.Changeset.for_update(:update, %{visibility: :internal}, scope: scope)
      |> Ash.update!()

      result = KbReads.suggest_for_portal(kb_mount, org_id, "rotate payroll integration secrets")

      refute Enum.any?(result.hits, &(&1.article.id == article.id)),
             "a stale vector for a now-internal article must NEVER surface on the unauthenticated portal"
    end

    test "an INTERNAL article (never public) never surfaces on the portal even if it ranks well" do
      org_id = Ash.UUID.generate()
      kb_mount = KbReads.kb_mount(support_mount())
      scope = Mount.scope(support_mount(), org_id)

      internal =
        mk_article(kb_mount, scope, org_id, %{
          title: "Internal incident runbook",
          body: "Incident runbook: page on-call, open incident channel, notify leadership.",
          visibility: :internal
        })
        |> then(&publish!(kb_mount, scope, &1))

      result = KbReads.suggest_for_portal(kb_mount, org_id, "incident runbook page on-call notify leadership")

      refute Enum.any?(result.hits, &(&1.article.id == internal.id))
    end

    test "ORG-SCOPE PIN — deflection never crosses orgs" do
      org_a = Ash.UUID.generate()
      org_b = Ash.UUID.generate()
      kb_mount = KbReads.kb_mount(support_mount())
      scope_a = Mount.scope(support_mount(), org_a)
      scope_b = Mount.scope(support_mount(), org_b)

      _a =
        mk_article(kb_mount, scope_a, org_a, %{title: "Org A reset password guide", body: "reset password org A", visibility: :public})
        |> then(&publish!(kb_mount, scope_a, &1))

      b =
        mk_article(kb_mount, scope_b, org_b, %{title: "Org B reset password guide", body: "reset password org B", visibility: :public})
        |> then(&publish!(kb_mount, scope_b, &1))

      result = KbReads.suggest_for_portal(kb_mount, org_b, "reset password")

      assert Enum.all?(result.hits, &(&1.article.id == b.id))
    end
  end
end
