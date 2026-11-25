defmodule SamenCore.CatalogMeaningRatchetTest do
  @moduledoc """
  The growth guard of `mix samen.verify.catalog_meaning` (ADR-043 §8a, A2): a host's `catalog_meaning.baseline` can
  only shrink. Against the merge base with `origin/main`, no host baseline may hold an entry the base's did not, nor a
  higher ceiling. Modelled on `SwallowLintTest` ("a ceiling can only go down"): the same merge-base discovery, the
  same behaviour without one (skipped locally, a FAILURE under `CI`: a shallow checkout must not switch the guard
  off). A baseline absent at the merge base is the adoption commit and is tolerated only while the merge base predates
  the verifier itself (`Baseline.ratchet/3`); afterwards it is a failure. The end state keeps the file at ceiling 0.
  """
  use ExUnit.Case, async: false

  alias Samen.CatalogMeaning.Baseline
  alias Samen.Lint.KernelSwallow

  @hosts ~w(demo driftwood pawchart)
  @feature_file "samen_core/lib/samen/catalog_meaning/baseline.ex"

  defp root, do: KernelSwallow.repo_root()
  defp rel(host), do: "#{host}/#{Baseline.file_name()}"

  # What the merge base with origin/main has: `{:ok, base_baseline | :missing, feature_at_base?}`. `feature_at_base?` is
  # whether `Baseline` itself (the verifier's code) exists there: the fact that makes the adoption allowance expire.
  defp merge_base_facts(rel) do
    case System.cmd("git", ["merge-base", "HEAD", "origin/main"], cd: root(), stderr_to_stdout: true) do
      {base, 0} ->
        base = String.trim(base)

        baseline =
          case System.cmd("git", ["show", "#{base}:#{rel}"], cd: root(), stderr_to_stdout: true) do
            {src, 0} -> {:ok, src}
            _ -> :missing
          end

        feature? = match?({_, 0}, System.cmd("git", ["cat-file", "-e", "#{base}:#{@feature_file}"], cd: root(), stderr_to_stdout: true))
        {:ok, baseline, feature?}

      _ ->
        :no_merge_base
    end
  end

  # The live path: the host's real baseline file judged by `Baseline.ratchet/3` against `base`.
  defp host_violations(host, base, feature_at_base?, current_src \\ nil) do
    current = current_src || File.read!(Path.join(root(), rel(host)))
    Baseline.ratchet(current, base, feature_at_base?)
  end

  test "every host's committed baseline is well-formed and its ceiling is its entry count" do
    for host <- @hosts do
      path = Path.join(root(), rel(host))
      assert File.exists?(path), "#{rel(host)} is missing: a host keeps its baseline (at `# ceiling: 0` when it has no debt)"

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

  # The rule, in one place. A baseline file absent at the merge base is tolerated ONLY while the merge base predates
  # the verifier (`Baseline.ratchet/3`, `feature_at_base?` false): that is the adoption commit, and it ends when this
  # branch merges. Once `samen_core/lib/samen/catalog_meaning/baseline.ex` exists at the merge base, a missing host
  # baseline there is a FAILURE: the file was deleted and re-initialised. A host with no debt keeps its file at
  # `# ceiling: 0`.
  test "a host baseline can only shrink against the merge base" do
    for host <- @hosts do
      case merge_base_facts(rel(host)) do
        {:ok, base, feature?} ->
          assert host_violations(host, base, feature?) == [],
                 "#{rel(host)} is refused against the merge base:\n  " <> Enum.join(host_violations(host, base, feature?), "\n  ")

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

  describe "Baseline.ratchet/3 (no merge base needed)" do
    test "the live host path refuses a grown baseline and a raised ceiling, and accepts an equal or shrunk one" do
      for host <- @hosts do
        src = File.read!(Path.join(root(), rel(host)))
        %{entries: entries} = Baseline.parse(src)
        assert entries != [], "#{host}: this test needs a non-empty baseline to shrink (the empty end state is tested below)"

        # green controls: the baseline against itself, and against a base that still had one more entry
        assert host_violations(host, {:ok, src}, true) == []
        assert host_violations(host, {:ok, Baseline.render(["zz_old_table.field" | entries])}, true) == []

        # RED: the base had one fewer entry, so the host's file "grew"
        assert [_ | _] = host_violations(host, {:ok, Baseline.render(tl(entries))}, true)
        # RED: the same host file with one extra entry against its own base
        assert [_ | _] = host_violations(host, {:ok, src}, true, Baseline.render(["zz_new_table.field" | entries]))
      end
    end

    test "RED: a baseline missing at a merge base that already has the feature is refused (deleted and re-initialised)" do
      src = Baseline.render(["zz_new_table.field"])

      assert [message] = Baseline.ratchet(src, :missing, true)
      assert message =~ "deleted and re-initialised"
      # also when the fresh file is empty: the file must exist at the base
      assert [_] = Baseline.ratchet(Baseline.render([]), :missing, true)

      # green control: the same file is the adoption commit while the merge base predates the verifier
      assert Baseline.ratchet(src, :missing, false) == []
      assert Baseline.ratchet(Baseline.render([]), :missing, false) == []
    end

    test "the end state: an empty baseline (`# ceiling: 0`) is well-formed, and can never regain an entry" do
      empty = Baseline.render([])
      assert %{ceiling: 0, entries: [], problems: []} = Baseline.parse(empty)

      assert Baseline.ratchet(empty, {:ok, empty}, true) == []
      assert Baseline.ratchet(empty, {:ok, Baseline.render(["a_table"])}, true) == []

      # RED: an entry or a raised ceiling against an empty base
      assert [_ | _] = Baseline.ratchet(Baseline.render(["a_table"]), {:ok, empty}, true)
      assert [_ | _] = Baseline.ratchet("# ceiling: 3\n", {:ok, empty}, true)
    end
  end

  test "RED: a catalog_meaning.baseline under an app that is not in the host list is refused" do
    assert Baseline.unguarded(["demo/catalog_meaning.baseline", "pawchart/catalog_meaning.baseline"], @hosts) == []
    assert Baseline.unguarded(["pawchart/catalog_meaning.baseline", "newhost/catalog_meaning.baseline"], @hosts) == ["newhost/catalog_meaning.baseline"]
    # a nested copy or a renamed host directory is not a guarded path either
    assert Baseline.unguarded(["demo/sub/catalog_meaning.baseline"], @hosts) == ["demo/sub/catalog_meaning.baseline"]
  end

  test "every catalog_meaning.baseline in the repo belongs to a host this ratchet guards" do
    {out, 0} = System.cmd("git", ["ls-files", "-co", "--exclude-standard", "--", "*#{Baseline.file_name()}"], cd: root())
    paths = String.split(out, "\n", trim: true)

    # positive control: the guarded ones are really found, so an empty listing cannot pass vacuously
    for host <- @hosts, do: assert(rel(host) in paths)

    assert Baseline.unguarded(paths, @hosts) == [],
           "a catalog_meaning.baseline exists for an app the ratchet does not guard: add it to @hosts in catalog_meaning_ratchet_test.exs"
  end

  test "growth/2 is not vacuous: a grown copy of a real baseline is refused, an equal or shrunk one is not" do
    for host <- @hosts do
      src = File.read!(Path.join(root(), rel(host)))
      %{entries: entries} = Baseline.parse(src)
      # an empty (end-state) baseline has no entry to drop: a synthetic one stands in, never a crash
      entries = if entries == [], do: ["zz_synthetic_table.field"], else: entries
      src = if Baseline.parse(src).entries == [], do: Baseline.render(entries), else: src

      assert Baseline.growth(src, src) == []
      assert Baseline.growth(Baseline.render(tl(entries)), src) == []
      assert [_ | _] = Baseline.growth(src, Baseline.render(tl(entries)))
      assert [_ | _] = Baseline.growth(Baseline.render(["zz_new_table.field" | entries]), src)
    end
  end
end
