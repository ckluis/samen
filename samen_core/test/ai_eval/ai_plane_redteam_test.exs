defmodule Samen.AI.Eval.MaskLeakRedTeamTest do
  @moduledoc """
  T72 / RP-AI-7 (ADR-043 §10.2 / §3.4, D8) — the PERMANENT mask-leak RED-TEAM, the load-
  bearing INV-7 (no-PII-egress) proof of the D8 CI tier. T65 established the standing
  `ai_prompt_masking` runtime red-team over in-memory fixtures; **T72 EXTENDS it** into a
  full-matrix eval over a **full-DB canary-seeded dataset**, exercising EVERY AI egress
  surface the WS-D tasks shipped (the T68 verbs, the T69 MCP tools, the T70 support operator,
  the T71 CRM + analytics surfaces, the T67 embeddings plane) and asserting no seeded canary
  — plaintext OR `vt_*` token — reaches ANY egress class:

    * **EG1** completion prompts — the six verbs + CRM + support-operator provider payloads;
    * **EG2** tool args / results — the structured-egress scrub (covered structurally by T65,
      re-asserted here through the live surfaces);
    * **EG3** embedding inputs / vector rows — a vault-routed field is refused, nothing stored;
    * **EG4** MCP tool responses — browse/drafts mask at the boundary;
    * **EG5** committed corpus/fixtures — this file + the corpus carry no raw vault token;
    * **EG6** logs / telemetry / errors — the observability shadow of a seeded call.

  Plus the load-bearing invariants: **cross-org isolation** (org B reaches NONE of org A's
  canaries through any surface), the **§3.2a multi-turn expired-grant re-mask** (RP-AI-10),
  and the **token-blind analytics** schema-purity refusal (§6.4). Every refutation is paired
  with a NON-VACUOUS positive control (the mask token IS present / a non-PII field DOES embed
  / org A DOES see its own) per the `Samen.MaskingCase` anti-tautology discipline.

  ## Full-DB vault canary seeding (the "full-DB" seeding T65 deferred to T72)

  `SamenCore.Support.AiEvalCorpus.seed_full_db!/1` writes unique 🔒 canaries into REAL vault-
  routed fields (`Person.emails`, `Document.secret`) across two orgs via the REAL vault write
  path (`Samen.Factory`), so the canary lives as ciphertext + a `vt_*` token in the row —
  never as plaintext. A masked-path canary appearance at any egress is therefore a genuine
  INV-7 leak, and a leak of the `vt_*` token is equally an INV-7 violation.

  ## Keyless + deterministic (a flaky permanent gate is a real red)

  Everything runs against `Samen.AI.Provider.Fake` (records every payload byte) + the
  deterministic embedder — zero API keys, zero live calls, identical result every run.

  ## Sabotage-refutable at the TIER level (scripts/sabotages/53-...)

  Sabotage 53 leaks the vault token at `Samen.AI.Chokepoint.render_value/1` (the value-layer
  mask of a full-DB-seeded 🔒 field), flipping the NAMED EG1 verbs test below — and because
  this file IS the `mix test test/ai_eval/` tier, the sabotage harness proves the TIER fails,
  not merely a unit test. The positive controls (mask present / leak detectable) make the
  refutation non-vacuous.
  """
  use ExUnit.Case, async: false

  @moduletag :ai_eval

  require Ash.Query
  require Logger
  import ExUnit.CaptureLog

  alias Samen.AI.{Analytics, Chokepoint, Completion, Crm, Embeddings, Mcp, Provider, SupportOperator, SupportReplyDraft, Verbs}
  alias Samen.AI.SupportOperator.ReplyHandler
  alias Samen.Delivery.FakeProvider
  alias Samen.Masked
  alias SamenCore.Support.AiEvalCorpus
  alias SamenCore.Support.ApprovalsFixture.{Approval, Document}
  alias SamenCore.Support.CrmScopeFixture.Person
  alias SamenCore.Support.EmbeddingsDomain.Article
  alias SamenCore.Support.RevealDomain.RevealPerson
  alias SamenCore.TestRepo

  @mask Masked.mask()
  @registry %{"ai_support_reply" => {:operator, ReplyHandler}}

  # Plaintext for the §3.2a multi-turn grant span exists ONLY behind the grant path — so its
  # appearance in an ungranted turn is a real leak. Never a vt_ token, so EG5 stays clean.
  @grant_canary "canary-eval-grant-6y5t4r@leak.example"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})
    Provider.Fake.reset()
    FakeProvider.reset()
    {:ok, AiEvalCorpus.seed_full_db!()}
  end

  # --- helpers ---------------------------------------------------------------------------

  defp scope(org, plane \\ :tenant),
    do: %Samen.Scope{actor: %{id: Ash.UUID.generate(), org_id: org, role: :member, plane: plane}}

  # All %MaskedPayload{} segments the Fake was sent this process, flattened to a scannable
  # string (the honest provider-side recording — a leak that reaches the provider is here).
  defp recorded_text do
    Provider.Fake.sent_payloads()
    |> Enum.flat_map(fn {_cb, p} -> Enum.map(p.segments, &to_string/1) end)
    |> Enum.join("\n")
  end

  # An org-scoped read of the seeded person with public fields selected — the vault-routed
  # emails reads back as %Samen.Masked{} (the Crm.read_source mechanism), the shape the
  # chokepoint masks. This is the binding the verbs egress.
  defp read_person(org, id) do
    fields = Person |> Ash.Resource.Info.public_attributes() |> Enum.map(& &1.name)

    query =
      Person
      |> Ash.Query.filter(org_id == ^org and id == ^id)
      |> Ash.Query.ensure_selected(fields)

    {:ok, records} = Ash.read(query, authorize?: false)
    records
  end

  # Every text column of every aie_embedding row, joined — a raw scan for a leaked value.
  defp store_dump do
    {:ok, %{rows: rows}} =
      TestRepo.query(
        "SELECT aie_source_resource, aie_source_id, aie_field, aie_embedding::text FROM aie_embedding",
        []
      )

    rows |> List.flatten() |> Enum.map_join(" ", &to_string/1)
  end

  # ==========================================================================
  # EG1 — the six verbs over a full-DB CRM binding (THE SABOTAGE TARGET)
  # ==========================================================================

  describe "EG1 — the intelligence verbs never egress the seeded canary" do
    test "the full-DB CRM canary never reaches the provider recording across all six verbs",
         %{org_a: org, person_a: person} do
      records = read_person(org, person.id)
      assert records != [], "sanity: the seeded person must be readable org-scoped"
      canary = AiEvalCorpus.crm_canary_a()

      for verb <- Verbs.verbs() do
        Provider.Fake.reset()

        assert {:ok, %Completion{}} =
                 Verbs.run(verb, scope(org), "handle this contact", bindings: [{records, Person}])

        recorded = recorded_text()

        # Non-vacuous positive control: the vault field WAS resolved into the egress, MASKED.
        assert recorded =~ @mask, "verb #{verb}: the 🔒 field must resolve-then-mask, not be omitted"
        refute recorded =~ canary, "verb #{verb}: the 🔒 canary PLAINTEXT reached the provider"
        refute recorded =~ "vt_", "verb #{verb}: a vault token reached the provider"
      end
    end
  end

  # ==========================================================================
  # EG1 + EG6 (persisted draft) — the AI support operator
  # ==========================================================================

  describe "EG1 — the support operator masks the seeded canary in the provider AND the persisted draft" do
    test "draft_reply grounds on a full-DB support item and leaks nothing to the provider or the stored body",
         %{org_a: org, doc_a: doc} do
      canary = AiEvalCorpus.doc_canary_a()

      {:ok, result} =
        SupportOperator.draft_reply(
          scope(org, :operator),
          %{
            to_subscriber_id: Ash.UUID.generate(),
            source_resource: Document,
            source_id: doc.id,
            instruction: "draft a friendly reply to this refund question",
            verb: :generate
          },
          approval_resource: Approval,
          repo: TestRepo,
          kinds: @registry
        )

      recorded = recorded_text()
      assert recorded =~ @mask, "the support item's 🔒 field must resolve-then-mask (non-vacuous)"
      refute recorded =~ canary, "the 🔒 canary reached the AI provider payload"
      refute recorded =~ "vt_", "a vault token reached the AI provider payload"

      # The persisted draft body (what a human reviews / what will send) carries neither.
      draft = Ash.get!(SupportReplyDraft, result.draft.id, authorize?: false)
      refute draft.body =~ canary
      refute draft.body =~ "vt_"
    end
  end

  # ==========================================================================
  # EG1 + draft body — the CRM AI surfaces
  # ==========================================================================

  describe "EG1 — the CRM AI surfaces never egress the seeded canary" do
    test "summarize_timeline / recommend_next_step / draft_sequence mask the canary everywhere",
         %{org_a: org, person_a: person} do
      canary = AiEvalCorpus.crm_canary_a()

      assert {:ok, %Completion{}} = Crm.summarize_timeline(scope(org), Person, person.id)
      assert recorded_text() =~ @mask
      refute recorded_text() =~ canary
      refute recorded_text() =~ "vt_"

      Provider.Fake.reset()
      assert {:ok, %Completion{}} = Crm.recommend_next_step(scope(org), Person, person.id)
      refute recorded_text() =~ canary

      Provider.Fake.reset()

      assert {:ok, %{status: :draft, body: body}} =
               Crm.draft_sequence(scope(org), Person, person.id, "draft a friendly check-in")

      refute body =~ canary, "the drafted sequence body must never carry the canary"
      refute body =~ "vt_"
      refute recorded_text() =~ canary
    end
  end

  # ==========================================================================
  # EG4 — MCP tool responses mask at the external-agent boundary
  # ==========================================================================

  describe "EG4 — the MCP boundary masks the seeded canary" do
    test "browse and drafts over a full-DB support item never surface the canary",
         %{org_a: org, doc_a: doc} do
      canary = AiEvalCorpus.doc_canary_a()
      opts = [resources: [Document], repo: TestRepo]

      {:ok, data} = Mcp.browse(scope(org), %{"resource" => "apd_document"}, opts)
      assert [rec] = data["records"]
      assert rec["title"] == "Refund question", "a non-PII field is CLEAR (projection is not blanket-masking)"
      assert rec["secret"] == @mask, "the 🔒 field is masked at the MCP boundary"
      refute inspect(data) =~ canary, "the canary reached the MCP browse response"
      refute inspect(data) =~ "vt_"

      {:ok, ddata} =
        Mcp.drafts(
          scope(org),
          %{"verb" => "summarize", "input" => "summarize the account", "resource" => "apd_document", "record_id" => doc.id},
          opts
        )

      assert ddata["kind"] == "draft"
      refute inspect(ddata) =~ canary, "the canary reached the MCP draft response"
      refute recorded_text() =~ canary, "the canary reached the provider via the MCP draft"
      refute recorded_text() =~ "vt_"
    end
  end

  # ==========================================================================
  # EG3 — embeddings deny-by-default; no canary ever reaches the vector store
  # ==========================================================================

  describe "EG3 — a vault-routed field never enters vector space (grants never unlock it)" do
    test "embed_field on a 🔒 field is refused and the vector store carries no canary; a non-PII body embeds",
         %{org_a: org} do
      s = scope(org)
      canary = AiEvalCorpus.crm_canary_a()

      assert {:error, :field_not_embeddable} =
               Embeddings.embed_field(s, RevealPerson, Ash.UUID.generate(), :emails, canary, repo: TestRepo)

      # Non-vacuous positive control: a legitimately-declared non-PII field DOES embed.
      article = struct(Article, id: Ash.UUID.generate(), body: "quarterly billing report")
      assert {:ok, 1} = Embeddings.embed_record(s, article, Article, repo: TestRepo)

      dump = store_dump()
      refute dump =~ canary, "the 🔒 canary reached the invertible vector store (permanent leak)"
      refute dump =~ "vt_", "a vault token reached the vector store"
    end
  end

  # ==========================================================================
  # §6.4 — token-blind analytics: no PII column to leak, by schema
  # ==========================================================================

  describe "§6.4 — analytics is token-blind by schema" do
    test "ask over a PII-bearing resource is refused BEFORE any read (non-vacuous)", %{org_a: org} do
      # The one being refused genuinely carries vault-routed columns — the refusal protects
      # something real. (The full narration-over-suppressed-rows path is demo/test/ai_analytics_test.exs.)
      # An operator/platform caller passes the T144 caller-authz gate so the refusal proven here
      # is the RESOURCE-plane (schema-purity) refusal, not the authz refusal (covered in
      # test/ai/analytics_test.exs).
      assert {:error, :not_aggregate_resource} =
               Analytics.ask(scope(org, :operator), Person, "how many contacts do we have?")

      assert Samen.Pii.Info.vault_routed_columns(Person) != []
    end
  end

  # ==========================================================================
  # EG6 — logs / telemetry / errors carry no canary or vault token
  # ==========================================================================

  describe "EG6 — the observability shadow of a seeded call carries no content" do
    test "a naive log line, a normalized adapter error, and a telemetry event cannot spill the canary",
         %{org_a: org, person_a: person} do
      canary = AiEvalCorpus.crm_canary_a()
      records = read_person(org, person.id)

      {:ok, payload} =
        Chokepoint.seal(:complete, ["ctx"], actor: scope(org).actor, bindings: [{records, Person}])

      # An adapter error that tries to echo the canary is normalized to a content-free term.
      assert {:error, {:provider_error, Provider.Fake}} =
               Chokepoint.complete(Provider.Fake, %{error: {:boom, canary}}, :complete, ["p"], [])

      log =
        capture_log(fn ->
          Logger.error("ai egress: payload=#{inspect(payload)} err=#{inspect({:error, :pii_egress_refused})}")
        end)

      refute log =~ canary
      refute log =~ "vt_"

      handler = "t72-eg6-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:samen, :ai, :t72_egress],
        fn _e, _m, meta, _c -> send(self(), {:telemetry_meta, inspect(meta)}) end,
        nil
      )

      :telemetry.execute([:samen, :ai, :t72_egress], %{count: 1}, %{payload: payload, kind: payload.kind})
      :telemetry.detach(handler)

      assert_receive {:telemetry_meta, meta_str}
      refute meta_str =~ canary
      refute meta_str =~ "vt_"
    end
  end

  # ==========================================================================
  # RP-AI-10 — the §3.2a multi-turn expired-grant re-mask
  # ==========================================================================

  describe "RP-AI-10 — a grant-revealed span re-masks in an ungranted later turn" do
    test "a canary in a grant-tagged span never survives into the ungranted turn N+1 payload" do
      field = RevealPerson |> Samen.Pii.Info.pii_attributes() |> Enum.at(0) |> Map.get(:name)
      action = RevealPerson |> Samen.Pii.Info.reveal_actions() |> Enum.at(0)

      ctx = %Samen.Reveal.Context{
        actor: %{plane: :operator},
        subject_id: "11111111-1111-1111-1111-111111111111",
        resource: RevealPerson,
        action: action,
        label: field
      }

      # Turn N+1: the accumulated history carries the prior turn's grant-resolved canary as a
      # grant-tagged span, but THIS turn lacks the grant (flag off) → the span re-masks.
      assert {:ok, payload} =
               Chokepoint.seal(:complete, ["turn N+1: summarize the prior answer"],
                 actor: %{plane: :operator},
                 history: [{:grant_span, @grant_canary, ctx}],
                 grant_egress?: false
               )

      refute Enum.any?(payload.segments, &(to_string(&1) =~ @grant_canary)),
             "an expired-grant turn leaked the accumulated canary (RP-AI-10)"

      assert @mask in payload.segments
    end
  end

  # ==========================================================================
  # Cross-org isolation — org B reaches NONE of org A's canaries
  # ==========================================================================

  describe "cross-org — org B reaches none of org A's seeded canaries through any surface" do
    test "CRM grounding + MCP browse are org-scoped, with the same-org positive control",
         %{org_a: org_a, org_b: org_b, person_a: person} do
      # CRM: org B — same tool, same id — cannot ground on org A's object.
      assert {:error, :source_not_found} = Crm.summarize_timeline(scope(org_b), Person, person.id)
      # Positive control: org A grounds on its own object.
      assert {:ok, %Completion{}} = Crm.summarize_timeline(scope(org_a), Person, person.id)

      # MCP: org B's browse sees none of org A's rows.
      opts = [resources: [Document], repo: TestRepo]
      {:ok, b_data} = Mcp.browse(scope(org_b), %{"resource" => "apd_document"}, opts)
      assert b_data["count"] == 0
      assert b_data["records"] == []

      {:ok, a_data} = Mcp.browse(scope(org_a), %{"resource" => "apd_document"}, opts)
      assert a_data["count"] == 1
    end
  end

  # ==========================================================================
  # Master no-egress scan — zero canary across a full fan-out
  # ==========================================================================

  describe "the master INV-7 assertion — zero seeded canary across the whole matrix" do
    test "after a full-surface fan-out, NONE of the seeded canaries appears in any provider recording",
         %{org_a: org, person_a: person, doc_a: doc} do
      Provider.Fake.reset()

      records = read_person(org, person.id)
      s = scope(org)

      # Fire a representative slice of every completion-bearing surface at once.
      {:ok, _} = Crm.summarize_timeline(s, Person, person.id)
      {:ok, _} = Verbs.run(:analyze, s, "analyze", bindings: [{records, Person}])

      {:ok, _} =
        SupportOperator.draft_reply(
          scope(org, :operator),
          %{to_subscriber_id: Ash.UUID.generate(), source_resource: Document, source_id: doc.id, instruction: "reply"},
          approval_resource: Approval,
          repo: TestRepo,
          kinds: @registry
        )

      recorded = recorded_text()

      for canary <- AiEvalCorpus.canaries() do
        refute recorded =~ canary, "a seeded canary reached a provider recording: #{canary}"
      end

      refute recorded =~ "vt_", "a vault token reached a provider recording"
      # Non-vacuous: the fan-out DID egress masked vault fields (the surfaces really ran).
      assert recorded =~ @mask
    end
  end

  # ==========================================================================
  # EG5 — the committed corpus + this red-team file carry no raw vault token
  # ==========================================================================

  describe "EG5 — the committed eval corpus + this file embed no raw vault token" do
    test "a file-scan of the corpus and this red-team finds no vt_ token (non-vacuous scanner)" do
      token_re = ~r/vt_[0-9a-f]{32}/

      files = [
        Path.join(__DIR__, "ai_plane_redteam_test.exs"),
        Path.expand("../support/ai_eval_corpus.ex", __DIR__)
      ]

      for path <- files do
        assert File.exists?(path), "EG5 fixture scan found no file at #{path}"

        assert Regex.scan(token_re, File.read!(path)) == [],
               "EG5: #{Path.relative_to_cwd(path)} commits a raw vault token"
      end

      # Anti-tautology: the same scanner DOES catch a modeled token, so the green above is real.
      assert Regex.match?(token_re, "contact_token=vt_" <> String.duplicate("a", 32))
      refute Regex.match?(token_re, AiEvalCorpus.crm_canary_a())
    end
  end
end
