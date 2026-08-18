defmodule Samen.Scopes.ChatSearchMaskingTest do
  @moduledoc """
  T61 / C7 (B) — FULL-HISTORY CHAT SEARCH, PII-MASKED (the crux security surface).

  Chat message `body` is VAULT-ROUTED 🔒 PII. `Samen.Scopes.Chat.Search.query/4` resolves
  every candidate on the actor's plane FIRST and matches the term ONLY over the body the
  actor was authorized to read — so MATCH AUTHORITY == READ AUTHORITY. This test proves,
  sabotage-refutably:

    * **Org-scope** — a 2-org seed; org B's messages NEVER appear in org A's results.
    * **Masked results + NO match-oracle** — an operator-WITHOUT-grant matches ZERO
      vaulted bodies: no plaintext, no `vt_*`, and searching for a substring that IS
      present is INDISTINGUISHABLE from one that is NOT (both `[]`) — no presence oracle.
    * **Tenant / operator-WITH-grant** — resolve appropriately and get a plaintext snippet
      (they were already authorized to READ the body).
    * **Bounded** — `:limit`-capped, no unbounded scan.
    * **Stored-XSS-safe** — attacker chat content is inert in the rendered results list.
    * **Index-content probe** — the vaulted body can NEVER be registered into a tsvector
      search index as plaintext (`SearchIndexGuard`).
  """
  use Samen.WebTest.DataCase, async: false
  use Samen.MaskingCase

  alias Samen.Api.PiiResolution
  alias Samen.Scopes.Chat.Search
  alias Samen.Scopes.Chat.Search.Hit
  alias Samen.Scopes.Chat.SearchComponents
  alias Samen.Scopes.Primitives.SearchIndexGuard
  alias Samen.WebTest.Chat.ChatMessage

  @sentinel "CHAT-BODY-SENTINEL"
  @repo Samen.WebTest.Repo

  defmodule AllowAllGrant do
    @moduledoc false
    def granted?(_ctx), do: true
  end

  # -- scopes ------------------------------------------------------------------

  defp tenant_scope(org_id), do: Samen.Web.Plane.scope(Samen.Web.Plane.tenant(), org_id)

  defp operator_scope(org_id),
    do: Samen.Web.Plane.scope(Samen.Web.Plane.operator("op-1", org_id, "chat-search-session"), org_id)

  defp search(scope, term, opts \\ []),
    do: Search.query(scope, ChatMessage, term, Keyword.merge([repo: @repo], opts))

  defp add_message(chat, org_id, body) do
    ChatMessage
    |> Ash.Changeset.for_create(:create, %{
      org_id: org_id,
      thread_id: chat.thread.id,
      participant_id: chat.tenant_participant.id,
      sender_party: :tenant,
      kind: :message,
      body: body
    })
    |> Ash.create!(authorize?: false)
  end

  defp render_results(hits) do
    %{hits: hits, __changed__: %{}}
    |> SearchComponents.search_results()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  # ==========================================================================
  # Org-scope (2-org — non-negotiable)
  # ==========================================================================

  describe "org-scope (org B never in org A's results)" do
    test "a tenant search sees ONLY its own org's messages" do
      org_a = Ash.UUID.generate()
      org_b = Ash.UUID.generate()
      chat_a = Seeds.seed_chat(org_a)
      chat_b = Seeds.seed_chat(org_b)

      hits_a = search(tenant_scope(org_a), @sentinel)

      # Non-vacuous: org A finds its own message.
      assert hits_a != []
      ids_a = Enum.map(hits_a, & &1.id)

      # Org B's message is NEVER in org A's results (OrgScope, by construction).
      refute chat_b.message.id in ids_a
      assert chat_a.message.id in ids_a

      # POSITIVE CONTROL: org B finds its OWN message (proves it is searchable at all).
      hits_b = search(tenant_scope(org_b), @sentinel)
      assert chat_b.message.id in Enum.map(hits_b, & &1.id)
    end
  end

  # ==========================================================================
  # Masked results + match-oracle prevention (RED)
  # ==========================================================================

  describe "masked results + NO match-oracle (RP: vaulted-body search)" do
    test "GREEN: a tenant search of its own org returns a plaintext snippet" do
      org_id = Ash.UUID.generate()
      Seeds.seed_chat(org_id)

      assert [%Hit{} = hit | _] = search(tenant_scope(org_id), @sentinel)
      assert hit.snippet =~ @sentinel
      refute hit.snippet =~ "vt_"
    end

    test "RED: an operator-WITHOUT-grant matches ZERO vaulted bodies (no hit, no leak)" do
      org_id = Ash.UUID.generate()
      Seeds.seed_chat(org_id)

      # The SAME term the tenant matched — the operator gets nothing (the body resolves
      # to %Masked{} → unmatchable). No plaintext, no snippet, no vt_ token.
      assert [] = search(operator_scope(org_id), @sentinel)

      html = render_results(search(operator_scope(org_id), @sentinel))
      refute html =~ @sentinel
      refute html =~ "vt_"
      assert html =~ "No matching messages."
    end

    test "MATCH-ORACLE: present vs absent substring are INDISTINGUISHABLE for a no-grant operator" do
      org_id = Ash.UUID.generate()
      Seeds.seed_chat(org_id)
      # A distinctive PII-like needle actually present in a vaulted body.
      chat = Seeds.seed_chat(org_id)
      add_message(chat, org_id, "SSN on file: 123-45-6789 for the account.")

      op = operator_scope(org_id)

      # Present substring → [] ; absent substring → [] — no presence/absence oracle.
      assert [] = search(op, "123-45-6789")
      assert [] = search(op, "999-99-9999")

      # ANTI-TAUTOLOGY: the TENANT (authorized) DOES find the present one — so the
      # operator's [] is the PLANE's doing, not the term being absent from the data.
      assert search(tenant_scope(org_id), "123-45-6789") != []
      assert search(tenant_scope(org_id), "999-99-9999") == []
    end

    test "operator-WITH-grant resolves appropriately (authorized to read ⇒ authorized to match)" do
      org_id = Ash.UUID.generate()
      Seeds.seed_chat(org_id)

      assert [%Hit{} = hit | _] =
               search(operator_scope(org_id), @sentinel, grant: AllowAllGrant)

      assert hit.snippet =~ @sentinel
    end

    test "SABOTAGE refutability: the tenant-plane plaintext a projection-bypass would leak IS present" do
      # Model the leak the resolve-on-plane match prevents: a match run over the
      # tenant-plane plaintext (what a bypass would ship to an operator) DOES carry the
      # sentinel — so the operator's [] above is a real refutation, not a vacuous one.
      raw = %{body: "#{@sentinel} leaked to operator"}
      leaked = [raw] |> PiiResolution.resolve(ChatMessage, %{plane: :tenant}, repo: @repo) |> hd()
      assert leaked.body =~ @sentinel
    end
  end

  # ==========================================================================
  # Bounded
  # ==========================================================================

  describe "bounded results (Reads discipline)" do
    test "results are :limit-capped" do
      org_id = Ash.UUID.generate()
      chat = Seeds.seed_chat(org_id)
      for i <- 1..6, do: add_message(chat, org_id, "BOUNDNEEDLE message number #{i}")

      hits = search(tenant_scope(org_id), "BOUNDNEEDLE", limit: 2)
      assert length(hits) == 2
    end
  end

  # ==========================================================================
  # Stored-XSS-safe result rendering
  # ==========================================================================

  describe "stored-XSS-safe snippets" do
    test "attacker chat content is INERT in the rendered results list" do
      org_id = Ash.UUID.generate()
      chat = Seeds.seed_chat(org_id)
      add_message(chat, org_id, "<script>alert('xss')</script> XSSNEEDLE9 payload")

      assert [%Hit{} = hit | _] = search(tenant_scope(org_id), "XSSNEEDLE9")
      html = render_results([hit])

      # The snippet carries the (authorized) plaintext, but the markup is ESCAPED.
      assert html =~ "XSSNEEDLE9"
      refute html =~ "<script>alert"
      assert html =~ "&lt;script&gt;"
    end
  end

  # ==========================================================================
  # Index-content probe — the vaulted body is NEVER indexed as plaintext
  # ==========================================================================

  describe "index-content probe (search never indexes vaulted plaintext)" do
    test "registering the vaulted body column into a search index is REFUSED" do
      # The vaulted body can never enter a tsvector index as plaintext — the guard raises.
      assert_raise ArgumentError, fn ->
        SearchIndexGuard.assert_no_pii_column(ChatMessage, "body")
      end

      # POSITIVE CONTROL: a non-PII column is allowed (proves the guard is discriminating).
      assert :ok = SearchIndexGuard.assert_no_pii_column(ChatMessage, "kind")
    end
  end
end
