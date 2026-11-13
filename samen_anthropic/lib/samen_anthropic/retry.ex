defmodule SamenAnthropic.Retry do
  @moduledoc """
  Bounded retry for one Messages-API call (ADR-043 §5.1a, the 2026-11-13 amendment; AX-9).

  What is retried, and nothing else:

    * HTTP **429** (rate limited), **529** (overloaded) and every other **5xx** — the
      statuses the API documents as retryable;
    * a failure to CONNECT (`:econnrefused`, `:ehostunreach`, `:enetunreach`) — the request
      provably never left this host, so the model never saw it.

  What is NOT retried: any other 4xx (the request itself is wrong — a second identical
  request fails the same way); a **timeout**, and a connection **closed or reset**
  (`:closed`, `:econnreset`): the request may have reached the model, which may have done
  the work (and billed it), so a second attempt could run — and pay for — the same generation
  twice without telling anyone. Those are reported once, honestly (`:provider_timeout` for a
  timeout).

  ## One deadline for the whole call

  Every attempt, every retry and every wait between them fit inside ONE budget,
  `config[:call_budget_ms]` (`Samen.AI.Provider`, "The call budget"; the agent loop passes
  half its in-flight watchdog, `Samen.AI.Agent.provider_call_budget_ms/0`). The default, for
  a caller that passes none, is the transport's single-attempt receive timeout
  (`SamenAnthropic.Transport.default_receive_timeout/0`). Each attempt is handed the time
  left (`attempt.(remaining_ms)`) and the adapter caps that attempt's connect, receive and
  total-response timeouts to it; a wait is taken only when at least `:min_attempt_ms` would be
  left for the next attempt after it — otherwise the last result is returned as it is. So,
  given a transport that honours its timeouts, the call ends within the budget.

  The delay honours a `retry-after` header (seconds) when the response carries one; a
  `retry-after` longer than `:max_retry_after_ms` is not waited out — the response is
  returned and the caller reports it (`:rate_limited` / `:overloaded`) honestly instead of
  holding a run's turn for minutes. Otherwise the delay is exponential (`:base_delay_ms`,
  doubling, capped at `:max_delay_ms`) with up to 25% jitter. At most `:max_retries`
  retries (default 2, the Anthropic SDKs' default), so at most three attempts.

  `:sleep` (default `Process.sleep/1`) and `:clock` (default monotonic milliseconds) are
  injection seams, so the policy and the deadline are provable hermetically: a test hands in
  a fake clock and a recorder and asserts every delay and every budget without waiting.
  """

  @connection_errors [:econnrefused, :ehostunreach, :enetunreach]

  @defaults %{
    max_retries: 2,
    base_delay_ms: 500,
    max_delay_ms: 8_000,
    max_retry_after_ms: 60_000,
    min_attempt_ms: 5_000
  }

  @doc """
  Run `attempt` under the policy above. `attempt` is an arity-1 function given the
  milliseconds left in the call's budget (an arity-0 function is accepted too) and returning a
  transport result. `config` is the adapter config; the keys read are `:call_budget_ms`,
  `:max_retries`, `:base_delay_ms`, `:max_delay_ms`, `:max_retry_after_ms`, `:min_attempt_ms`,
  `:sleep` and `:clock`.
  """
  @spec run(
          (non_neg_integer() -> {:ok, map()} | {:error, term()})
          | (-> {:ok, map()} | {:error, term()}),
          map()
        ) ::
          {:ok, map()} | {:error, term()}
  def run(attempt, config)
      when (is_function(attempt, 1) or is_function(attempt, 0)) and is_map(config) do
    policy = Map.merge(@defaults, Map.take(config, Map.keys(@defaults)))
    sleep = Map.get(config, :sleep, &Process.sleep/1)
    clock = Map.get(config, :clock, fn -> System.monotonic_time(:millisecond) end)
    deadline = clock.() + call_budget_ms(config)
    loop(attempt, policy, %{sleep: sleep, clock: clock, deadline: deadline}, 0)
  end

  @doc """
  The budget one call runs under: `config[:call_budget_ms]` when it is a positive integer,
  else one attempt's default receive timeout.
  """
  @spec call_budget_ms(map()) :: pos_integer()
  def call_budget_ms(config) do
    case Map.get(config, :call_budget_ms) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> SamenAnthropic.Transport.default_receive_timeout()
    end
  end

  defp loop(attempt, policy, t, n) do
    result = call(attempt, t.deadline - t.clock.())

    with true <- n < policy.max_retries,
         {:retry, delay} <- decide(result, policy, n),
         true <- t.clock.() + delay + policy.min_attempt_ms <= t.deadline do
      t.sleep.(delay)
      loop(attempt, policy, t, n + 1)
    else
      _ -> result
    end
  end

  defp call(attempt, remaining) when is_function(attempt, 1), do: attempt.(max(remaining, 1))
  defp call(attempt, _remaining), do: attempt.()

  @doc false
  # Public for the policy tests: `{:retry, delay_ms}` or `:stop` for one result.
  @spec decide({:ok, map()} | {:error, term()}, map(), non_neg_integer()) ::
          {:retry, non_neg_integer()} | :stop
  def decide({:ok, %{status: status} = response}, policy, n)
      when status == 429 or status in 500..599 do
    case retry_after_ms(response) do
      nil -> {:retry, backoff(policy, n)}
      ms when ms <= policy.max_retry_after_ms -> {:retry, ms}
      _too_long -> :stop
    end
  end

  def decide({:error, reason}, policy, n) do
    if transport_reason(reason) in @connection_errors,
      do: {:retry, backoff(policy, n)},
      else: :stop
  end

  def decide(_result, _policy, _n), do: :stop

  @doc """
  The bare reason of a transport failure — an atom as given, or the `:reason` of an
  exception struct (`Req.TransportError`, `Mint.TransportError`). Anything else is `nil`.
  """
  @spec transport_reason(term()) :: atom() | nil
  def transport_reason(reason) when is_atom(reason), do: reason
  def transport_reason(%{__exception__: true, reason: reason}) when is_atom(reason), do: reason
  def transport_reason(_reason), do: nil

  defp backoff(policy, n) do
    full = min(policy.base_delay_ms * Integer.pow(2, n), policy.max_delay_ms)
    full - :rand.uniform(div(full, 4) + 1) + 1
  end

  # `retry-after` in whole or fractional seconds. An HTTP-date or anything unparseable is
  # ignored (the exponential backoff applies), never guessed at.
  defp retry_after_ms(response) do
    case header(response, "retry-after") do
      nil ->
        nil

      value ->
        case Float.parse(String.trim(value)) do
          {seconds, ""} when seconds >= 0 -> round(seconds * 1000)
          _ -> nil
        end
    end
  end

  defp header(%{headers: headers}, name) when is_map(headers) do
    case Map.get(headers, name) do
      [value | _] when is_binary(value) -> value
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp header(%{headers: headers}, name) when is_list(headers) do
    Enum.find_value(headers, fn
      {key, value} when is_binary(key) and is_binary(value) ->
        if String.downcase(key) == name, do: value

      _ ->
        nil
    end)
  end

  defp header(_response, _name), do: nil
end
