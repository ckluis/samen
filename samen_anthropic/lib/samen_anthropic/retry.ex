defmodule SamenAnthropic.Retry do
  @moduledoc """
  Bounded retry for one Messages-API call (ADR-043 §5.1a, the 2026-11-13 amendment; AX-9).

  What is retried, and nothing else:

    * HTTP **429** (rate limited), **529** (overloaded) and every other **5xx** — the
      statuses the API documents as retryable;
    * a **connection** failure (`:econnrefused`, `:closed`, `:econnreset`, `:ehostunreach`,
      `:enetunreach`) — the request never reached the model.

  What is NOT retried: any other 4xx (the request itself is wrong — a second identical
  request fails the same way), and a **timeout**: the model may have done the work, so a
  second attempt would double the spend and the wait without telling anyone. A timeout is
  reported once, as the adapter's bounded `:provider_timeout`.

  The delay honours a `retry-after` header (seconds) when the response carries one; a
  `retry-after` longer than `:max_retry_after_ms` is not waited out — the response is
  returned and the caller reports it (`:rate_limited` / `:overloaded`) honestly instead of
  holding a run's turn for minutes. Otherwise the delay is exponential (`:base_delay_ms`,
  doubling, capped at `:max_delay_ms`) with up to 25% jitter. At most `:max_retries`
  retries (default 2, the Anthropic SDKs' default), so at most three attempts.

  `:sleep` is an injection seam (default `Process.sleep/1`) so the policy is provable
  hermetically: a test hands in a recorder and asserts every delay without waiting.
  """

  @connection_errors [:econnrefused, :closed, :econnreset, :ehostunreach, :enetunreach]

  @defaults %{
    max_retries: 2,
    base_delay_ms: 500,
    max_delay_ms: 8_000,
    max_retry_after_ms: 60_000
  }

  @doc """
  Run `attempt` (an arity-0 function returning a transport result) under the policy above.
  `config` is the adapter config; the keys read are `:max_retries`, `:base_delay_ms`,
  `:max_delay_ms`, `:max_retry_after_ms` and `:sleep`.
  """
  @spec run((-> {:ok, map()} | {:error, term()}), map()) :: {:ok, map()} | {:error, term()}
  def run(attempt, config) when is_function(attempt, 0) and is_map(config) do
    policy = Map.merge(@defaults, Map.take(config, Map.keys(@defaults)))
    sleep = Map.get(config, :sleep, &Process.sleep/1)
    loop(attempt, policy, sleep, 0)
  end

  defp loop(attempt, policy, sleep, n) do
    result = attempt.()

    with true <- n < policy.max_retries,
         {:retry, delay} <- decide(result, policy, n) do
      sleep.(delay)
      loop(attempt, policy, sleep, n + 1)
    else
      _ -> result
    end
  end

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
