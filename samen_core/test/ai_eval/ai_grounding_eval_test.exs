defmodule Samen.AI.Eval.GroundingEvalTest do
  @moduledoc """
  T72 / RP-AI-8-adjacent (ADR-043 §10.1, D8) — the PERMANENT, keyless, deterministic
  **grounding-context eval**, the eval half of the D8 CI tier (the mask-leak red-team is
  `ai_plane_redteam_test.exs`). It runs the committed corpus (`SamenCore.Support.
  AiEvalCorpus.grounding_cases/0`, ≥20 cases) through the REAL kernel completion path
  (`Samen.AI.complete/4` → `Samen.AI.Chokepoint` → the recording `Provider.Fake`) and
  asserts that the correct catalog grounding was **assembled and injected** into the payload
  the provider received.

  ## What it measures (the §10 honesty clause, verbatim)

  Under the scriptable Fake there is no model cognition, so this proves the correct
  grounding context was **assembled and injected** for each question (catalog selection +
  prompt composition) — a **context-assembly bar, NOT a model-answer-fidelity bar** (that is
  the `SAMEN_AI_LIVE=1` lane). **Pass bar: ≥90%** (ADR-043 §10.1, authoritative — this eval
  never picks its own number). The ≥90 over 100 is deliberate: the corpus includes
  indirect-reference `:absent` cases so a 100% bar cannot pressure the corpus toward
  triviality (the anti-tautology failure mode §10 names).

  ## Deterministic + keyless (no flake — this is a permanent gate)

  `Provider.Fake` is scripted (same segments ⇒ same output) and grounding is pure
  `Ash.Resource.Info` introspection over a FIXED resource set per case (`opts[:resources]`),
  so the score is identical every run. Zero API keys, zero live calls, no DB (the schema
  catalog is compile-time metadata; the org-scoped custom-object half degrades to `[]`
  without a repo). A regression that breaks grounding assembly drops the score below 0.90
  and FAILS the tier.
  """
  use ExUnit.Case, async: true

  @moduletag :ai_eval

  alias Samen.AI.Provider
  alias SamenCore.Support.AiEvalCorpus

  # ADR-043 §10.1 — the authoritative context-assembly pass bar. Fixed here; never chosen.
  @pass_bar 0.90

  defp scope(org), do: %Samen.Scope{actor: %{id: "eval:#{org}", org_id: org, role: :member, plane: :tenant}}

  # Assemble + inject grounding for one question through the real completion path, keyless,
  # and return the set of catalog table_names that actually reached the provider payload.
  defp grounded_tables(question, resources) do
    Provider.Fake.reset()

    {:ok, _completion} =
      Samen.AI.complete(scope(Ash.UUID.generate()), [question], %{},
        resources: resources,
        provider: {Provider.Fake, %{}}
      )

    [{:complete, payload}] = Provider.Fake.sent_payloads()

    payload.grounding
    |> Map.get(:schema, %{})
    |> Map.get("tables", [])
    |> Enum.map(& &1["table_name"])
    |> MapSet.new()
  end

  # Does the case's grounding property hold?
  defp case_passes?(%{question: q, resources: resources, expect: {kind, mod}}) do
    tables = grounded_tables(q, resources)
    table = Samen.Catalog.table_name(mod)

    case kind do
      :present -> MapSet.member?(tables, table)
      :absent -> not MapSet.member?(tables, table)
    end
  end

  describe "the grounding-context eval — ≥90% of the committed corpus assembles the expected grounding" do
    test "the corpus is a real, non-trivial floor (≥20 cases, both :present and :absent)" do
      cases = AiEvalCorpus.grounding_cases()

      assert length(cases) >= 20,
             "ADR-043 §10.1 fixes a ≥20-case floor; got #{length(cases)}"

      kinds = cases |> Enum.map(fn %{expect: {k, _}} -> k end) |> Enum.uniq() |> Enum.sort()

      assert kinds == [:absent, :present],
             "the corpus must carry BOTH :present and :absent (indirect-reference) cases so " <>
               "the ≥90% bar cannot be met by a trivial 'ground everything' assembler"
    end

    test "the assembled-grounding score meets the ADR-043 §10.1 ≥90% context-assembly bar" do
      cases = AiEvalCorpus.grounding_cases()
      total = length(cases)

      results = Enum.map(cases, fn c -> {c.id, case_passes?(c)} end)
      passed = Enum.count(results, fn {_id, ok} -> ok end)
      score = passed / total

      failures = for {id, false} <- results, do: id

      # The score lands in the tier's output (ADR-043 §10 — "the exact score lands in evidence").
      IO.puts(
        "\n[ai_eval] grounding-context assembly score: #{passed}/#{total} = " <>
          "#{Float.round(score * 100, 1)}% (bar ≥ #{trunc(@pass_bar * 100)}%)" <>
          if(failures == [], do: "", else: " — unassembled case ids: #{inspect(failures)}")
      )

      assert score >= @pass_bar,
             "grounding-context eval REGRESSION: #{Float.round(score * 100, 1)}% assembled, " <>
               "below the ADR-043 §10.1 ≥#{trunc(@pass_bar * 100)}% bar (unassembled: #{inspect(failures)})"
    end

    test "non-vacuous: the eval genuinely discriminates (a :present case whose resource is DROPPED fails)" do
      # Refutability of the scorer itself: the same property that PASSES when the resource is
      # in scope must FAIL when it is not — otherwise a 100% score would be meaningless.
      present = Enum.find(AiEvalCorpus.grounding_cases(), &match?(%{expect: {:present, _}}, &1))
      {:present, mod} = present.expect

      assert case_passes?(present), "sanity: the :present case passes in scope"

      dropped = %{present | resources: present.resources -- [mod], expect: {:present, mod}}
      refute case_passes?(dropped), "the scorer must FAIL when the expected resource is out of scope"
    end
  end
end
