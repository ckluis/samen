defmodule SamenAnthropic.ProviderTest do
  @moduledoc """
  T64 — `SamenAnthropic.Provider` standalone coverage. Proves the D1 contract for the
  reference AI-provider adapter WITHOUT any live HTTP call (ADR-043 §4):

    * fail-honest keyless: unconfigured (no `:api_key`) -> `{:error, :not_configured}`,
      never a fake `{:ok, _}` (RP-AI-3);
    * by-construction raw-refusal: a raw string/map refuses by function clause, so raw
      (unmasked) input cannot reach Anthropic (the INV-7 seam, RP-AI-1);
    * request-shaping + response-parsing against an injected fixture transport (the
      samen_postmark cassette precedent) — the pipeline genuinely works, proven without
      claiming a live call;
    * `embed/2` honestly refuses (Anthropic has no embeddings endpoint).
  """
  use ExUnit.Case, async: true

  alias Samen.AI.{Chokepoint, Completion, MaskedPayload}
  alias SamenAnthropic.Provider

  # Mint a real chokepoint-sealed payload (the only sanctioned mint path). Tests may
  # CALL the chokepoint's mint; only lib modules are forbidden from constructing the
  # struct literal (the anti-bypass probe scans lib/, not test/).
  defp sealed(segments) do
    {:ok, %MaskedPayload{} = payload} = Chokepoint.seal(:complete, segments, [])
    payload
  end

  # A recorded Anthropic Messages-API success response (no network).
  defp fixture_transport(recorder \\ nil) do
    fn request ->
      if recorder, do: send(recorder, {:anthropic_request, request})

      {:ok,
       %{
         status: 200,
         body: %{
           "id" => "msg_fixture",
           "type" => "message",
           "role" => "assistant",
           "model" => "claude-opus-5",
           "stop_reason" => "end_turn",
           "content" => [%{"type" => "text", "text" => "fixture completion"}],
           "usage" => %{"input_tokens" => 12, "output_tokens" => 3}
         }
       }}
    end
  end

  # ---------------------------------------------------------------------------
  # configured?/1

  describe "configured?/1" do
    test "false with no api_key" do
      refute Provider.configured?(%{})
    end

    test "false with an empty api_key" do
      refute Provider.configured?(%{api_key: ""})
    end

    test "true with a non-empty api_key" do
      assert Provider.configured?(%{api_key: "sk-ant-xxx"})
    end
  end

  # ---------------------------------------------------------------------------
  # fail-honest keyless (RP-AI-3)

  describe "complete/2 fail-honest keyless" do
    test "unconfigured (no api_key) refuses :not_configured — NEVER a fake ok" do
      assert {:error, :not_configured} = Provider.complete(sealed(["hello"]), %{})
    end

    test "unconfigured refuses even though a transport is wired (config, not glue, gates it)" do
      config = %{transport: fixture_transport()}
      assert {:error, :not_configured} = Provider.complete(sealed(["hello"]), config)
    end
  end

  # ---------------------------------------------------------------------------
  # by-construction raw-refusal (RP-AI-1 seam)

  describe "a provider callback accepts ONLY %MaskedPayload{} (raw input cannot reach Anthropic)" do
    test "complete/2 refuses a raw string by function clause (runtime)" do
      assert_raise FunctionClauseError, fn ->
        apply(Provider, :complete, ["a raw unmasked prompt", %{api_key: "sk-ant-xxx"}])
      end
    end

    test "complete/2 refuses a raw map by function clause (runtime)" do
      raw = %{prompt: "raw"}

      assert_raise FunctionClauseError, fn ->
        apply(Provider, :complete, [raw, %{api_key: "sk-ant-xxx"}])
      end
    end
  end

  # ---------------------------------------------------------------------------
  # configured + fixture transport → genuine parse (anti-tautology)

  describe "complete/2 with a fixture transport (no live call)" do
    test "configured + transport genuinely builds a request and parses the response" do
      config = %{api_key: "sk-ant-xxx", model: "claude-opus-5", transport: fixture_transport(self())}

      assert {:ok, %Completion{provider: :anthropic, text: "fixture completion", model: "claude-opus-5"}} =
               Provider.complete(sealed(["summarize the account"]), config)

      # The outbound request carries the sealed segment text in a user message and the
      # configured api_key/model — proving the request builder actually ran.
      assert_received {:anthropic_request, request}
      assert request.api_key == "sk-ant-xxx"
      assert request.body["model"] == "claude-opus-5"
      assert [%{"role" => "user", "content" => content}] = request.body["messages"]
      assert content =~ "summarize the account"
    end

    test "an Anthropic API error is surfaced as a bounded, content-free term (EG6)" do
      erroring = fn _request ->
        {:ok, %{status: 400, body: %{"error" => %{"type" => "invalid_request_error", "message" => "PROMPT-CANARY"}}}}
      end

      config = %{api_key: "sk-ant-xxx", transport: erroring}
      result = Provider.complete(sealed(["p"]), config)

      assert {:error, {:anthropic_error, 400, "invalid_request_error"}} = result
      refute inspect(result) =~ "PROMPT-CANARY"
    end

    test "a transport-level failure is surfaced as-is" do
      failing = fn _request -> {:error, :econnrefused} end
      config = %{api_key: "sk-ant-xxx", transport: failing}
      assert {:error, :econnrefused} = Provider.complete(sealed(["p"]), config)
    end
  end

  # ---------------------------------------------------------------------------
  # embed/2 — honest capability absence

  describe "embed/2" do
    test "unconfigured refuses :not_configured" do
      assert {:error, :not_configured} = Provider.embed(sealed(["x"]), %{})
    end

    test "configured but Anthropic has no embeddings endpoint -> :not_implemented (never a fake vector)" do
      assert {:error, :not_implemented} = Provider.embed(sealed(["x"]), %{api_key: "sk-ant-xxx"})
    end

    test "embed/2 also refuses raw (non-MaskedPayload) input by function clause" do
      assert_raise FunctionClauseError, fn ->
        apply(Provider, :embed, ["raw", %{api_key: "sk-ant-xxx"}])
      end
    end
  end
end
