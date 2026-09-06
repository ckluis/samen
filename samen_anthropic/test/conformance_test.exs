defmodule SamenAnthropic.ConformanceTest do
  @moduledoc """
  T188 — family #2 (AI provider, non-ESP, separate mix package) consumer of the shared
  `Samen.AdapterConformanceCase` kit (WS-C). `provider_test.exs` already covers
  `SamenAnthropic.Provider` end to end; this file proves the SAME two guarantees through
  the shared, cross-family kit instead of hand-rolled assertions — the generalization the
  kit exists for.
  """
  use Samen.AdapterConformanceCase, adapter: SamenAnthropic.Provider
  use ExUnit.Case, async: true

  alias Samen.AI.{Chokepoint, MaskedPayload}
  alias SamenAnthropic.Provider

  defp sealed(segments) do
    {:ok, %MaskedPayload{} = payload} = Chokepoint.seal(:complete, segments, [])
    payload
  end

  # No live HTTP call: an injected fixture transport (the samen_postmark cassette /
  # provider_test.exs precedent) keeps this hermetic — only whether the call raises
  # FunctionClauseError is under test here, never the network.
  defp fixture_transport do
    fn _request ->
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
           "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
         }
       }}
    end
  end

  describe "%MaskedPayload{}-only acceptance (shared kit)" do
    test "complete/2 accepts a sealed payload and refuses a raw one by function clause" do
      config = %{api_key: "sk-ant-xxx", transport: fixture_transport()}

      assert :ok =
               assert_masked_payload_only!(
                 fn -> Provider.complete(sealed(["hello"]), config) end,
                 fn -> apply(Provider, :complete, ["raw unmasked prompt", config]) end
               )
    end

    test "embed/2 accepts a sealed payload and refuses a raw one by function clause" do
      assert :ok =
               assert_masked_payload_only!(
                 fn -> Provider.embed(sealed(["x"]), %{api_key: "sk-ant-xxx"}) end,
                 fn -> apply(Provider, :embed, ["raw", %{api_key: "sk-ant-xxx"}]) end
               )
    end
  end

  describe "fail-honest refusal table (shared kit)" do
    test "unconfigured complete/2, unconfigured embed/2, and embed/2's honest capability absence" do
      assert :ok =
               assert_refusal_table!([
                 {"complete/2 unconfigured", fn -> Provider.complete(sealed(["hi"]), %{}) end,
                  :not_configured},
                 {"embed/2 unconfigured", fn -> Provider.embed(sealed(["hi"]), %{}) end,
                  :not_configured},
                 {"embed/2 configured but Anthropic has no embeddings endpoint",
                  fn -> Provider.embed(sealed(["hi"]), %{api_key: "sk-ant-xxx"}) end,
                  :not_implemented}
               ])
    end
  end
end
