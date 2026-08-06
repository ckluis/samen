defmodule Samen.AI.EmbeddingsTest do
  @moduledoc """
  RP-AI-4 (no PII in vector space) + RP-AI-5 (org isolation) — the D3 semantic-search plane
  (ADR-043 §7, T67), the permanent red-team for the embeddings egress class (EG3). Every
  refutation is paired with a non-vacuous positive control (the `Samen.MaskingCase` / anti-
  tautology discipline): a legitimately-declared non-PII field DOES embed + rank, so the
  refusals are proven to be the gate, not a blanket failure.

  ## The proofs

    * **positive control** — a resource's DECLARED non-PII `:body` field embeds through the
      keyless deterministic embedder, stores an org-scoped vector, and semantic search finds it
      (the matching document ranks first). Non-vacuous by construction.
    * **RP-AI-4 / §7.2 deny-by-default** — a vault-routed (🔒) field is NEVER embeddable, even
      with a (grant-resolved) PLAINTEXT value: grants never unlock embedding (a vector persists
      beyond any grant window and is invertible). Refused fail-closed at the plane guard; the
      chokepoint refuses a masked / `vt_*` value at the value layer; no plaintext / `vt_*` token
      ever reaches the embedder or the `aie_embedding` store. **This is the sabotage target.**
    * **RP-AI-5 org isolation** — semantic search from org A never returns (never even ranks)
      org B's vectors, with the same-org positive control.
    * **compile-time (non-vacuous)** — the `Samen.Verifiers.EmbeddableNoPii` detection flags a
      🔒 field and passes a clean one (a `use Samen.Resource, embeddable: [🔒]` resource cannot
      compile, so the compile-fail itself is the `TntBoundary` scratch-probe idiom).
    * **seam binding** — `Article.embeddable_fields/0` is the DSL-injected seam the
      `ai_prompt_masking` verifier (b) reads; it returns the real declaration and is GREEN for a
      non-PII field.

  Sabotage-refutable: `scripts/sabotages/48-t67-ai-embeddings-vault-embed-deny-bypass.patch`
  drops the plane's vault-routed deny, and the named §7.2 test flips (the canary embeds).
  """
  use ExUnit.Case, async: false

  alias Samen.AI.{Chokepoint, Embedder, Embeddings, Provider}
  alias Samen.Masked
  alias SamenCore.TestRepo
  alias SamenCore.Support.EmbeddingsDomain.Article
  alias SamenCore.Support.RevealDomain.RevealPerson
  alias Mix.Tasks.Samen.Verify.AiPromptMasking, as: V

  # A unique PII canary — the plaintext a grant might resolve for a vault field. If it ever
  # appears in the vector store, that is the exact §7.2 leak (a permanent, invertible vector).
  @canary "canary-embed-7q6w5e@leak.example"
  @vt_token "vt_" <> String.duplicate("a", 32)

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})
    Provider.Fake.reset()
    :ok
  end

  defp scope(org_id) do
    %Samen.Scope{actor: %{id: "u:#{org_id}", org_id: org_id, role: :member, plane: :tenant}}
  end

  defp article(body, id \\ Ash.UUID.generate()), do: struct(Article, id: id, body: body)

  defp opts, do: [repo: TestRepo]

  # Every text column of every aie_embedding row, joined — a raw scan for a leaked canary/token.
  # Includes `aie_snippet` (T152) so a leak into the self-describing Hit snippet is caught too.
  defp store_dump do
    {:ok, %{rows: rows}} =
      TestRepo.query(
        "SELECT aie_source_resource, aie_source_id, aie_field, aie_snippet, aie_embedding::text FROM aie_embedding",
        []
      )

    rows |> List.flatten() |> Enum.map_join(" ", &to_string/1)
  end

  defp row_count(org_id) do
    {:ok, %{rows: [[n]]}} =
      TestRepo.query("SELECT count(*) FROM aie_embedding WHERE aie_org_id = $1::text::uuid", [org_id])

    n
  end

  # ---------------------------------------------------------------------------------------
  describe "positive control — a declared non-PII field embeds and is searchable" do
    test "embed_record embeds :body and semantic search ranks the matching document first" do
      org = Ash.UUID.generate()
      s = scope(org)

      fox = article("the quick brown fox jumps over the lazy dog")
      bill = article("quarterly billing invoices and payment reconciliation reports")

      assert {:ok, 1} = Embeddings.embed_record(s, fox, Article, opts())
      assert {:ok, 1} = Embeddings.embed_record(s, bill, Article, opts())

      assert {:ok, hits} = Embeddings.search(s, "quick brown fox", opts())
      assert [%Embeddings.Hit{} = top | _] = hits
      # The fox document is the nearest neighbor (non-vacuous ranking-shape).
      assert top.source_id == fox.id
      assert top.field == "body"
      assert top.source_resource == inspect(Article)

      # And the billing doc is strictly farther (the query really discriminates).
      bill_hit = Enum.find(hits, &(&1.source_id == bill.id))
      assert bill_hit == nil or bill_hit.distance > top.distance
    end

    test "the Hit carries a self-describing text snippet of the matched field (T152)" do
      org = Ash.UUID.generate()
      s = scope(org)

      fox = article("the quick brown fox jumps over the lazy dog")
      assert {:ok, 1} = Embeddings.embed_record(s, fox, Article, opts())

      assert {:ok, [%Embeddings.Hit{} = top | _]} = Embeddings.search(s, "quick brown fox", opts())
      # Self-describing: the caller sees WHAT matched without a second fetch.
      assert is_binary(top.snippet)
      assert top.snippet =~ "quick brown fox"
    end

    test "the snippet is masking-safe: no vt_ token, no canary plaintext in the store (T152)" do
      org = Ash.UUID.generate()
      s = scope(org)

      # Embedded fields are non-vault by deny-by-default, so a snippet carries only non-PII
      # text — but PROVE it: even a body that tries to smuggle a token / canary through the
      # non-vault field never surfaces a vt_ token in the snippet (snippet_of/1 drops it), and
      # the full store scan (now incl. aie_snippet) is clean.
      assert {:ok, 1} =
               Embeddings.embed_record(s, article("clean non-pii body text about invoices"), Article, opts())

      assert {:ok, [%Embeddings.Hit{snippet: snippet} | _]} =
               Embeddings.search(s, "invoices", opts())

      refute snippet =~ "vt_"
      refute snippet =~ @canary

      dump = store_dump()
      refute dump =~ "vt_", "a vault token must never reach the snippet/vector store"
      refute dump =~ @canary, "the 🔒 canary must never reach the snippet/vector store"
    end

    test "embeddable_fields/0 is the DSL-injected seam and the verifier (b) is GREEN for it" do
      assert Article.embeddable_fields() == [:body]
      assert Samen.Info.embeddable_fields(Article) == [:body]
      # A non-PII declared field is no (b) violation — the seam binds to a real declaration.
      assert V.embeddable_vault_violations([Article]) == []
    end
  end

  # ---------------------------------------------------------------------------------------
  describe "RP-AI-5 — semantic search is org-scoped (org A's vectors never surface for org B)" do
    test "cross-org search returns nothing for the foreign org, with the same-org control" do
      org_a = Ash.UUID.generate()
      org_b = Ash.UUID.generate()

      a_doc = article("the quick brown fox jumps over the lazy dog")
      assert {:ok, 1} = Embeddings.embed_record(scope(org_a), a_doc, Article, opts())

      # Positive control: org A finds its own document.
      assert {:ok, [%Embeddings.Hit{source_id: sid} | _]} =
               Embeddings.search(scope(org_a), "quick brown fox", opts())

      assert sid == a_doc.id

      # RP-AI-5: org B — with the SAME query — sees nothing (the row does not exist for it).
      assert {:ok, []} = Embeddings.search(scope(org_b), "quick brown fox", opts())
    end
  end

  # ---------------------------------------------------------------------------------------
  describe "RP-AI-4 / §7.2 — a vault-routed field is NEVER embeddable (grants never unlock it)" do
    # THE SABOTAGE TARGET (scripts/sabotages/48). RevealPerson (laundering-)declares its
    # vault-routed :emails field embeddable, and here we pass a grant-resolved PLAINTEXT value —
    # the strongest §7.2 case. It MUST refuse fail-closed and store NO vector: a vector outlives
    # any grant and is invertible. Dropping the plane's vault-routed deny flips this test (the
    # canary embeds into vector space — the permanent leak §7.2 forbids).
    test "a vault-routed field with a grant-resolved plaintext value is refused, nothing stored" do
      org = Ash.UUID.generate()
      s = scope(org)
      id = Ash.UUID.generate()

      before = row_count(org)

      assert {:error, :field_not_embeddable} =
               Embeddings.embed_field(s, RevealPerson, id, :emails, @canary, opts())

      # No vector row was written, and the canary plaintext is nowhere in the store.
      assert row_count(org) == before
      refute store_dump() =~ @canary
    end

    test "only DECLARED embeddable fields embed — an undeclared field is refused" do
      s = scope(Ash.UUID.generate())
      id = Ash.UUID.generate()
      # :title is a real non-PII attribute of Article but is NOT declared embeddable.
      assert {:error, :field_not_embeddable} =
               Embeddings.embed_field(s, Article, id, :title, "just a title", opts())
    end

    test "the chokepoint refuses a masked / vt_* embed value fail-closed; embedder never called" do
      Provider.Fake.reset()

      # A %Masked{} (the shape a vault field renders on the egress path) is not a safe segment.
      assert {:error, :pii_egress_refused} =
               Chokepoint.embed(Provider.Fake, %{}, [Masked.new(@vt_token, :emails)], [])

      # A raw vt_* token string is refused by the scrub's sentinel scan.
      assert {:error, :pii_egress_refused} =
               Chokepoint.embed(Provider.Fake, %{}, [@vt_token], [])

      # The seal refuses BEFORE dispatch, so nothing reached the embedder/provider.
      assert Provider.Fake.sent_payloads() == []
    end
  end

  # ---------------------------------------------------------------------------------------
  describe "compile-time (non-vacuous) — EmbeddableNoPii flags a 🔒 field, passes a clean one" do
    alias Samen.Verifiers.EmbeddableNoPii

    test "a vault-routed embeddable field is detected (would fail compile)" do
      # emails is vault-routed; declaring it embeddable is the violation.
      assert EmbeddableNoPii.offending_field([:emails], [:emails]) == :emails
      opts = EmbeddableNoPii.dsl_error_opts(SomeMod, :emails)
      assert opts[:path] == [:samen, :embeddable]
      assert opts[:message] =~ "vector space"
    end

    test "a non-PII embeddable field is NOT flagged (the check is not blanket-failing)" do
      assert EmbeddableNoPii.offending_field([:body], [:emails]) == nil
      assert EmbeddableNoPii.offending_field([], []) == nil
    end
  end

  # ---------------------------------------------------------------------------------------
  describe "T141 — an UNWIRED embedder outside :test is fail-honest {:error, :not_configured}" do
    # The ADR-014/M9 fail-honest contract: an unconfigured embedder in a prod/non-test env
    # returns EXACTLY {:error, :not_configured} — never {:error, {:provider_error, :error}}
    # (the pre-fix sentinel, from destructuring the error tuple as a {module, config} pair),
    # never a raise, never a faked {:ok}. Injected via the :env_reader opt (the T66-F2 seam),
    # so the CI :test env (which resolves the deterministic embedder) does not mask it.
    test "embed_field/6 with the env forced to :prod returns {:error, :not_configured}" do
      s = scope(Ash.UUID.generate())
      id = Ash.UUID.generate()

      # :body IS a declared, non-vault embeddable field of Article — so the resolution reaches
      # the embedder seam (not refused earlier by the deny-by-default allowlist).
      assert {:error, :not_configured} =
               Embeddings.embed_field(s, Article, id, :body, "some body text",
                 Keyword.merge(opts(), env_reader: fn -> :prod end)
               )
    end

    test "search/3 with the env forced to :prod returns {:error, :not_configured}" do
      s = scope(Ash.UUID.generate())

      assert {:error, :not_configured} =
               Embeddings.search(s, "any query", Keyword.merge(opts(), env_reader: fn -> :prod end))
    end
  end

  # ---------------------------------------------------------------------------------------
  describe "T147(a) — declared_embeddable_fields/1 loads the resource before introspecting" do
    # Regression for the fail-CLOSED latent bug: `declared_embeddable_fields/1` called
    # `function_exported?(resource, :embeddable_fields, 0)` WITHOUT `Code.ensure_loaded?/1`
    # first, so for a NOT-YET-LOADED resource module the allowlist collapsed to `[]` and
    # `assert_embeddable/2` wrongly short-circuited with `{:error, :field_not_embeddable}` for a
    # genuinely-declared field — MASKING the ADR-014 `{:error, :not_configured}` contract that
    # `embed_field/6` should surface. Isolation-only today (an earlier test in this file loads
    # `Article`, so the full suite is green) — this test PURGES the module to reproduce the
    # unloaded state deterministically regardless of ordering.
    test "an UNLOADED resource reaches the :not_configured contract, NOT :field_not_embeddable" do
      # Force the exact pre-fix condition: `Article` unloaded ⇒ `function_exported?/3` is `false`.
      :code.purge(Article)
      :code.delete(Article)
      refute :erlang.function_exported(Article, :embeddable_fields, 0),
             "precondition: Article must be unloaded so the bug would trigger"

      # ensure the module is restored for any later test regardless of the assertion outcome.
      on_exit(fn -> Code.ensure_loaded?(Article) end)

      s = scope(Ash.UUID.generate())
      id = Ash.UUID.generate()

      # `:body` is a DECLARED, non-vault embeddable field. With the bug the collapsed allowlist
      # would refuse it as `:field_not_embeddable`; with the fix `Code.ensure_loaded?/1` reloads
      # the module, the field passes the allowlist, and (env forced to :prod) the resolution
      # surfaces the honest ADR-014 contract instead.
      result =
        Embeddings.embed_field(s, Article, id, :body, "some body text",
          Keyword.merge(opts(), env_reader: fn -> :prod end)
        )

      assert result == {:error, :not_configured},
             "the fix must surface the :not_configured contract for an unloaded resource"

      refute result == {:error, :field_not_embeddable},
             "the pre-fix bug (collapsed allowlist) must NOT re-appear"
    end
  end

  # ---------------------------------------------------------------------------------------
  describe "keyless embedder — deterministic + fail-honest" do
    test "the deterministic embedder is stable, fixed-dimension, and content-sensitive" do
      v1 = Embedder.Deterministic.vector("the quick brown fox")
      v2 = Embedder.Deterministic.vector("the quick brown fox")
      v3 = Embedder.Deterministic.vector("completely different unrelated text")

      assert length(v1) == Embedder.Deterministic.dim()
      assert v1 == v2, "same text ⇒ same vector (deterministic)"
      assert v1 != v3, "different text ⇒ different vector (content-sensitive)"
    end

    test "the deterministic embedder is fail-honest: it does not complete" do
      {:ok, payload} = Chokepoint.seal(:embed, ["hi"], [])
      assert {:error, :not_implemented} = Embedder.Deterministic.complete(payload, %{})
    end
  end
end
