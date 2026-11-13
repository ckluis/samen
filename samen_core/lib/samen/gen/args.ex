defmodule Samen.Gen.Args do
  @moduledoc """
  Strict argv parsing shared by the generator / allocator mix tasks (`samen.gen.app|resource|scope|agent`,
  `samen.abbrev.reserve`).

  Every one of those tasks has a permanent side effect (files written, abbrevs reserved in an append-only,
  never-recycled registry), so a typo or a guessed flag (`--modlues`, `--dry-run`) must NOT quietly turn into a
  different real run. `parse!/3` raises `Mix.Error` — naming the offending argument and listing the valid
  switches — and it runs before the task does anything else, so a refused run has no side effect.
  """

  @doc """
  Parses `argv` against `switches` (an `OptionParser` `strict:` list). Returns the options keyword list, or raises
  `Mix.Error` when any switch is unknown or malformed (e.g. a missing value, a non-integer for an integer
  switch) or any positional argument is present.
  """
  @spec parse!(String.t(), [String.t()], keyword()) :: keyword()
  def parse!(task, argv, switches) when is_binary(task) and is_list(argv) and is_list(switches) do
    {opts, rest, invalid} = OptionParser.parse(argv, strict: switches)

    problems =
      Enum.map(invalid, &describe_invalid(&1, switches)) ++
        Enum.map(rest, &"unexpected positional argument #{inspect(&1)}")

    case problems do
      [] ->
        opts

      _ ->
        Mix.raise(
          "mix #{task}: " <>
            Enum.join(problems, "; ") <>
            ". Nothing was written or reserved. Valid switches: #{valid_list(switches)}."
        )
    end
  end

  defp describe_invalid({name, value}, switches) do
    key = name |> String.trim_leading("-") |> String.replace("-", "_")

    known? =
      Enum.any?(switches, fn {k, _} ->
        Atom.to_string(k) == key or "no_" <> Atom.to_string(k) == key
      end)

    cond do
      not known? -> "unknown flag #{name}"
      is_nil(value) -> "flag #{name} needs a value"
      true -> "flag #{name} has an invalid value #{inspect(value)}"
    end
  end

  defp valid_list(switches) do
    switches
    |> Enum.map(fn
      {k, :boolean} -> "--#{dash(k)}/--no-#{dash(k)}"
      {k, _} -> "--#{dash(k)}"
    end)
    |> Enum.join(", ")
  end

  defp dash(k), do: k |> Atom.to_string() |> String.replace("_", "-")
end
