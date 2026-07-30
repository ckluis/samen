defmodule Samen.Scopes.Calendar.Recurrence do
  @moduledoc """
  Pure, dependency-free recurrence-rule expansion (F2; spec §F2/§F8) — the
  substrate `Samen.Scopes.Calendar.Event.recurrence` map is expanded into a
  BOUNDED list of occurrence start instants over a caller-supplied window.

  ## Timezone / DST safety — deliberately NOT the digest fixed-offset shape

  `Samen.Notifications.Digest.to_local/2` (the C8 digest scheduler) is a
  documented, NAMED gap: it shifts a UTC instant by a FIXED per-zone offset
  that does not model daylight-saving transitions, because `samen_core`
  carries no tzdata dependency (INV-4). Recurrence expansion does NOT repeat
  that shape — it never converts to/from a "local" wall-clock zone at all.

  Every `Event.starts_at`/`ends_at` is a `utc_datetime_usec` (UTC, always).
  Expansion steps the CALENDAR DATE component forward (day/week/month/year,
  per `:freq`) while holding the UTC time-of-day fixed, then reconstructs a
  UTC `DateTime` from the stepped date + the original time-of-day. This is
  pure calendar arithmetic over a SINGLE fixed zone (UTC) — a total order of
  UTC instants, each exactly `interval` calendar units apart — so it can
  never silently drift the way a fixed-offset "local hour" reinterpretation
  would across a DST boundary (there IS no local reinterpretation step to get
  wrong). `Event.timezone` is carried on the resource purely as DISPLAY
  metadata for a future calendar VIEW (WS-G2) to render occurrences in the
  organizer's zone — expansion arithmetic never reads it, so it cannot
  reproduce the digest gap.

  A caller that genuinely wants "the 9am LOCAL wall-clock instant, DST-aware,
  in America/New_York" needs an IANA tzdata source this foundry does not
  carry (INV-4); this module is honest about not providing that and instead
  guarantees the weaker, ALWAYS-CORRECT property: occurrences are exactly
  `interval` calendar units apart on the UTC calendar, deterministically,
  every time, for every input (no seasonal branch, nothing to get wrong).

  ## Bounded expansion (done-criterion 1 — no infinite expansion)

  `expand/4,5` ALWAYS terminates: candidates stop at the first of —
  `window_to`, `rule[:until]`, `rule[:count]` occurrences, or the hard safety
  cap `:max_occurrences` (default 366 — one non-leap year of daily
  occurrences). A caller cannot construct a rule/window pair that hangs this
  function; the cap applies even to a rule with neither `:count` nor
  `:until` and an unbounded-looking window.
  """

  @default_max_occurrences 366
  @freqs [:daily, :weekly, :monthly, :yearly]

  @type freq :: :daily | :weekly | :monthly | :yearly
  @type rule :: %{
          optional(:freq) => freq(),
          optional(:interval) => pos_integer(),
          optional(:count) => pos_integer(),
          optional(:until) => DateTime.t()
        }

  @doc "The supported `:freq` atoms, in order — the closed-world set `cast_rule/1` accepts."
  def freqs, do: @freqs

  @doc """
  Validate + normalize a user-supplied rule map (string or atom keys/values,
  as arrives from a form/API) into the canonical internal shape, or
  `{:error, reason}`. `nil` is a valid "not recurring" rule.
  """
  @spec cast_rule(map() | nil) :: {:ok, rule() | nil} | {:error, term()}
  def cast_rule(nil), do: {:ok, nil}

  def cast_rule(%{} = raw) do
    with {:ok, freq} <- fetch_freq(raw),
         {:ok, interval} <- fetch_interval(raw),
         {:ok, count} <- fetch_count(raw),
         {:ok, until} <- fetch_until(raw) do
      {:ok,
       %{freq: freq, interval: interval}
       |> maybe_put(:count, count)
       |> maybe_put(:until, until)}
    end
  end

  def cast_rule(_other), do: {:error, :invalid_rule}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp fetch_freq(raw) do
    case get(raw, :freq) do
      nil -> {:error, :missing_freq}
      v when is_atom(v) -> if v in @freqs, do: {:ok, v}, else: {:error, {:invalid_freq, v}}
      v when is_binary(v) ->
        try do
          atom = String.to_existing_atom(v)
          if atom in @freqs, do: {:ok, atom}, else: {:error, {:invalid_freq, v}}
        rescue
          ArgumentError -> {:error, {:invalid_freq, v}}
        end

      other ->
        {:error, {:invalid_freq, other}}
    end
  end

  defp fetch_interval(raw) do
    case get(raw, :interval) do
      nil -> {:ok, 1}
      n when is_integer(n) and n > 0 -> {:ok, n}
      other -> {:error, {:invalid_interval, other}}
    end
  end

  defp fetch_count(raw) do
    case get(raw, :count) do
      nil -> {:ok, nil}
      n when is_integer(n) and n > 0 -> {:ok, n}
      other -> {:error, {:invalid_count, other}}
    end
  end

  defp fetch_until(raw) do
    case get(raw, :until) do
      nil -> {:ok, nil}
      %DateTime{} = dt -> {:ok, dt}
      s when is_binary(s) ->
        case DateTime.from_iso8601(s) do
          {:ok, dt, _offset} -> {:ok, dt}
          {:error, reason} -> {:error, {:invalid_until, reason}}
        end

      other ->
        {:error, {:invalid_until, other}}
    end
  end

  defp get(map, key) when is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, v} -> v
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  @doc """
  Expand `starts_at` (a UTC `DateTime`) under `rule` (see `cast_rule/1`; `nil`
  = not recurring) into a bounded, ascending, deduplicated list of UTC
  occurrence-start instants within `[window_from, window_to]` (inclusive).

  Options:

    * `:max_occurrences` — the hard safety cap (default #{@default_max_occurrences}).

  ALWAYS returns a plain list (bounded — see moduledoc). A non-recurring
  event (`rule == nil`) yields `[starts_at]` iff `starts_at` falls in the
  window, else `[]`.

  `rule` is normalized through `cast_rule/1` BEFORE expansion — a raw,
  string-keyed map (exactly the shape `Event.recurrence` round-trips as after
  a Postgres jsonb read: Postgrex always decodes jsonb object keys as
  strings, never atoms) works transparently, same as the already-cast
  canonical shape. An invalid rule raises `ArgumentError` (fail-honest — a
  malformed persisted rule is a bug to surface, not silently swallow).
  """
  @spec expand(DateTime.t(), rule() | map() | nil, DateTime.t(), DateTime.t(), keyword()) :: [
          DateTime.t()
        ]
  def expand(%DateTime{} = starts_at, rule, window_from, window_to, opts \\ []) do
    case cast_rule(rule) do
      {:ok, nil} ->
        if in_window?(starts_at, window_from, window_to), do: [starts_at], else: []

      {:ok, normalized} ->
        do_expand(starts_at, normalized, window_from, window_to, opts)

      {:error, reason} ->
        raise ArgumentError,
              "Samen.Scopes.Calendar.Recurrence.expand/5: invalid recurrence rule " <>
                "#{inspect(rule)} (#{inspect(reason)})"
    end
  end

  defp do_expand(starts_at, %{freq: freq, interval: interval} = rule, window_from, window_to, opts) do
    max = Keyword.get(opts, :max_occurrences, @default_max_occurrences)
    count_limit = Map.get(rule, :count)
    until = Map.get(rule, :until)

    step_date = date_stepper(freq, interval)
    time = DateTime.to_time(starts_at)
    date0 = DateTime.to_date(starts_at)

    0
    |> Stream.iterate(&(&1 + 1))
    |> Stream.take(max)
    |> Stream.map(fn n -> reconstruct(step_date.(date0, n), time, starts_at) end)
    |> Stream.take_while(fn dt -> not past_bound?(dt, window_to, until) end)
    |> Enum.take(count_limit || max)
    |> Enum.filter(&in_window?(&1, window_from, window_to))
  end

  defp past_bound?(dt, window_to, until) do
    DateTime.compare(dt, window_to) == :gt or
      (not is_nil(until) and DateTime.compare(dt, until) == :gt)
  end

  defp in_window?(dt, from, to) do
    DateTime.compare(dt, from) != :lt and DateTime.compare(dt, to) != :gt
  end

  # Reconstruct a UTC DateTime from a stepped Date + the ORIGINAL time-of-day
  # (hour/min/sec/microsecond) — the fixed-clock-face step this module's DST
  # safety rests on (see moduledoc). `anchor` supplies the microsecond
  # precision/calendar the new DateTime is built with.
  defp reconstruct(%Date{} = date, %Time{} = time, %DateTime{microsecond: {_, precision}}) do
    {:ok, dt} = DateTime.new(date, time, "Etc/UTC")
    %{dt | microsecond: {elem(dt.microsecond, 0), precision}}
  end

  defp date_stepper(:daily, interval), do: fn date, n -> Date.add(date, n * interval) end
  defp date_stepper(:weekly, interval), do: fn date, n -> Date.add(date, n * interval * 7) end
  defp date_stepper(:monthly, interval), do: fn date, n -> add_months(date, n * interval) end
  defp date_stepper(:yearly, interval), do: fn date, n -> add_months(date, n * interval * 12) end

  # Calendar-correct month stepping (no dependency): total-month arithmetic,
  # day-of-month CLAMPED to the target month's actual length (Jan 31 + 1
  # month -> Feb 28/29, never an invalid date / never rolls into March).
  defp add_months(%Date{year: year, month: month, day: day}, delta_months) do
    total = year * 12 + (month - 1) + delta_months
    new_year = div(total, 12)
    new_month = rem(total, 12) + 1
    last_day = :calendar.last_day_of_the_month(new_year, new_month)
    Date.new!(new_year, new_month, min(day, last_day))
  end
end
