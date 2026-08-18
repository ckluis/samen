defmodule Samen.AI.VerbsAllowGrantFixture do
  @moduledoc "Test grant checker: approves every reveal context (the operator-WITH-grant case)."
  @behaviour Samen.Reveal.Grant
  @impl true
  def granted?(_context), do: true
end

defmodule Samen.AI.VerbsVaultStubFixture do
  @moduledoc """
  Test vault double: on the grant path, `reveal/3` returns the canary plaintext (keyless — no
  real decrypt, the grant-plaintext-egress path is proven at the value layer).
  """
  # MUST match @canary in Samen.AI.VerbsTest below.
  def reveal(%Samen.Masked{}, _repo, _opts), do: {:ok, "canary-verb-4f3e2d@leak.example"}
end

defmodule Samen.AI.VerbsTruthyGrantFixture do
  @moduledoc """
  Test grant checker returning a TRUTHY NON-`true` verdict (`:yes`) — a non-conforming checker
  (T137). `Samen.Api.PiiResolution.resolve_egress/7` must require a LITERAL `true`, so this
  verdict must NOT admit plaintext into the egress payload.
  """
  @behaviour Samen.Reveal.Grant
  @impl true
  def granted?(_context), do: :yes
end

defmodule Samen.AI.VerbsTest do
  @moduledoc """
  T68 (ADR-043 §7.5) — the six intelligence verbs (Summarize, Extract, Classify, Generate,
  Recommend, Analyze). Proves:

    * **per-verb table test** — each of the six verbs executes org-scoped, through the
      chokepoint, against the fake provider, using its BUILT-IN default template
      (framework-first ≈0-LOC — no `Samen.AI.Prompt` row required);
    * **name+version reference** — `opts[:prompt]: {name, version}` selects an EXACT
      org-authored prompt version, not silently "whatever is latest";
    * **cross-org prompt isolation** — a verb referencing another org's prompt gets
      `{:error, :not_found}`, never a leak;
    * **the masked-path PII canary (non-vacuous, positive control)** — a vault-routed
      binding passed to a verb reaches the fake provider `••••`-masked, never plaintext,
      never a `vt_*` token; a live grant + the host opt-in is the ONE way to reveal it
      (proving the masked assertion is refutable, not a blanket pass);
    * **keyless / fail-honest** — an unconfigured provider outside `:test` returns
      `{:error, :not_configured}`, never a faked `{:ok, _}`;
    * **chokepoint routing, explicitly per verb module** — the RP-AI-1 AST probe
      (`Samen.AI.ChokepointAntiBypassProbeTest.offenders_in_source/2`) finds ZERO
      `%Samen.AI.MaskedPayload{}` constructions in any of the six verb source files.

  Sabotage-refutable: `scripts/sabotages/49-t68-ai-prompt-vt-scan-weaken.patch` targets the
  check-(c) structural verifier (see `prompt_resource_test.exs`), not this runtime suite —
  this suite's own canary/positive-control pairing is what makes ITS assertions refutable.
  """
  use ExUnit.Case, async: false

  alias Samen.AI.{Completion, Prompt, Provider, Verbs}
  alias SamenCore.TestRepo
  alias SamenCore.Support.RevealDomain.RevealPerson

  @res RevealPerson
  @canary "canary-verb-4f3e2d@leak.example"
  @vt_token "vt_" <> String.duplicate("a", 32)

  @verb_modules [
    {:summarize, Samen.AI.Verbs.Summarize},
    {:extract, Samen.AI.Verbs.Extract},
    {:classify, Samen.AI.Verbs.Classify},
    {:generate, Samen.AI.Verbs.Generate},
    {:recommend, Samen.AI.Verbs.Recommend},
    {:analyze, Samen.AI.Verbs.Analyze}
  ]

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})
    Provider.Fake.reset()
    :ok
  end

  defp uniq, do: System.unique_integer([:positive])

  defp scope(org_id) do
    %Samen.Scope{actor: %{id: "u:#{org_id}", org_id: org_id, role: :member, plane: :tenant}}
  end

  defp op_actor, do: %{plane: :operator}

  defp recorded_text do
    Provider.Fake.sent_payloads()
    |> Enum.flat_map(fn {_callback, payload} -> Enum.map(payload.segments, &seg_to_string/1) end)
    |> Enum.join("\n")
  end

  defp seg_to_string(seg) when is_binary(seg), do: seg
  defp seg_to_string(seg), do: inspect(seg)

  # --------------------------------------------------------------------------------------
  # per-verb table test — the six-row proof

  describe "per-verb table test: each verb executes org-scoped through the chokepoint (default template)" do
    for {verb_name, mod} <- @verb_modules do
      test "#{verb_name}: #{inspect(mod)}.run/3 returns {:ok, %Completion{}} via the fake provider" do
        org = Ash.UUID.generate()
        s = scope(org)
        mod = unquote(mod)

        assert {:ok, %Completion{text: text}} = mod.run(s, "the quarterly report is on track")
        assert is_binary(text)

        assert recorded_text() =~ "the quarterly report is on track",
               "#{inspect(mod)} did not route its input to the fake provider recording"
      end
    end

    test "Samen.AI.Verbs.verbs/0 lists exactly the six ADR-043 §7.5 verb names" do
      assert Verbs.verbs() == [:summarize, :extract, :classify, :generate, :recommend, :analyze]
    end
  end

  # --------------------------------------------------------------------------------------
  # name+version reference — "verbs reference prompts by name + version"

  describe "opts[:prompt]: {name, version} selects an EXACT org-authored prompt version" do
    test "referencing version 1 renders v1's body, NOT the latest (v2)" do
      org = Ash.UUID.generate()
      s = scope(org)
      name = "custom.summarize.#{uniq()}"

      {:ok, _v1} = Prompt.new_version(s, name, "V1 TEMPLATE MARKER: {{input}}")
      {:ok, _v2} = Prompt.new_version(s, name, "V2 TEMPLATE MARKER: {{input}}")

      assert {:ok, %Completion{}} =
               Samen.AI.Verbs.Summarize.run(s, "payload-x", prompt: {name, 1})

      assert recorded_text() =~ "V1 TEMPLATE MARKER"
      refute recorded_text() =~ "V2 TEMPLATE MARKER"
    end

    test "referencing the name alone (no version) resolves the LATEST version" do
      org = Ash.UUID.generate()
      s = scope(org)
      name = "custom.latest.#{uniq()}"

      {:ok, _v1} = Prompt.new_version(s, name, "OLD MARKER: {{input}}")
      {:ok, _v2} = Prompt.new_version(s, name, "NEW MARKER: {{input}}")

      assert {:ok, %Completion{}} = Samen.AI.Verbs.Summarize.run(s, "payload-y", prompt: name)

      assert recorded_text() =~ "NEW MARKER"
      refute recorded_text() =~ "OLD MARKER"
    end
  end

  # --------------------------------------------------------------------------------------
  # cross-org prompt isolation — a verb-level proof (Prompt.fetch/3's own proof is T68's
  # prompt_resource_test.exs; this proves the ISOLATION HOLDS THROUGH the verb call path too).

  describe "cross-org prompt isolation: a verb referencing another org's prompt is refused" do
    test "org B's verb call with org A's {name, version} returns {:error, :not_found} — never org A's body" do
      org_a = Ash.UUID.generate()
      org_b = Ash.UUID.generate()
      name = "cross-org-verb.#{uniq()}"

      {:ok, _} = Prompt.new_version(scope(org_a), name, "org A's private prompt: {{input}}")

      assert {:error, :not_found} =
               Samen.AI.Verbs.Summarize.run(scope(org_b), "attempted-read", prompt: {name, 1})

      refute recorded_text() =~ "org A's private prompt"
    end
  end

  # --------------------------------------------------------------------------------------
  # the masked-path PII canary — non-vacuous, positive control (INV-1)

  describe "masked-path input: a vault-routed binding reaches the provider MASKED, never plaintext (refutable)" do
    setup do
      field = @res |> Samen.Pii.Info.pii_attributes() |> Enum.at(0) |> Map.get(:name)
      id = Ash.UUID.generate()
      rec = @res |> struct(id: id, display_name: "Canary Co") |> Map.put(field, Samen.Masked.new(@vt_token, field))
      %{rec: rec, field: field}
    end

    for {verb_name, mod} <- @verb_modules do
      test "#{verb_name}: a vault-routed binding masks — no canary plaintext, no vt_ token", %{
        rec: rec
      } do
        mod = unquote(mod)

        assert {:ok, %Completion{}} =
                 mod.run(scope(Ash.UUID.generate()), "summarize the account",
                   actor: op_actor(),
                   bindings: [{[rec], @res}]
                 )

        recorded = recorded_text()
        refute recorded =~ @canary, "#{inspect(mod)} leaked the canary PLAINTEXT to the provider"
        refute recorded =~ "vt_", "#{inspect(mod)} leaked a vt_ token to the provider"
        assert recorded =~ Samen.Masked.mask(), "#{inspect(mod)} must carry the masked field present-but-masked"
      end
    end

    test "POSITIVE CONTROL: a live grant + the grant_plaintext_egress opt-in egresses the canary (proves the masking above is refutable)",
         %{rec: rec} do
      assert {:ok, %Completion{}} =
               Samen.AI.Verbs.Summarize.run(scope(Ash.UUID.generate()), "summarize the account",
                 actor: op_actor(),
                 bindings: [{[rec], @res}],
                 grant_egress?: true,
                 grant: Samen.AI.VerbsAllowGrantFixture,
                 vault: Samen.AI.VerbsVaultStubFixture,
                 repo: :fake_repo
               )

      assert recorded_text() =~ @canary
    end

    test "T137: a TRUTHY-NON-true grant verdict (:yes) does NOT admit plaintext, stays masked",
         %{rec: rec} do
      # Same path as the positive control above, but the grant checker returns `:yes` (truthy,
      # not the literal `true`). resolve_egress/7 must refuse it — the field stays `••••`, the
      # canary never egresses. This flips if resolve_egress accepts any truthy verdict again.
      assert {:ok, %Completion{}} =
               Samen.AI.Verbs.Summarize.run(scope(Ash.UUID.generate()), "summarize the account",
                 actor: op_actor(),
                 bindings: [{[rec], @res}],
                 grant_egress?: true,
                 grant: Samen.AI.VerbsTruthyGrantFixture,
                 vault: Samen.AI.VerbsVaultStubFixture,
                 repo: :fake_repo
               )

      recorded = recorded_text()

      refute recorded =~ @canary,
             "a truthy-non-true grant verdict must NOT egress plaintext (resolve_egress requires a literal true)"

      refute recorded =~ "vt_"

      assert recorded =~ Samen.Masked.mask(),
             "the vault field must remain present-but-masked when the grant verdict is not a literal true"
    end
  end

  # --------------------------------------------------------------------------------------
  # keyless / fail-honest

  describe "keyless / fail-honest: unconfigured outside :test never fakes success" do
    test "a verb call with the unwired-provider env forced to :prod returns {:error, :not_configured}" do
      assert {:error, :not_configured} =
               Samen.AI.Verbs.Summarize.run(scope(Ash.UUID.generate()), "x",
                 env_reader: fn -> :prod end
               )

      assert Provider.Fake.sent_payloads() == [],
             "an unconfigured provider must never be reached, even to record a payload"
    end
  end

  # --------------------------------------------------------------------------------------
  # RP-AI-1 — the verb modules themselves never construct a MaskedPayload (explicit binding)

  describe "RP-AI-1 (ADR-043 §3.2 layer 3): verb modules never mint a MaskedPayload directly" do
    @verb_files ~w(
      samen_core/lib/samen/ai/verbs.ex
      samen_core/lib/samen/ai/verbs/summarize.ex
      samen_core/lib/samen/ai/verbs/extract.ex
      samen_core/lib/samen/ai/verbs/classify.ex
      samen_core/lib/samen/ai/verbs/generate.ex
      samen_core/lib/samen/ai/verbs/recommend.ex
      samen_core/lib/samen/ai/verbs/analyze.ex
    )

    test "zero MaskedPayload constructions in any verb source file" do
      repo_root = Path.expand("../../..", __DIR__)

      offenders =
        for rel <- @verb_files,
            path = Path.join(repo_root, rel),
            offender <-
              Samen.AI.ChokepointAntiBypassProbeTest.offenders_in_source(File.read!(path), rel) do
          offender
        end

      assert offenders == [], "a verb module bypasses the chokepoint: #{inspect(offenders)}"
    end
  end
end
