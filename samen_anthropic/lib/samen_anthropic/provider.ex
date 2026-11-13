defmodule SamenAnthropic.Provider do
  @moduledoc """
  Anthropic implementation of `Samen.AI.Provider` (ADR-043 §5.1; T64/D1) — the
  reference AI-provider adapter, on the `samen_stripe`/`samen_postmark` §8.1 layout
  precedent.

  ## By-construction raw-refusal (the INV-7 seam, ADR-043 §3.2)

  Both callbacks pattern-match `%Samen.AI.MaskedPayload{}` in the function head, so a
  raw string/map cannot reach Anthropic — it refuses by `FunctionClauseError`, exactly
  the runtime clause-refusal `Samen.Type.VaultField.dump_to_native/2` ships. Since only
  `Samen.AI.Chokepoint` mints a `MaskedPayload`, no unmasked value can be forged into one
  either. This adapter therefore transmits ONLY chokepoint-sealed content: every byte of the
  request below comes from the payload's `:system`, `:turns`, `:segments` and `:tools`.

  ## Fail-honest, keyless (ADR-043 §4; ADR-014/024/026)

    * `complete/2` with NO `config[:api_key]` -> `{:error, :not_configured}` — NEVER a
      fake `{:ok, _}` (a canned success is the exact lie the sabotage harness catches).
    * `embed/2` -> `{:error, :not_implemented}` REGARDLESS of config: Anthropic has no
      embeddings endpoint, so the honest answer is "this adapter does not do that".

  ## The request (ADR-043 §5.1a, the 2026-11-13 amendment)

    * `system` — the payload's `:system` instructions, one text block, with a
      `cache_control` breakpoint (tools render before system, so this one breakpoint caches
      the tool definitions and the instructions together — both stable for an agent).
    * `messages` — the payload's role-structured `:turns`: a `tool_call` block becomes a
      `tool_use` block, a `tool_result` block a `tool_result` with the matching
      `tool_use_id` (and `is_error: true` for a failure). Tool results and tenant data are
      therefore user CONTENT, never instruction text. A payload with no turns (a single-shot
      verb) is sent exactly as before: its segments joined into one user message.
    * `tools` — each definition with its `input_schema` (`Samen.AI.Agent.Tools.input_schema/1`)
      and `tool_choice: auto` with parallel calls disabled (the loop takes one call per turn).
    * `cache_control` at the top level once the conversation has an assistant turn, so a
      multi-turn loop reads its own history prefix from the cache; a single-shot call never
      pays the cache-write premium for a prefix nobody will reuse.
    * `model` — the payload's `meta.model` (an agent definition's or a verb call's), else
      `config[:model]`, else `"claude-opus-5-5"`. `max_tokens` — `config[:max_tokens]`,
      default 16 000 (thinking counts toward it on current models; 1 024 was cut off routinely).
      `config[:effort]` sets `output_config.effort`. `config[:fallbacks]` opts into the
      server-side refusal fallback (beta) — OFF by default: which model processes tenant data
      is the operator's decision, and the completion records the model that answered.

  ## Stop reasons — only a finished answer is an `{:ok, _}`

    * `end_turn` / `stop_sequence` / `tool_use` → `{:ok, %Completion{}}` (a `tool_use` stop
      with no tool call in it is not a finished answer: `:unexpected_stop`);
    * `max_tokens` → `{:error, :truncated, usage}` — the response was cut off at its output
      limit, so it is not an answer (the moduledoc's own rule: a truncated answer is never
      handed back as a finished one), and its tokens were spent;
    * `refusal` → `{:error, :refused, usage}`;
    * `model_context_window_exceeded` → `{:error, :context_overflow, usage}` (ADR-048 §6);
    * anything else, or none → `{:error, :unexpected_stop, usage}` — unknown is an error.

  ## Context overflow (ADR-048 §6 Level 2; issue #11)

  The INPUT alone exceeding the window is a 400 `invalid_request_error` ("prompt is too
  long"): nothing was spent, so it is `{:error, :context_overflow}`. GENERATION filling the
  window is the `model_context_window_exceeded` stop above. The error message is read only to
  classify; it is never returned (EG6).

  ## Transport, timeouts, retries

  `config[:transport]` (default `SamenAnthropic.Transport.live/1`) makes ONE request with
  explicit `:connect_timeout` / `:receive_timeout` / `:request_timeout`; `SamenAnthropic.Retry`
  wraps it (429, 529, 5xx and failures to connect, bounded, honouring `retry-after`; never
  another 4xx, never a timeout or a closed/reset connection). The whole call — every attempt
  and every wait — fits `config[:call_budget_ms]` (the agent loop passes half its in-flight
  watchdog): each attempt's timeouts are capped to the time left, and no wait is taken that
  would leave too little for the next attempt. Once retries are spent: 429 → `:rate_limited`,
  529 → `:overloaded`, a timeout → `:provider_timeout`; any other API error stays the bounded
  `{:anthropic_error, status, type}` the chokepoint reduces to `:provider_error`.

  ## Usage

  With prompt caching the API splits a request's input across `input_tokens` (uncached),
  `cache_creation_input_tokens` (processed and written to the cache) and
  `cache_read_input_tokens` (served from the cache). Samen keeps two buckets (issue #74),
  because cached input costs a fraction of fresh input but still fills the window:

    * `input_tokens` — input processed FRESH: `input_tokens + cache_creation_input_tokens`;
    * `cached_input_tokens` — input SERVED from the cache: `cache_read_input_tokens`.

  A missing or non-integer field counts as 0.
  """

  @behaviour Samen.AI.Provider

  alias Samen.AI.{Completion, MaskedPayload}
  alias SamenAnthropic.{Retry, Transport}

  @default_model "claude-opus-5-5"
  @default_max_tokens 16_000
  @efforts ~w(low medium high xhigh max)
  @fallback_beta "server-side-fallback-2026-07-01"
  @ephemeral %{"type" => "ephemeral"}

  @impl Samen.AI.Provider
  def complete(%MaskedPayload{} = payload, config) when is_map(config) do
    if configured?(config) do
      do_complete(payload, config)
    else
      {:error, :not_configured}
    end
  end

  @impl Samen.AI.Provider
  def embed(%MaskedPayload{} = _payload, config) when is_map(config) do
    # Anthropic exposes no embeddings endpoint — honest capability absence, never a
    # fabricated vector. The embeddings plane (pgvector + a real deterministic/provider
    # embedder + the embeddable-field allowlist) is T67.
    if configured?(config), do: {:error, :not_implemented}, else: {:error, :not_configured}
  end

  # The Messages API takes tool definitions natively and answers with `tool_use` blocks,
  # which `complete/2` maps into `Completion.tool_calls` (ADR-047 §5.2).
  @impl Samen.AI.Provider
  def native_tools?, do: true

  @doc """
  Is the adapter configured to actually dispatch? True only when a non-empty
  `:api_key` is present. This is the single source of truth for the fail-honest gate.
  """
  @spec configured?(map()) :: boolean()
  def configured?(config) when is_map(config), do: present?(config, :api_key)
  def configured?(_), do: false

  @doc """
  The exact Messages-API request body `complete/2` sends for `payload` under `config` —
  public so the request shape is asserted byte-for-byte without a network.
  """
  @spec request_body(MaskedPayload.t(), map()) :: map()
  def request_body(%MaskedPayload{} = payload, config) when is_map(config) do
    %{
      "model" => model(payload, config),
      "max_tokens" => Map.get(config, :max_tokens, @default_max_tokens),
      "messages" => messages(payload)
    }
    |> put_system(payload.system)
    |> put_tools(payload.tools)
    |> put_conversation_cache(payload.turns)
    |> put_effort(Map.get(config, :effort))
    |> put_fallbacks(Map.get(config, :fallbacks))
  end

  # ---------------------------------------------------------------------------

  defp do_complete(%MaskedPayload{} = payload, config) do
    transport = Map.get(config, :transport, &Transport.live/1)
    body = request_body(payload, config)

    request = %{
      api_key: Map.fetch!(config, :api_key),
      body: body,
      anthropic_version: Map.get(config, :anthropic_version),
      connect_timeout: Map.get(config, :connect_timeout),
      receive_timeout: Map.get(config, :receive_timeout),
      betas: if(Map.has_key?(body, "fallbacks"), do: [@fallback_beta], else: [])
    }

    fn remaining_ms -> transport.(within(request, remaining_ms)) end
    |> Retry.run(config)
    |> handle_response(body["model"])
  end

  # One attempt may take at most what is left of the call's budget: connect within (at most
  # half of) it, and the whole response within the rest (`receive_timeout` bounds each wait for
  # data, `request_timeout` the response as a whole) — connect + response <= remaining.
  defp within(request, remaining_ms) do
    configured = request.connect_timeout || Transport.default_connect_timeout()
    connect = max(min(configured, div(remaining_ms, 2)), 1)
    rest = max(remaining_ms - connect, 1)
    receive = min(request.receive_timeout || Transport.default_receive_timeout(), rest)

    request
    |> Map.put(:connect_timeout, connect)
    |> Map.put(:receive_timeout, receive)
    |> Map.put(:request_timeout, rest)
  end

  # Field-less match + dot access on purpose (the single-mint anti-bypass probe
  # convention: only Samen.AI.Chokepoint uses a field-bearing %MaskedPayload{...} literal).
  defp model(%MaskedPayload{} = payload, config) do
    case payload.meta do
      %{model: model} when is_binary(model) -> model
      _ -> Map.get(config, :model, @default_model)
    end
  end

  # The role-structured conversation when the kernel sent one; else the pre-amendment
  # shape, byte for byte: every sealed segment joined into ONE user message.
  defp messages(%MaskedPayload{} = payload) do
    case payload.turns do
      [_ | _] = turns ->
        Enum.map(turns, &message/1)

      _none ->
        text = payload.segments |> Enum.map(&to_string/1) |> Enum.join("\n")
        [%{"role" => "user", "content" => text}]
    end
  end

  defp message(%{"role" => role, "content" => blocks}),
    do: %{"role" => role, "content" => Enum.map(blocks, &block/1)}

  defp block(%{"type" => "text", "text" => text}), do: %{"type" => "text", "text" => text}

  defp block(%{"type" => "tool_call", "id" => id, "name" => name, "input" => input}),
    do: %{"type" => "tool_use", "id" => id, "name" => name, "input" => input}

  defp block(%{"type" => "tool_result", "id" => id, "content" => content, "is_error" => error?}) do
    result = %{"type" => "tool_result", "tool_use_id" => id, "content" => content}
    if error?, do: Map.put(result, "is_error", true), else: result
  end

  defp put_system(body, [_ | _] = system) do
    Map.put(body, "system", [
      %{"type" => "text", "text" => Enum.join(system, "\n\n"), "cache_control" => @ephemeral}
    ])
  end

  defp put_system(body, _none), do: body

  defp put_tools(body, [_ | _] = tools) do
    defs =
      Enum.map(tools, fn def ->
        %{
          "name" => Map.get(def, :name),
          "description" => Map.get(def, :description),
          "input_schema" => Samen.AI.Agent.Tools.input_schema(def)
        }
      end)

    # With no system prompt the tool list is the whole stable prefix: mark its end.
    defs = if Map.has_key?(body, "system"), do: defs, else: mark_last(defs)

    body
    |> Map.put("tools", defs)
    |> Map.put("tool_choice", %{"type" => "auto", "disable_parallel_tool_use" => true})
  end

  defp put_tools(body, _none), do: body

  defp mark_last(defs) do
    List.update_at(defs, -1, &Map.put(&1, "cache_control", @ephemeral))
  end

  defp put_conversation_cache(body, turns) when is_list(turns) do
    if Enum.any?(turns, &(&1["role"] == "assistant")),
      do: Map.put(body, "cache_control", @ephemeral),
      else: body
  end

  defp put_conversation_cache(body, _turns), do: body

  defp put_effort(body, effort) when effort in @efforts,
    do: Map.put(body, "output_config", %{"effort" => effort})

  defp put_effort(body, _effort), do: body

  defp put_fallbacks(body, "default"), do: Map.put(body, "fallbacks", "default")

  defp put_fallbacks(body, [_ | _] = fallbacks) do
    if Enum.all?(fallbacks, &match?(%{"model" => m} when is_binary(m), &1)),
      do: Map.put(body, "fallbacks", fallbacks),
      else: body
  end

  defp put_fallbacks(body, _none), do: body

  # --- responses ---------------------------------------------------------------

  defp handle_response({:ok, %{status: 200, body: %{} = body}}, model) do
    usage = normalize_usage(Map.get(body, "usage", %{}))

    case Map.get(body, "stop_reason") do
      reason when reason in ["end_turn", "stop_sequence", "tool_use"] ->
        completion(body, reason, usage, model)

      # Generation filled the context window: truncated, and it spent tokens.
      "model_context_window_exceeded" ->
        {:error, :context_overflow, usage}

      # Cut off at the output limit: not an answer, and the tokens were spent.
      "max_tokens" ->
        {:error, :truncated, usage}

      "refusal" ->
        {:error, :refused, usage}

      # `pause_turn` (a server-tool loop this adapter never starts), a new reason, or none.
      _unknown ->
        {:error, :unexpected_stop, usage}
    end
  end

  # The input alone exceeds the window: rejected before any work, no usage reported.
  defp handle_response(
         {:ok,
          %{
            status: 400,
            body: %{"error" => %{"type" => "invalid_request_error", "message" => message}}
          }},
         _model
       )
       when is_binary(message) do
    if prompt_too_long?(message),
      do: {:error, :context_overflow},
      else: {:error, {:anthropic_error, 400, "invalid_request_error"}}
  end

  # Retries are spent (or the server asked for a wait longer than the policy allows).
  defp handle_response({:ok, %{status: 429}}, _model), do: {:error, :rate_limited}
  defp handle_response({:ok, %{status: 529}}, _model), do: {:error, :overloaded}

  defp handle_response({:ok, %{status: status, body: %{"error" => %{"type" => type}}}}, _model)
       when is_binary(type) do
    # EG6: surface a bounded, content-free error — never echo the request/prompt.
    {:error, {:anthropic_error, status, type}}
  end

  defp handle_response({:ok, %{status: status}}, _model) do
    {:error, {:unexpected_response, status}}
  end

  defp handle_response({:error, reason}, _model) do
    if Retry.transport_reason(reason) == :timeout,
      do: {:error, :provider_timeout},
      else: {:error, reason}
  end

  defp completion(%{"content" => content} = body, reason, usage, model) when is_list(content) do
    tool_calls = tool_calls(content)

    if reason == "tool_use" and tool_calls == [] do
      {:error, :unexpected_stop, usage}
    else
      {:ok,
       %Completion{
         text: extract_text(content),
         model: Map.get(body, "model", model),
         provider: :anthropic,
         usage: usage,
         meta: %{stop_reason: reason},
         tool_calls: tool_calls
       }}
    end
  end

  defp completion(_body, _reason, _usage, _model), do: {:error, {:unexpected_response, 200}}

  defp extract_text(content) do
    content
    |> Enum.filter(&(is_map(&1) and Map.get(&1, "type") == "text"))
    |> Enum.map_join("", &Map.get(&1, "text", ""))
  end

  # Every `tool_use` block, in order, in the bounded `Completion.tool_calls` shape. The
  # input is passed as given: a non-object input reaches the loop as a malformed call
  # (`:invalid_tool_call`), never as "no arguments".
  defp tool_calls(content) do
    for %{"type" => "tool_use", "name" => name} = block <- content, is_binary(name) do
      %{"id" => Map.get(block, "id"), "name" => name, "args" => Map.get(block, "input", %{})}
    end
  end

  defp prompt_too_long?(message),
    do: message |> String.downcase() |> String.contains?("prompt is too long")

  # All three input fields count toward the window (see the moduledoc).
  defp normalize_usage(usage) when is_map(usage) do
    %{
      input_tokens: count(usage, "input_tokens") + count(usage, "cache_creation_input_tokens"),
      cached_input_tokens: count(usage, "cache_read_input_tokens"),
      output_tokens: count(usage, "output_tokens")
    }
  end

  defp normalize_usage(_usage), do: %{input_tokens: 0, cached_input_tokens: 0, output_tokens: 0}

  defp count(usage, key) do
    case Map.get(usage, key) do
      n when is_integer(n) and n >= 0 -> n
      _ -> 0
    end
  end

  defp present?(config, key) do
    case Map.get(config, key) do
      nil -> false
      "" -> false
      _ -> true
    end
  end
end
