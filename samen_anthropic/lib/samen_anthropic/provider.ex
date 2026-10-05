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
  either. This adapter therefore transmits ONLY chokepoint-sealed segments.

  ## Fail-honest, keyless (ADR-043 §4; ADR-014/024/026)

    * `complete/2` with NO `config[:api_key]` -> `{:error, :not_configured}` — NEVER a
      fake `{:ok, _}` (a canned success is the exact lie the sabotage harness catches).
    * `embed/2` -> `{:error, :not_implemented}` REGARDLESS of config: Anthropic has no
      embeddings endpoint, so the honest answer is "this adapter does not do that"
      (the embeddings plane + a real embedder are T67).

  ## `complete/2` — real HTTP mechanics, hermetic tests

  `complete/2` builds the real Anthropic Messages-API request from the sealed payload's
  segments and dispatches via `config[:transport]` (default `SamenAnthropic.Transport.live/1`).
  A host wires a real `api_key` and the live transport is exercised ONLY behind
  `SAMEN_AI_LIVE=1` (ADR-043 §4) — the test suite injects a fixture transport so `mix test`
  makes zero live calls (the samen_postmark cassette precedent).

  ## Context overflow (ADR-048 §6 Level 2; issue #11)

  The Messages API signals an overflowing context two ways, and both map to the bounded
  `:context_overflow` kind the agent loop's Level 2 recovery keys on:

    * the INPUT alone exceeds the model's window — a 400 `invalid_request_error`
      ("prompt is too long"). The request is rejected before any work is done and the
      error body carries no usage, so this is `{:error, :context_overflow}`: nothing was
      spent, and nothing is invented;
    * GENERATION fills the window — an HTTP 200 with `stop_reason:
      "model_context_window_exceeded"`. The docs say to treat that response as
      truncated, and it reports what it spent, so it is NOT a completion: it is
      `{:error, :context_overflow, usage}`, the failed attempt whose tokens still count
      (ADR-048 §6 Level 2 constraint 1). A truncated answer is never handed back as a
      finished one.

  The error message is read only to classify; it is never returned (EG6).

  ## Usage

  `input_tokens` is the input the request was billed for. With prompt caching the API
  splits it across `input_tokens`, `cache_creation_input_tokens` and
  `cache_read_input_tokens`, and all three count toward the context window, so the
  reported `input_tokens` is their sum (a missing or non-integer field counts as 0).
  """

  @behaviour Samen.AI.Provider

  alias Samen.AI.{Completion, MaskedPayload}
  alias SamenAnthropic.Transport

  @default_model "claude-opus-5"
  @default_max_tokens 1024

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

  @doc """
  Is the adapter configured to actually dispatch? True only when a non-empty
  `:api_key` is present. This is the single source of truth for the fail-honest gate.
  """
  @spec configured?(map()) :: boolean()
  def configured?(config) when is_map(config), do: present?(config, :api_key)
  def configured?(_), do: false

  # ---------------------------------------------------------------------------

  defp do_complete(%MaskedPayload{} = payload, config) do
    transport = Map.get(config, :transport, &Transport.live/1)
    model = Map.get(config, :model, @default_model)

    body = %{
      "model" => model,
      "max_tokens" => Map.get(config, :max_tokens, @default_max_tokens),
      "messages" => build_messages(payload)
    }

    request = %{
      api_key: Map.fetch!(config, :api_key),
      body: body,
      anthropic_version: Map.get(config, :anthropic_version, "2023-06-01")
    }

    transport.(request) |> handle_response(model)
  end

  # The sealed segments are the already-scrubbed prompt text (T65 owns the full
  # resolve/assemble pipeline that produces them). Join them into a single user
  # message for the Messages API.
  # Field-less match + dot access on purpose (the single-mint anti-bypass probe
  # convention: only Samen.AI.Chokepoint uses a field-bearing %MaskedPayload{...} literal).
  defp build_messages(%MaskedPayload{} = payload) do
    text = payload.segments |> Enum.map(&to_string/1) |> Enum.join("\n")
    [%{"role" => "user", "content" => text}]
  end

  # Generation filled the context window: truncated, and it spent tokens — the
  # usage-carrying overflow (see the moduledoc). Ordered before the success clause.
  defp handle_response(
         {:ok, %{status: 200, body: %{"stop_reason" => "model_context_window_exceeded"} = body}},
         _model
       ) do
    {:error, :context_overflow, normalize_usage(Map.get(body, "usage", %{}))}
  end

  defp handle_response({:ok, %{status: 200, body: %{"content" => content} = body}}, model)
       when is_list(content) do
    {:ok,
     %Completion{
       text: extract_text(content),
       model: Map.get(body, "model", model),
       provider: :anthropic,
       usage: normalize_usage(Map.get(body, "usage", %{})),
       meta: %{stop_reason: Map.get(body, "stop_reason")}
     }}
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

  defp handle_response({:ok, %{status: status, body: %{"error" => %{"type" => type}}}}, _model) do
    # EG6: surface a bounded, content-free error — never echo the request/prompt.
    {:error, {:anthropic_error, status, type}}
  end

  defp handle_response({:ok, %{status: status}}, _model) do
    {:error, {:unexpected_response, status}}
  end

  defp handle_response({:error, reason}, _model), do: {:error, reason}

  defp extract_text(content) do
    content
    |> Enum.filter(&(is_map(&1) and Map.get(&1, "type") == "text"))
    |> Enum.map_join("", &Map.get(&1, "text", ""))
  end

  defp prompt_too_long?(message),
    do: message |> String.downcase() |> String.contains?("prompt is too long")

  # All three input fields count toward the window (see the moduledoc).
  defp normalize_usage(usage) when is_map(usage) do
    %{
      input_tokens:
        count(usage, "input_tokens") + count(usage, "cache_creation_input_tokens") +
          count(usage, "cache_read_input_tokens"),
      output_tokens: count(usage, "output_tokens")
    }
  end

  defp normalize_usage(_usage), do: %{input_tokens: 0, output_tokens: 0}

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
