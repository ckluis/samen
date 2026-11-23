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

  # The ONE line that turns the verifier on in a host's ci.sh (step 1c): a WHOLE, unindented, uncommented command with
  # no `|| true` and no `--baseline` override. Precedent: `read_scope_verify_test.exs`.
  @ci_line "mix samen.verify.catalog_meaning"
  @ci_line_regex ~r/^mix samen\.verify\.catalog_meaning$/m
  @drift_passed "PASSED (schema.dict.json matches regenerated output)"

  test "every host's ci.sh runs the verifier: the exact whole line `#{@ci_line}`, once, after the dict drift step" do
    for host <- @hosts do
      ci = File.read!(Path.join([root(), host, "ci.sh"]))

      assert [[_]] = Regex.scan(@ci_line_regex, ci),
             "#{host}/ci.sh must run `#{@ci_line}` as ONE whole, uncommented line with no `|| true` and no `--baseline` override"

      [{line_at, _}] = Regex.run(@ci_line_regex, ci, return: :index)
      assert {drift_at, _} = :binary.match(ci, @drift_passed), "#{host}/ci.sh lost its dict drift step"
      assert line_at > drift_at, "#{host}/ci.sh: step 1c must sit after the schema.dict.json drift step"
    end
  end

  test "the ci.sh pin is refutable: a commented, indented, `|| true`-ed, overridden or absent line does not satisfy it" do
    assert "echo a\n#{@ci_line}\necho b\n" =~ @ci_line_regex

    for bad <- [
          "# #{@ci_line}",
          "  #{@ci_line}",
          "#{@ci_line} || true",
          "#{@ci_line} --baseline /tmp/other.baseline",
          "if false; then #{@ci_line}; fi",
          "true"
        ] do
      refute "echo a\n#{bad}\necho b\n" =~ @ci_line_regex, "#{inspect(bad)} must not satisfy the pin"
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
