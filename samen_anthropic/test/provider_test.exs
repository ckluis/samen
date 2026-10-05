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
      config = %{
        api_key: "sk-ant-xxx",
        model: "claude-opus-5",
        transport: fixture_transport(self())
      }

      assert {:ok,
              %Completion{
                provider: :anthropic,
                text: "fixture completion",
                model: "claude-opus-5"
              }} =
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
        {:ok,
         %{
           status: 400,
           body: %{"error" => %{"type" => "invalid_request_error", "message" => "PROMPT-CANARY"}}
         }}
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

  # ---------------------------------------------------------------------------
  # Context overflow (ADR-048 §6 Level 2 constraint 1; issue #11)
  #
  # The two ways the Messages API says the context overflowed, both mapped to the bounded
  # `:context_overflow` kind the agent's Level 2 recovery keys on — and the one that spent
  # tokens carries them, so the failed attempt can be billed.

  @canary "Ada Lovelace, 12 Analytical Way"

  defp responding(response), do: fn _request -> {:ok, response} end

  defp complete_with(response),
    do: Provider.complete(sealed(["p"]), %{api_key: "sk-ant-x", transport: responding(response)})

  defp window_exceeded(usage) do
    %{
      status: 200,
      body: %{
        "type" => "message",
        "model" => "claude-opus-5",
        "stop_reason" => "model_context_window_exceeded",
        "content" => [%{"type" => "text", "text" => "truncated mid-sentence about " <> @canary}],
        "usage" => usage
      }
    }
  end

  defp invalid_request(message) do
    %{
      status: 400,
      body: %{
        "type" => "error",
        "error" => %{"type" => "invalid_request_error", "message" => message},
        "request_id" => "req_fixture"
      }
    }
  end

  describe "context overflow (issue #11)" do
    test "a 400 'prompt is too long' is a :context_overflow — nothing was spent, so no usage" do
      result =
        complete_with(invalid_request("prompt is too long: 1048577 tokens > 1048576 maximum"))

      assert result == {:error, :context_overflow}
    end

    test "any other invalid request stays a bounded provider error (the classifier is narrow)" do
      result =
        complete_with(
          invalid_request("messages: roles must alternate between \"user\" and \"assistant\"")
        )

      assert result == {:error, {:anthropic_error, 400, "invalid_request_error"}}
    end

    test "a 200 that filled the context window is a usage-carrying :context_overflow, never a completion" do
      result = complete_with(window_exceeded(%{"input_tokens" => 900, "output_tokens" => 48}))

      assert result == {:error, :context_overflow, %{input_tokens: 900, output_tokens: 48}}
      # The truncated text is never handed back as an answer (and never echoed — EG6).
      refute inspect(result) =~ "Lovelace"
    end

    test "positive control: a 200 that ended normally is still a completion" do
      assert {:ok, %Completion{text: "fixture completion"}} =
               Provider.complete(sealed(["p"]), %{
                 api_key: "sk-ant-x",
                 transport: fixture_transport()
               })
    end

    test "end to end through the chokepoint: the agent loop's opt-in sees the usage, every other caller the 2-tuple" do
      config = %{
        api_key: "sk-ant-x",
        transport: responding(window_exceeded(%{"input_tokens" => 900, "output_tokens" => 48}))
      }

      assert Chokepoint.complete(Provider, config, :complete, ["p"], error_usage: true) ==
               {:error, :context_overflow, %{input_tokens: 900, output_tokens: 48}}

      assert Chokepoint.complete(Provider, config, :complete, ["p"], []) ==
               {:error, :context_overflow}
    end
  end

  describe "usage (issue #11)" do
    test "input_tokens is the whole billed input — uncached plus cache write plus cache read" do
      usage = %{
        "input_tokens" => 40,
        "cache_creation_input_tokens" => 1_000,
        "cache_read_input_tokens" => 20_000,
        "output_tokens" => 7
      }

      assert {:error, :context_overflow, %{input_tokens: 21_040, output_tokens: 7}} =
               complete_with(window_exceeded(usage))
    end

    test "a missing or malformed count is 0, never a guess" do
      assert {:error, :context_overflow, %{input_tokens: 5, output_tokens: 0}} =
               complete_with(
                 window_exceeded(%{
                   "input_tokens" => 5,
                   "output_tokens" => "9",
                   "cache_read_input_tokens" => -3
                 })
               )

      assert {:error, :context_overflow, %{input_tokens: 0, output_tokens: 0}} =
               complete_with(window_exceeded(nil))
    end
  end
end
