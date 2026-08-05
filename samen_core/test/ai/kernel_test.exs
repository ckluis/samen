defmodule Samen.AI.KernelTest do
  @moduledoc """
  T64 — the `Samen.AI` kernel + `Samen.AI.Chokepoint` seam + `%Samen.AI.MaskedPayload{}`
  type + `Samen.AI.Provider.Fake` (ADR-043 §3/§4/§5). Proves:

    * calls dispatch through the chokepoint to the configured provider; unwired ⇒
      `{:error, :not_configured}` outside `:test`, the Fake in `:test` (fail-honest, RP-AI-3);
    * the by-construction gate: a provider callback REFUSES raw (non-MaskedPayload) input by
      function clause, so raw input cannot reach a provider (RP-AI-1 seam — sabotage-refutable);
    * `Provider.Fake` records the sent `%MaskedPayload{}` and is deterministic;
    * `%MaskedPayload{}` is Inspect-redacting (EG6 — RP-AI-9);
    * the chokepoint refuses `vt_*`/`%Masked{}` segments fail-closed (`:pii_egress_refused`);
    * adapter errors are normalized so they carry no payload content (EG6).
  """
  use ExUnit.Case, async: true

  alias Samen.AI
  alias Samen.AI.{Chokepoint, Completion, MaskedPayload, Provider}

  setup do
    Provider.Fake.reset()
    :ok
  end

  # --------------------------------------------------------------------------------------
  # provider_for/2 — the fail-honest resolution (RP-AI-3)

  describe "provider_for/2 (the Delivery decide/3 mirror)" do
    test "unwired in :test resolves to the keyless Fake" do
      assert {Provider.Fake, %{}} = AI.provider_for([], :test)
    end

    test "unwired in :prod is BLOCKED — {:error, :not_configured}, never a fake ok (ADR-014)" do
      assert {:error, :not_configured} = AI.provider_for([], :prod)
    end

    test "an explicit :provider opt overrides the env fallback" do
      assert {Provider.Fake, %{seed: 7}} = AI.provider_for([provider: {Provider.Fake, %{seed: 7}}], :prod)
    end
  end

  # --------------------------------------------------------------------------------------
  # resolved_env/1 — T66-F2 fix-round: never RAISE for a missing/unstartable Mix (fail-honest,
  # not fail-safe-by-crash). `Code.ensure_loaded?(Mix)` is true whenever the `:mix` BEAM files
  # are on the code path even if the OTP app never started — `Mix.env/0` then raises
  # `ArgumentError` live (its backing ETS table does not exist). `env_reader` is the injectable
  # seam so this is modeled WITHOUT touching the real `:mix` application's live state (stopping
  # the actual `:mix` app mid-suite would risk destabilizing the whole shared test run).

  describe "resolved_env/1 (T66-F2 — never raises, even when Mix.env/0 would)" do
    test "the default reader (&Mix.env/0) resolves normally to :test in this suite" do
      assert AI.resolved_env() == :test
    end

    test "a raising env_reader (modeling a stopped/unstartable :mix app) degrades to :prod, never raises" do
      raising_reader = fn -> raise ArgumentError, "the table identifier does not refer to an existing ETS table" end

      assert AI.resolved_env(raising_reader) == :prod
    end

    test "AI.complete/4 stays fail-honest ({:error, :not_configured}) when the env cannot be read" do
      # Non-vacuous end-to-end proof: with a raising reader, complete/4 must NOT crash — it
      # must degrade to the SAME fail-honest error an explicit :prod resolution produces
      # (RP-AI-3), never an unhandled exception.
      opts = [env_reader: fn -> raise "mix state unavailable" end]

      assert AI.complete(:scope, "hi", %{}, opts) == {:error, :not_configured}
    end
  end

  # --------------------------------------------------------------------------------------
  # complete/4 — dispatch through the chokepoint

  describe "complete/4 dispatches through the chokepoint to the configured provider" do
    test "configured Fake returns a Completion and RECORDS the sealed payload" do
      assert {:ok, %Completion{provider: :fake, text: text}} =
               AI.complete(:scope, "summarize the account", %{})

      assert is_binary(text)

      # The chokepoint minted a MaskedPayload and the provider received exactly that.
      assert [{:complete, %MaskedPayload{kind: :complete} = payload}] = Provider.Fake.sent_payloads()
      assert "summarize the account" in payload.segments
    end

    test "unwired provider outside :test blocks the call (fail-honest)" do
      # Force the non-:test resolution via an explicit unwired opt path: provider_for/2 is
      # the pure seam; complete/4's own auto-detection resolves to :test here (samen_core is
      # the main app in THIS suite, not a dependency — see T66's ai.ex fix note), so we
      # assert the pure branch directly.
      assert {:error, :not_configured} = AI.provider_for([], :prod)
    end

    test "deterministic: same input ⇒ same output (RP: Fake determinism)" do
      {:ok, a} = AI.complete(:scope, "same prompt", %{})
      {:ok, b} = AI.complete(:scope, "same prompt", %{})
      assert a.text == b.text

      {:ok, c} = AI.complete(:scope, "different prompt", %{})
      refute c.text == a.text
    end
  end

  # --------------------------------------------------------------------------------------
  # By-construction raw refusal (RP-AI-1 seam) — the load-bearing INV-7 mechanism

  describe "a provider callback accepts ONLY %MaskedPayload{} (by-construction raw refusal)" do
    # `apply/3` obscures the argument type from the compile-time set-theoretic type checker
    # (which would otherwise flag a statically-known non-MaskedPayload literal under
    # --warnings-as-errors): the REFUSAL we assert is a RUNTIME clause guarantee, not a
    # compile-time type claim (ADR-043 §3.2 — Elixir does not statically type callback args).
    test "Fake.complete/2 refuses a raw string by function clause (runtime)" do
      assert_raise FunctionClauseError, fn ->
        apply(Provider.Fake, :complete, ["a raw unmasked prompt", %{}])
      end
    end

    test "Fake.complete/2 refuses a raw map by function clause (runtime)" do
      raw = %{prompt: "raw"}

      assert_raise FunctionClauseError, fn ->
        apply(Provider.Fake, :complete, [raw, %{}])
      end
    end

    test "sabotage-refutable: a chokepoint-minted payload DOES reach the provider (positive control)" do
      {:ok, %MaskedPayload{} = payload} = Chokepoint.seal(:complete, ["masked prompt"], [])
      assert {:ok, %Completion{}} = Provider.Fake.complete(payload, %{})
    end
  end

  # --------------------------------------------------------------------------------------
  # Chokepoint fail-closed scrub (RP-AI-2 skeleton) + single mint

  describe "Chokepoint.seal/3 fails closed on unsafe segments" do
    test "a vt_* token segment is refused (payload-free error)" do
      assert {:error, :pii_egress_refused} = Chokepoint.seal(:complete, ["vt_abc123"], [])
    end

    test "an un-rendered %Samen.Masked{} segment is refused" do
      masked = Samen.Masked.new("vt_tok", :email)
      assert {:error, :pii_egress_refused} = Chokepoint.seal(:complete, [masked], [])
    end

    test "a clean segment seals (positive control — the refusal is not vacuous)" do
      assert {:ok, %MaskedPayload{segments: ["clean text"]}} =
               Chokepoint.seal(:complete, ["clean text"], [])
    end

    test "complete/5 surfaces the refusal without ever calling the provider" do
      assert {:error, :pii_egress_refused} =
               Chokepoint.complete(Provider.Fake, %{}, :complete, ["vt_leak"], [])

      assert Provider.Fake.sent_payloads() == [], "a refused payload must NEVER reach the provider"
    end
  end

  # --------------------------------------------------------------------------------------
  # Inspect-redaction (EG6 — RP-AI-9)

  describe "%MaskedPayload{} is Inspect-redacting (EG6)" do
    test "inspect/1 does NOT print the sealed segment content" do
      {:ok, payload} = Chokepoint.seal(:complete, ["SECRET-CANARY-ssn-000-11-2222"], grounding: %{table: :accounts})
      rendered = inspect(payload)

      refute rendered =~ "SECRET-CANARY"
      refute rendered =~ "000-11-2222"
      assert rendered =~ "#Samen.AI.MaskedPayload<"
      assert rendered =~ "kind: :complete"
      assert rendered =~ "segments: 1 sealed"
      # grounding KEY names are safe metadata; values are never present.
      assert rendered =~ "grounding: [:table]"
    end

    test "a payload interpolated into a log-style string cannot spill its segments" do
      {:ok, payload} = Chokepoint.seal(:complete, ["LEAK-CANARY-42"], [])
      line = "dispatching payload=#{inspect(payload)}"
      refute line =~ "LEAK-CANARY"
    end
  end

  # --------------------------------------------------------------------------------------
  # EG6 adapter-error normalization

  describe "adapter errors are normalized (EG6 — no payload content propagates)" do
    test "a bounded atom error passes through unchanged" do
      assert {:error, :not_configured} =
               Chokepoint.complete(Provider.Fake, %{error: :not_configured}, :complete, ["p"], [])
    end

    test "a rich error that could echo the prompt is reduced to a content-free term" do
      # The Fake is scripted to return an error tuple carrying a canary — the chokepoint
      # must strip it before it propagates.
      assert {:error, {:provider_error, Provider.Fake}} =
               Chokepoint.complete(
                 Provider.Fake,
                 %{error: {:boom, "PROMPT-CANARY-should-not-leak"}},
                 :complete,
                 ["p"],
                 []
               )
    end
  end

  # --------------------------------------------------------------------------------------
  # embed/3 seam

  describe "embed/3 routes through the chokepoint" do
    test "configured Fake returns one deterministic vector per segment and records the payload" do
      assert {:ok, [v1, v2]} = AI.embed(:scope, ["alpha", "beta"])
      assert is_list(v1) and is_list(v2)
      assert [{:embed, %MaskedPayload{kind: :embed}}] = Provider.Fake.sent_payloads()
    end

    test "embed refuses a vt_* segment fail-closed" do
      assert {:error, :pii_egress_refused} = AI.embed(:scope, ["vt_token"])
    end
  end
end
