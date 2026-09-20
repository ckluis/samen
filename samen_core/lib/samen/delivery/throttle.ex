defmodule Samen.Delivery.Throttle do
  @moduledoc """
  `Samen.Delivery.Throttle` — the ONE place that decides what an ESP throttle response
  means and how long to wait (backlog `T170`, bug half).

  ## The bug this closes

  None of the shipped ESP adapter packages recognised a throttle response: a `429` fell
  through each provider's generic `handle_response/1` clause and became an ordinary
  vendor-error tuple. The delivery Oban workers return that to Oban verbatim, so Oban
  retried on its ordinary exponential schedule — **against an account that had just said
  "you are sending too fast"** — burning one of 20 attempts per hammer. That is a retry
  storm aimed at the operator's own ESP account.

  A throttle is now a DISTINCT outcome, `{:error, {:throttled, retry_after_seconds}}`,
  which the Oban workers translate to **`{:snooze, seconds}`**. Oban's snooze
  re-schedules the job and raises `max_attempts` to compensate, so a throttle costs **no
  attempt** — the job waits the ESP's own `Retry-After` and then tries again, with its
  full retry budget intact.

  ## Scope — the bug only

  `T170`'s full feature (a per-org token bucket in front of the send path, so the
  platform paces itself BEFORE the ESP has to) is NOT here. This module only stops the
  storm once an ESP has already pushed back.

  ## What counts as a throttle — the ADAPTER decides, this module only says how long

  Recognition is deliberately NOT here. Each ESP names throttling in its own vocabulary —
  one uses the HTTP status alone, another a typed error name that can arrive on a `400`,
  another a documented error name beside the `429` — and naming any of them in
  `samen_core` would break the vendor-freeness invariant this app is held to (ADR-038
  §8.3 / INV-4: `samen_core` never names an ESP at compile time; dispatch is host
  config). So each adapter package's own `handle_response/1` decides "this is a
  throttle", by NAME as well as by status, and documents its vendor's spelling in its own
  moduledoc. It then calls `throttled/1` here, and THIS module owns the one question that
  is not vendor-specific: how long to wait, and what the workers should do about it.

  ## How long to wait

  `retry_after_seconds/1` reads the response headers, in this order:

    1. `retry-after` — the standard header. A bare integer is seconds; an HTTP-date is
       converted to seconds-from-now.
    2. `ratelimit-reset` / `x-ratelimit-reset` — the rate-limit-window form some ESPs
       send instead of, or alongside, `Retry-After`.

  With no usable header the default is 60 seconds: long enough that a per-second rate
  limit has certainly cleared, short enough that a queue does not stall visibly. Every
  answer is clamped to `1..3600` — a hostile or broken `Retry-After` of `999999` must not
  park a job for eleven days, and a `0` must not reproduce the storm the snooze exists to
  prevent.

  Headers arrive in whichever shape the transport produced: a keyword-ish list of
  `{name, value}` tuples (charlists included, as `:httpc` yields) or `Req`'s map of
  `name => [value]`. Both are handled; anything else falls back to the default rather
  than raising inside a delivery path.
  """

  @default_seconds 60
  @min_seconds 1
  @max_seconds 3_600

  @retry_after_keys ["retry-after", "ratelimit-reset", "x-ratelimit-reset"]

  @type seconds :: pos_integer()

  @doc "The wait used when the ESP sent no usable `Retry-After` (#{@default_seconds}s)."
  @spec default_seconds() :: seconds()
  def default_seconds, do: @default_seconds

  @doc """
  The adapter-facing constructor: the distinct throttle error, carrying the wait derived
  from `headers`.

      iex> Samen.Delivery.Throttle.throttled([{"retry-after", "120"}])
      {:error, {:throttled, 120}}
  """
  @spec throttled(term()) :: {:error, {:throttled, seconds()}}
  def throttled(headers), do: {:error, {:throttled, retry_after_seconds(headers)}}

  @doc "Is `term` the throttle error this module defines?"
  @spec throttled?(term()) :: boolean()
  def throttled?({:error, {:throttled, seconds}}) when is_integer(seconds) and seconds > 0, do: true
  def throttled?(_other), do: false

  @doc """
  The worker-facing translation: an Oban `{:snooze, seconds}` for a throttle, so the
  attempt is NOT burned.

  Returns `:no_throttle` for anything else, so a worker can add exactly one clause and
  keep its existing error handling untouched.
  """
  @spec oban_result(term()) :: {:snooze, seconds()} | :no_throttle
  def oban_result({:error, {:throttled, seconds}}) when is_integer(seconds) and seconds > 0 do
    {:snooze, seconds}
  end

  def oban_result(_other), do: :no_throttle

  @doc """
  Seconds to wait, from response `headers`. Always a positive integer clamped to
  `1..3600`; falls back to `default_seconds/0` when no header is usable.
  """
  @spec retry_after_seconds(term()) :: seconds()
  def retry_after_seconds(headers) do
    @retry_after_keys
    |> Enum.find_value(fn key -> headers |> header(key) |> parse_value() end)
    |> clamp()
  end

  # ---------------------------------------------------------------------------
  # Header access — Req's `%{name => [value]}` map and a `[{name, value}]` list
  # (string or charlist values, as `:httpc` yields) are both accepted. Anything
  # else yields nil rather than raising inside a delivery path.

  defp header(headers, key) when is_map(headers) and not is_struct(headers) do
    Enum.find_value(headers, fn {k, v} ->
      if downcase(k) == key, do: first_value(v), else: nil
    end)
  end

  defp header(headers, key) when is_list(headers) do
    Enum.find_value(headers, fn
      {k, v} -> if downcase(k) == key, do: first_value(v), else: nil
      _other -> nil
    end)
  end

  defp header(_other, _key), do: nil

  defp first_value([v | _]) when is_binary(v), do: v
  defp first_value(v) when is_list(v), do: safe_to_string(v)
  defp first_value(v) when is_binary(v), do: v
  defp first_value(v) when is_integer(v), do: Integer.to_string(v)
  defp first_value(_other), do: nil

  defp downcase(k) when is_binary(k), do: String.downcase(k)
  defp downcase(k) when is_atom(k), do: k |> Atom.to_string() |> String.downcase()
  defp downcase(k) when is_list(k), do: k |> safe_to_string() |> String.downcase()
  defp downcase(_other), do: ""

  defp safe_to_string(charlist) do
    List.to_string(charlist)
  rescue
    _ -> ""
  end

  # ---------------------------------------------------------------------------
  # Value parsing — delta-seconds first, then the HTTP-date form.

  defp parse_value(nil), do: nil

  defp parse_value(value) when is_binary(value) do
    trimmed = String.trim(value)

    case Integer.parse(trimmed) do
      {seconds, ""} -> seconds
      _other -> parse_http_date(trimmed)
    end
  end

  defp parse_value(_other), do: nil

  # An absolute `Retry-After` date becomes seconds-from-now. A date already in the past
  # yields 0, which `clamp/1` lifts to the 1s floor — never a negative snooze.
  defp parse_http_date(value) do
    with {:ok, datetime} <- http_date(value) do
      DateTime.diff(datetime, DateTime.utc_now(), :second)
    else
      _other -> nil
    end
  end

  # ISO-8601 first (a few gateways emit it), then RFC 1123 / IMF-fixdate — the form
  # `Retry-After` actually uses ("Wed, 21 Oct 2015 07:28:00 GMT"), parsed through
  # `:httpd_util`, which ships with OTP's inets, so no date-library dependency enters
  # samen_core for this.
  defp http_date(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _other -> rfc1123(value)
    end
  end

  defp rfc1123(value) do
    case :httpd_util.convert_request_date(String.to_charlist(value)) do
      {{year, month, day}, {hour, minute, second}} ->
        case NaiveDateTime.new(year, month, day, hour, minute, second) do
          {:ok, naive} -> {:ok, DateTime.from_naive!(naive, "Etc/UTC")}
          _other -> :error
        end

      _other ->
        :error
    end
  rescue
    _ -> :error
  end

  # ---------------------------------------------------------------------------

  defp clamp(nil), do: @default_seconds
  defp clamp(seconds) when is_integer(seconds) and seconds < @min_seconds, do: @min_seconds
  defp clamp(seconds) when is_integer(seconds) and seconds > @max_seconds, do: @max_seconds
  defp clamp(seconds) when is_integer(seconds), do: seconds
  defp clamp(_other), do: @default_seconds
end
