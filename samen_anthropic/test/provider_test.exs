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
           "model" => "claude-opus-5-5",
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
        model: "claude-opus-5-5",
        transport: fixture_transport(self())
      }

      assert {:ok,
              %Completion{
                provider: :anthropic,
                text: "fixture completion",
                model: "claude-opus-5-5"
              }} =
               Provider.complete(sealed(["summarize the account"]), config)

      # The outbound request carries the sealed segment text in a user message and the
      # configured api_key/model — proving the request builder actually ran.
      assert_received {:anthropic_request, request}
      assert request.api_key == "sk-ant-xxx"
      assert request.body["model"] == "claude-opus-5-5"
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

    test "a connection failure is retried (bounded), then surfaced as-is" do
      me = self()

      failing = fn _request ->
        send(me, :attempt)
        {:error, :econnrefused}
      end

      config = %{api_key: "sk-ant-xxx", transport: failing, sleep: &send(me, {:slept, &1})}
      assert {:error, :econnrefused} = Provider.complete(sealed(["p"]), config)

      # the default policy: 2 retries, so 3 attempts and 2 waits
      assert_received :attempt
      assert_received :attempt
      assert_received :attempt
      refute_received :attempt
      assert_received {:slept, _}
      assert_received {:slept, _}
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
        "model" => "claude-opus-5-5",
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

      assert result ==
               {:error, :context_overflow,
                %{input_tokens: 900, cached_input_tokens: 0, output_tokens: 48}}

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
               {:error, :context_overflow,
                %{input_tokens: 900, cached_input_tokens: 0, output_tokens: 48}}

      assert Chokepoint.complete(Provider, config, :complete, ["p"], []) ==
               {:error, :context_overflow}
    end
  end

  describe "usage (issue #11)" do
    test "cached input is its own bucket — fresh = uncached + cache write, cached = cache read (issue #74)" do
      usage = %{
        "input_tokens" => 40,
        "cache_creation_input_tokens" => 1_000,
        "cache_read_input_tokens" => 20_000,
        "output_tokens" => 7
      }

      assert {:error, :context_overflow,
              %{input_tokens: 1_040, cached_input_tokens: 20_000, output_tokens: 7}} =
               complete_with(window_exceeded(usage))
    end

    test "a missing or malformed count is 0, never a guess" do
      assert {:error, :context_overflow,
              %{input_tokens: 5, cached_input_tokens: 0, output_tokens: 0}} =
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

  # ---------------------------------------------------------------------------
  # Stop reasons (2026-11-13): only a finished answer is an {:ok, _}

  defp stopped(
         reason,
         content \\ [%{"type" => "text", "text" => "partial answer about " <> @canary}]
       ) do
    %{
      status: 200,
      body: %{
        "model" => "claude-opus-5-5",
        "stop_reason" => reason,
        "content" => content,
        "usage" => %{"input_tokens" => 30, "output_tokens" => 16_000}
      }
    }
  end

  @spent %{input_tokens: 30, cached_input_tokens: 0, output_tokens: 16_000}

  describe "stop reasons" do
    test "max_tokens is NOT a finished answer: a usage-carrying :truncated, the text never handed back" do
      result = complete_with(stopped("max_tokens"))
      assert result == {:error, :truncated, @spent}
      refute inspect(result) =~ "Lovelace"
    end

    test "refusal is a usage-carrying :refused" do
      assert complete_with(stopped("refusal")) == {:error, :refused, @spent}
    end

    test "an unknown stop reason, a missing one, or pause_turn is an error, never a success" do
      for reason <- ["a_new_reason", nil, "pause_turn"] do
        assert complete_with(stopped(reason)) == {:error, :unexpected_stop, @spent}
      end
    end

    test "a tool_use stop with no tool_use block in it is not a finished answer" do
      assert complete_with(stopped("tool_use")) == {:error, :unexpected_stop, @spent}
    end

    test "end_turn and stop_sequence are completions (positive control)" do
      for reason <- ["end_turn", "stop_sequence"] do
        assert {:ok, %Completion{meta: %{stop_reason: ^reason}, tool_calls: []}} =
                 complete_with(stopped(reason))
      end
    end

    test "tool_use blocks map into Completion.tool_calls with their ids, in order" do
      content = [
        %{"type" => "thinking", "thinking" => ""},
        %{"type" => "text", "text" => "Let me look."},
        %{
          "type" => "tool_use",
          "id" => "toolu_A",
          "name" => "fetch_record",
          "input" => %{"id" => "x"}
        }
      ]

      assert {:ok, %Completion{text: "Let me look.", tool_calls: calls, model: "claude-opus-5-5"}} =
               complete_with(stopped("tool_use", content))

      assert calls == [%{"id" => "toolu_A", "name" => "fetch_record", "args" => %{"id" => "x"}}]
    end
  end

  # ---------------------------------------------------------------------------
  # Retries and bounded error kinds (2026-11-13; AX-9)

  defp scripted_transport(responses) do
    me = self()
    {:ok, agent} = Agent.start_link(fn -> responses end)

    fn request ->
      send(me, {:attempt, request})
      Agent.get_and_update(agent, fn [r | rest] -> {r, if(rest == [], do: [r], else: rest)} end)
    end
  end

  defp retrying(responses, extra \\ %{}) do
    me = self()

    Provider.complete(
      sealed(["p"]),
      Map.merge(
        %{
          api_key: "sk-ant-x",
          transport: scripted_transport(responses),
          sleep: &send(me, {:slept, &1})
        },
        extra
      )
    )
  end

  defp attempts, do: count_received(:attempt)
  defp sleeps, do: collect_received(:slept)

  defp count_received(tag) do
    receive do
      {^tag, _} -> 1 + count_received(tag)
    after
      0 -> 0
    end
  end

  defp collect_received(tag) do
    receive do
      {^tag, value} -> [value | collect_received(tag)]
    after
      0 -> []
    end
  end

  defp status(code, headers \\ %{}),
    do:
      {:ok,
       %{status: code, headers: headers, body: %{"error" => %{"type" => "overloaded_error"}}}}

  describe "retries" do
    test "a 529 then success: retried once, the completion returned" do
      assert {:ok, %Completion{text: "ok"}} =
               retrying([
                 status(529),
                 {:ok,
                  %{
                    status: 200,
                    body: %{
                      "stop_reason" => "end_turn",
                      "content" => [%{"type" => "text", "text" => "ok"}]
                    }
                  }}
               ])

      assert attempts() == 2
      assert [delay] = sleeps()
      assert delay in 375..500
    end

    test "429 honours retry-after (seconds), from a map or a list of headers" do
      for headers <- [%{"retry-after" => ["3"]}, [{"Retry-After", "3"}]] do
        assert {:error, :rate_limited} = retrying([status(429, headers)])
        assert attempts() == 3
        assert sleeps() == [3_000, 3_000]
      end
    end

    test "a retry-after longer than the policy allows is not waited out: :rate_limited at once" do
      assert {:error, :rate_limited} = retrying([status(429, %{"retry-after" => ["600"]})])
      assert attempts() == 1
      assert sleeps() == []
    end

    test "persistent 529 / 500 end as the bounded kinds after max_retries" do
      assert {:error, :overloaded} = retrying([status(529)])
      assert attempts() == 3

      assert {:error, {:anthropic_error, 500, "overloaded_error"}} =
               retrying([status(500)], %{max_retries: 1})

      assert attempts() == 2
    end

    test "backoff doubles and is capped" do
      assert {:error, :overloaded} =
               retrying([status(529)], %{max_retries: 4, base_delay_ms: 100, max_delay_ms: 300})

      assert [d1, d2, d3, d4] = sleeps()
      assert d1 in 75..100 and d2 in 150..200 and d3 in 225..300 and d4 in 225..300
    end

    test "no retry on any other 4xx" do
      for code <- [400, 401, 403, 404, 408, 409, 413] do
        assert {:error, {:anthropic_error, ^code, _}} = retrying([status(code)])
        assert attempts() == 1
      end
    end

    test "a timeout is NOT retried (the work may have been done) and is the bounded :provider_timeout" do
      assert {:error, :provider_timeout} =
               retrying([{:error, %Req.TransportError{reason: :timeout}}])

      assert attempts() == 1
      assert {:error, :provider_timeout} = retrying([{:error, :timeout}])
      assert attempts() == 1
      # and a connection failure wrapped the same way IS retried
      assert {:error, %Req.TransportError{reason: :econnrefused}} =
               retrying([{:error, %Req.TransportError{reason: :econnrefused}}])

      assert attempts() == 3
    end

    test "the request is identical on every attempt — only its timeouts shrink to the budget left" do
      assert {:error, :overloaded} = retrying([status(529)])
      assert_received {:attempt, first}
      assert_received {:attempt, second}
      timeouts = [:connect_timeout, :receive_timeout, :request_timeout]
      assert Map.drop(first, timeouts) == Map.drop(second, timeouts)
      for key <- timeouts, do: assert(second[key] <= first[key])
    end

    test "a connection closed or reset is NOT retried (the model may have done the work); a failure to connect is" do
      for reason <- [:closed, :econnreset] do
        assert {:error, %Req.TransportError{reason: ^reason}} =
                 retrying([{:error, %Req.TransportError{reason: reason}}])

        assert attempts() == 1
        assert {:error, ^reason} = retrying([{:error, reason}])
        assert attempts() == 1
      end

      for reason <- [:econnrefused, :ehostunreach, :enetunreach] do
        assert {:error, ^reason} = retrying([{:error, reason}])
        assert attempts() == 3
      end
    end
  end

  describe "one deadline for the whole call (the agent watchdog cannot re-pick a turn mid-call)" do
    # A fake monotonic clock in the test process: the transport and `sleep` ADVANCE it, so a
    # call that would take minutes runs in microseconds and its elapsed time is exact.
    defp fake_clock do
      Process.put(:fake_now, 0)
      fn -> Process.get(:fake_now) end
    end

    defp advance(ms), do: Process.put(:fake_now, Process.get(:fake_now) + ms)

    # The worst an HONEST transport can do: use every millisecond its timeouts allow (or a
    # given share of them), then answer `response`.
    defp slow_transport(responses, share) do
      me = self()
      {:ok, agent} = Agent.start_link(fn -> responses end)

      fn request ->
        send(me, {:attempt, request, Process.get(:fake_now)})
        allowed = request.connect_timeout + request.request_timeout
        advance(round(allowed * share.()))
        Agent.get_and_update(agent, fn [r | rest] -> {r, if(rest == [], do: [r], else: rest)} end)
      end
    end

    defp timed_call(responses, config, share \\ fn -> 1.0 end) do
      clock = fake_clock()

      result =
        Provider.complete(
          sealed(["p"]),
          Map.merge(
            %{
              api_key: "sk-ant-x",
              transport: slow_transport(responses, share),
              clock: clock,
              sleep: fn ms ->
                send(self(), {:slept, ms})
                advance(ms)
              end
            },
            config
          )
        )

      {result, clock.()}
    end

    defp attempts_with_start do
      receive do
        {:attempt, request, at} -> [{request, at} | attempts_with_start()]
      after
        0 -> []
      end
    end

    test "the agent loop's budget holds across retries and sleeps, and ends below the watchdog" do
      budget = Samen.AI.Agent.provider_call_budget_ms()
      watchdog_ms = Samen.AI.Agent.inflight_watchdog_seconds() * 1000

      # Before the deadline: three 300 s attempts plus two 60 s retry-after waits = 1,020 s,
      # past the 600 s watchdog.
      {result, elapsed} =
        timed_call([status(529, %{"retry-after" => ["60"]})], %{call_budget_ms: budget})

      assert result == {:error, :overloaded}
      assert elapsed <= budget
      assert elapsed < watchdog_ms
    end

    test "every attempt is capped to the time left, and no wait is taken that leaves too little for the next" do
      # Seeded, so a failure reproduces. 500 scenarios: random budgets (the agent's among
      # them), retry policies, statuses, retry-after values and transport speeds.
      :rand.seed(:exsss, {2026, 11, 13})

      for _ <- 1..500 do
        budget =
          Enum.random([Samen.AI.Agent.provider_call_budget_ms(), Enum.random(1_000..700_000)])

        responses =
          for _ <- 1..5 do
            Enum.random([
              status(529),
              status(500),
              status(429, %{"retry-after" => [to_string(Enum.random(0..90))]}),
              {:error, :econnrefused},
              {:ok, %{status: 200, body: %{"stop_reason" => "end_turn", "content" => []}}}
            ])
          end

        config = %{
          call_budget_ms: budget,
          max_retries: Enum.random(0..4),
          connect_timeout: Enum.random([nil, 2_000, 10_000]),
          receive_timeout: Enum.random([nil, 90_000, 300_000, 900_000])
        }

        {_result, elapsed} = timed_call(responses, config, fn -> Enum.random([0.0, 0.5, 1.0]) end)

        assert elapsed <= budget, "#{inspect(config)}: #{elapsed} ms > #{budget} ms"

        for {request, started_at} <- attempts_with_start() do
          left = budget - started_at
          assert request.connect_timeout + request.request_timeout <= max(left, 1) + 1
          assert request.receive_timeout <= request.request_timeout
        end

        _ = sleeps()
      end
    end

    test "with no budget given the call is bounded by one attempt's default receive timeout" do
      {result, elapsed} = timed_call([status(529)], %{})
      assert result == {:error, :overloaded}
      assert elapsed <= SamenAnthropic.Transport.default_receive_timeout()
    end

    test "a budget smaller than a retry-after is not slept through: the response is returned at once" do
      {result, elapsed} =
        timed_call([status(429, %{"retry-after" => ["30"]})], %{call_budget_ms: 20_000}, fn ->
          0.0
        end)

      assert result == {:error, :rate_limited}
      assert sleeps() == []
      assert elapsed == 0
      assert [_one] = attempts_with_start()
    end
  end

  describe "transport options (explicit timeouts, Req-level retry off)" do
    test "defaults: 10 s connect, 300 s receive, retry: false, the current API version" do
      opts = SamenAnthropic.Transport.req_options(%{api_key: "k", body: %{}})
      assert opts[:connect_options] == [timeout: 10_000]
      assert opts[:receive_timeout] == 300_000
      assert opts[:request_timeout] == :infinity
      assert opts[:retry] == false
      assert {"anthropic-version", "2026-10-21"} in opts[:headers]
      refute Enum.any?(opts[:headers], &match?({"anthropic-beta", _}, &1))
    end

    test "configured timeouts and betas flow from the provider config into the transport request" do
      me = self()

      transport = fn request ->
        send(me, {:request, request})
        {:ok, %{status: 200, body: %{"stop_reason" => "end_turn", "content" => []}}}
      end

      assert {:ok, _} =
               Provider.complete(sealed(["p"]), %{
                 api_key: "k",
                 transport: transport,
                 connect_timeout: 2_000,
                 receive_timeout: 90_000
               })

      assert_received {:request, request}
      opts = SamenAnthropic.Transport.req_options(Map.put(request, :betas, ["b1", "b2"]))
      assert opts[:connect_options] == [timeout: 2_000]
      assert opts[:receive_timeout] == 90_000
      assert {"anthropic-beta", "b1,b2"} in opts[:headers]
    end
  end
end
