defmodule Samen.Sequences.ValidateSteps do
  @moduledoc """
  Write-time validation + normalization for `Outreach.Sequence.steps` (spec §I2).

  Each step must be a map carrying a non-negative integer `delay_hours` (hours
  after the PREVIOUS step, or after enrollment for step 0) plus `subject`/`body`
  strings (tenant-authored template copy — defaults to `""` when absent, never
  `nil`, so `Samen.Sequences.SendWorker`'s render step never crashes on a missing
  key). Normalizes to string keys (`"delay_hours"`/`"subject"`/`"body"`) so a
  step map written via either atom or string keys reads back identically. Bounded
  to `@max_steps` entries — an unbounded step list is a resource-exhaustion vector
  no test author needs.

  A malformed step list (wrong shape, negative delay, oversized) is REFUSED at
  write time with `Ash.Changeset.add_error/2` — never silently dropped or
  truncated (the same "refuse the write, don't guess" posture
  `Samen.Automation.NonPiiPredicates` uses for condition/action configs).
  """
  use Ash.Resource.Change

  @max_steps 50

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :steps) do
      steps when is_list(steps) ->
        apply_normalized(changeset, steps)

      _ ->
        changeset
    end
  end

  defp apply_normalized(changeset, steps) do
    case normalize(steps) do
      {:ok, normalized} ->
        Ash.Changeset.force_change_attribute(changeset, :steps, normalized)

      {:error, message} ->
        Ash.Changeset.add_error(changeset, field: :steps, message: message)
    end
  end

  defp normalize(steps) when length(steps) > @max_steps do
    {:error, "a sequence may not exceed #{@max_steps} steps"}
  end

  defp normalize(steps) do
    steps
    |> Enum.reduce_while({:ok, []}, fn step, {:ok, acc} ->
      case normalize_step(step) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        :error -> {:halt, {:error, "each step must be a map with a non-negative integer delay_hours"}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _} = err -> err
    end
  end

  defp normalize_step(step) when is_map(step) do
    with delay when is_integer(delay) and delay >= 0 <- get(step, "delay_hours", "delay_hours", 0) do
      {:ok,
       %{
         "delay_hours" => delay,
         "subject" => to_str(get(step, "subject", "subject", "")),
         "body" => to_str(get(step, "body", "body", ""))
       }}
    else
      _ -> :error
    end
  end

  defp normalize_step(_), do: :error

  defp get(map, str_key, atom_key, default) do
    cond do
      Map.has_key?(map, str_key) -> Map.get(map, str_key)
      Map.has_key?(map, String.to_atom(atom_key)) -> Map.get(map, String.to_atom(atom_key))
      true -> default
    end
  end

  defp to_str(v) when is_binary(v), do: v
  defp to_str(v), do: to_string(v)
end
