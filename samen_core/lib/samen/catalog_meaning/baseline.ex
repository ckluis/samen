defmodule Samen.CatalogMeaning.Baseline do
  @moduledoc """
  The `<app>/catalog_meaning.baseline` file of `mix samen.verify.catalog_meaning`: the honest ratchet for the
  catalogue meaning that is still missing. A plain, sorted list of the undescribed `table_name` and
  `table_name.logical_name` entries, under a `# ceiling: N` header that must equal the entry count:

      # samen.verify.catalog_meaning baseline: undescribed at adoption. Shrink-only; never add a line.
      # ceiling: 497
      cnt_contact
      cnt_contact.active

  The list can only shrink. `shrink/2` keeps the intersection of the file and what is still undescribed;
  `growth/2` compares a baseline with the one on the merge base (the ratchet test calls it) and names every entry
  the current file gained and a ceiling that rose. A plain list, not hashes: every grandfathered field shows up in
  review. Pure: strings in, strings and lists out.
  """

  @header "# samen.verify.catalog_meaning baseline: undescribed at adoption. Shrink-only; never add a line."

  @type parsed :: %{ceiling: non_neg_integer() | nil, entries: [String.t()], problems: [String.t()]}

  @doc "The file name, relative to the host app's root."
  @spec file_name() :: String.t()
  def file_name, do: "catalog_meaning.baseline"

  @doc "Render `entries` (any order, duplicates folded) as a baseline file: header, ceiling = count, sorted entries."
  @spec render([String.t()]) :: String.t()
  def render(entries) do
    sorted = entries |> Enum.uniq() |> Enum.sort()
    Enum.join([@header, "# ceiling: #{length(sorted)}" | sorted], "\n") <> "\n"
  end

  @doc """
  Parse a baseline file. Never raises: a malformed file yields `problems` (a missing ceiling header, a malformed or
  duplicate entry, entries out of order) beside whatever it could read, so a caller fails closed on it.
  """
  @spec parse(String.t()) :: parsed()
  def parse(src) when is_binary(src) do
    lines = src |> String.split("\n") |> Enum.map(&String.trim_trailing/1)

    ceilings = for "# ceiling: " <> n <- lines, do: n
    entries = for line <- lines, line != "", not String.starts_with?(line, "#"), do: line

    {ceiling, ceiling_problems} =
      case ceilings do
        [n] ->
          case Integer.parse(n) do
            {int, ""} when int >= 0 -> {int, []}
            _ -> {nil, ["the `# ceiling:` header is not a non-negative integer"]}
          end

        [] ->
          {nil, ["the `# ceiling: N` header is missing"]}

        _ ->
          {nil, ["the `# ceiling:` header appears more than once"]}
      end

    malformed = for e <- entries, not Regex.match?(~r/\A[a-z0-9_]+(\.[a-z0-9_]+)?\z/, e), do: "malformed entry #{inspect(e)}"

    ordering =
      cond do
        entries != Enum.uniq(entries) -> ["duplicate entries"]
        entries != Enum.sort(entries) -> ["entries are not sorted (run --shrink)"]
        true -> []
      end

    %{ceiling: ceiling, entries: entries, problems: ceiling_problems ++ malformed ++ ordering}
  end

  @doc """
  The shrunk file: the INTERSECTION of the file's entries and `undescribed` (what is still undescribed now), with the
  ceiling lowered to match. It never adds an entry: an undescribed field that was not listed stays a violation.
  """
  @spec shrink(String.t(), [String.t()]) :: String.t()
  def shrink(src, undescribed) do
    still = MapSet.new(undescribed)
    src |> parse() |> Map.fetch!(:entries) |> Enum.filter(&MapSet.member?(still, &1)) |> render()
  end

  @doc """
  What the current baseline gained against the merge base's: every entry not in the base, and a ceiling above the
  base's. `[]` when it only shrank. An unreadable ceiling on either side is a problem (never a silent pass).
  """
  @spec growth(String.t(), String.t()) :: [String.t()]
  def growth(current_src, base_src) do
    current = parse(current_src)
    base = parse(base_src)

    added = MapSet.difference(MapSet.new(current.entries), MapSet.new(base.entries))

    entries =
      for e <- Enum.sort(added),
          do: "#{e}: not in the merge base's baseline — the baseline never grows; describe the table or field instead"

    ceiling =
      cond do
        is_nil(current.ceiling) or is_nil(base.ceiling) ->
          ["the ceiling could not be read (current #{inspect(current.ceiling)}, merge base #{inspect(base.ceiling)})"]

        current.ceiling > base.ceiling ->
          ["the ceiling rose: #{base.ceiling} -> #{current.ceiling}"]

        true ->
          []
      end

    entries ++ ceiling
  end
end
