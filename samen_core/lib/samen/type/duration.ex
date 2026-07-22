defmodule Samen.Type.Duration do
  @moduledoc """
  `Samen.Type.Duration` — H2's duration scalar (ADR-036 D2; WS-H spec §H2), a
  non-negative-seconds `Ash.Type` (an SLA window, a call length, a task
  estimate).

  ## Storage shape

  `storage_type/1` is `:integer`. The canonical value is a **non-negative
  integer count of seconds** — the ADR's stated logical/storage shape (unlike
  `Priority`, this type's storage IS its logical shape).

  ## Cast — accepts three input shapes (ADR-036 §3 H2 table)

    * a bare integer/numeric-string — seconds directly;
    * an ISO-8601 duration string (`"PT1H30M"`) — parsed via the Elixir
      stdlib `Duration.from_iso8601/1` and reduced to seconds (`week/day/hour/
      minute/second` components; a `year`/`month` component is rejected —
      those units are calendar-relative and cannot be reduced to a fixed
      second count without a reference date, so a duration expressing one is
      `:error`, not a silently-wrong approximation);
    * a `%Duration{}` struct (Elixir 1.17+ stdlib) directly.

  ## Constraints (ADR-036 §3 H2 table)

    * `:min` — optional lower bound (seconds)
    * `:max` — optional upper bound (seconds)

  No default bounds beyond non-negativity — `cast_input/2` always rejects a
  negative second count regardless of `:min`/`:max`.

  ## PII posture — non-PII, cleared (ADR-036 D2; ADR-034 gate)

  A duration is categorically **not** PII. This module self-classifies
  `:non_pii` (`samen_pii_class/0`), and `samen_core` SHIPS the two-distinct-
  party `Samen.NonPii.TypeClearance` entry that governs it.
  """
  use Ash.Type

  @doc "Self-classification for `Samen.Pii.Classification`: a duration is non-PII (ADR-036 D2)."
  def samen_pii_class, do: :non_pii

  @impl true
  def storage_type(_constraints), do: :integer

  @impl true
  def constraints do
    [
      min: [type: :non_neg_integer, doc: "Minimum seconds (inclusive)."],
      max: [type: :non_neg_integer, doc: "Maximum seconds (inclusive)."]
    ]
  end

  @impl true
  def cast_input(nil, _constraints), do: {:ok, nil}

  def cast_input(seconds, constraints) when is_integer(seconds) do
    validate_range(seconds, constraints)
  end

  def cast_input(%Duration{} = duration, constraints) do
    case to_seconds(duration) do
      {:ok, seconds} -> validate_range(seconds, constraints)
      :error -> :error
    end
  end

  def cast_input(value, constraints) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        :error

      match?({:ok, _}, Duration.from_iso8601(trimmed)) ->
        {:ok, duration} = Duration.from_iso8601(trimmed)
        cast_input(duration, constraints)

      true ->
        case Integer.parse(trimmed) do
          {seconds, ""} -> cast_input(seconds, constraints)
          _ -> :error
        end
    end
  end

  def cast_input(_other, _constraints), do: :error

  @impl true
  def cast_stored(nil, _constraints), do: {:ok, nil}
  def cast_stored(seconds, _constraints) when is_integer(seconds) and seconds >= 0, do: {:ok, seconds}
  def cast_stored(_other, _constraints), do: :error

  @impl true
  def dump_to_native(nil, _constraints), do: {:ok, nil}
  def dump_to_native(seconds, _constraints) when is_integer(seconds) and seconds >= 0, do: {:ok, seconds}
  def dump_to_native(_other, _constraints), do: :error

  # A `%Duration{}` with a nonzero `:year`/`:month` component cannot be reduced to
  # a fixed second count without a reference date — reject rather than guess.
  # `week/day/hour/minute/second` are all fixed-length and safely summed. Any
  # sub-second `:microsecond` remainder is truncated (documented, not silently
  # inflated by rounding up).
  defp to_seconds(%Duration{year: 0, month: 0} = d) do
    total =
      d.week * 604_800 +
        d.day * 86_400 +
        d.hour * 3_600 +
        d.minute * 60 +
        d.second

    {:ok, total}
  end

  defp to_seconds(%Duration{}), do: :error

  defp validate_range(seconds, _constraints) when seconds < 0, do: :error

  defp validate_range(seconds, constraints) do
    min = Keyword.get(constraints, :min)
    max = Keyword.get(constraints, :max)

    cond do
      is_integer(min) and seconds < min -> :error
      is_integer(max) and seconds > max -> :error
      true -> {:ok, seconds}
    end
  end
end
