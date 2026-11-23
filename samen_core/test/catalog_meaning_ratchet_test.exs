defmodule SamenCore.CatalogMeaningRatchetTest do
  @moduledoc """
  The growth guard of `mix samen.verify.catalog_meaning` (ADR-043 §8a, A2): a host's `catalog_meaning.baseline` can
  only shrink. Against the merge base with `origin/main`, no host baseline may hold an entry the base's did not, nor a
  higher ceiling. Modelled on `SwallowLintTest` ("a ceiling can only go down"): the same merge-base discovery, the
  same behaviour without one (skipped locally, a FAILURE under `CI`: a shallow checkout must not switch the guard
  off). A baseline that does not exist at the merge base is the adoption commit and is skipped.
  """
  use ExUnit.Case, async: false

  alias Samen.CatalogMeaning.Baseline
  alias Samen.Lint.KernelSwallow

  @hosts ~w(demo driftwood pawchart)

  defp root, do: KernelSwallow.repo_root()
  defp rel(host), do: "#{host}/#{Baseline.file_name()}"

  defp merge_base_source(rel) do
    case System.cmd("git", ["merge-base", "HEAD", "origin/main"], cd: root(), stderr_to_stdout: true) do
      {base, 0} ->
        case System.cmd("git", ["show", "#{String.trim(base)}:#{rel}"], cd: root(), stderr_to_stdout: true) do
          {src, 0} -> {:ok, src}
          _ -> :new_file
        end

      _ ->
        :no_merge_base
    end
  end

  test "every host's committed baseline is well-formed and its ceiling is its entry count" do
    for host <- @hosts do
      path = Path.join(root(), rel(host))
      assert File.exists?(path), "#{rel(host)} is missing: run `mix samen.verify.catalog_meaning --init` in #{host}"

      parsed = path |> File.read!() |> Baseline.parse()
      assert parsed.problems == [], "#{rel(host)}: #{inspect(parsed.problems)}"
      assert parsed.ceiling == length(parsed.entries), "#{rel(host)}: ceiling #{parsed.ceiling} != #{length(parsed.entries)} entries"
    end
  end

  test "a host baseline can only shrink against the merge base" do
    for host <- @hosts do
      current = File.read!(Path.join(root(), rel(host)))

      case merge_base_source(rel(host)) do
        {:ok, base_src} ->
          assert Baseline.growth(current, base_src) == [],
                 "#{rel(host)} grew against the merge base:\n  " <> Enum.join(Baseline.growth(current, base_src), "\n  ")

        :new_file ->
          # the adoption commit: nothing to compare with
          :ok

        :no_merge_base ->
          # Skipping would turn the guard off exactly where it matters (a shallow CI checkout): fail there.
          if System.get_env("CI") in [nil, ""] do
            :skip
          else
            flunk("no merge base with origin/main in CI: the catalog-meaning baselines can-only-shrink check cannot run (fetch-depth: 0)")
          end
      end
    end
  end

  test "growth/2 is not vacuous: a grown copy of a real baseline is refused, an equal or shrunk one is not" do
    for host <- @hosts do
      src = File.read!(Path.join(root(), rel(host)))
      %{entries: [first | _] = entries} = Baseline.parse(src)

      assert Baseline.growth(src, src) == []
      assert Baseline.growth(Baseline.render(tl(entries)), src) == []
      assert [_ | _] = Baseline.growth(src, Baseline.render(tl(entries)))
      assert [_ | _] = Baseline.growth(Baseline.render(["zz_new_table.field" | entries]), src)
      assert first in entries
    end
  end
end
