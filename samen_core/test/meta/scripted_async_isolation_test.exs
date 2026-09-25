defmodule Samen.Meta.ScriptedAsyncIsolationTest do
  @moduledoc """
  Issue #13 — the CLASS guard for `Samen.AI.Provider.Scripted`'s global state.

  `Scripted` keeps its script AND its recording in `:persistent_term`, deliberately:
  `scripted.ex` documents it as *"cross-process, the A2 worker seam"* — A2's
  `Samen.AI.Agent.TurnWorker` executes turns in whatever process runs the job (an Oban
  drain, a watchdog replay, a spawned crash-simulation Task), so a process-local script
  would make the worker path answer `{:error, :not_configured}` for work that WAS scripted.
  That seam is load-bearing for the 18 sync test files that drive the agent loop, so
  `Scripted` must NOT be made process-scoped (issue #13's option 3 — it would break them).

  The price of global state is stated in that same moduledoc: `Scripted` is a
  **ONE-RUNNER-AT-A-TIME** seam — "agent suites run `async: false` and `reset/0` in setup".
  Nothing enforced it. `ai_prompt_masking_test.exs` was `async: true` and (since PR #10)
  scripted `Scripted` from its two P10 provenance arms; it happened to be the ONLY
  `async: true` module of the 19 that touch `Scripted`, so nothing raced — the trap was
  armed for the next author, not yet sprung. Two `async: true` modules that both
  `Scripted.reset/0` + `Scripted.script/1` would interleave through one `:persistent_term`
  key and produce exactly the seed-dependent red this project treats as a "known flake".

  This test makes that unrepresentable: **no `async: true` test module may reference
  `Samen.AI.Provider.Scripted`.** It runs in every `mix test`, names the offending file and
  the lines, and states the fix (move those arms into an `async: false` module — never flip
  `Scripted` to process-scoped).

  ## AST, not a text scan (and why that matters here)

  The scan parses each test file (`Code.string_to_quoted/2` + `Macro.prewalk/3`) and looks at
  **alias nodes** and the **`use ... async: true` option**, exactly as
  `Samen.AI.ChokepointAntiBypassProbeTest` parses rather than greps. A text scan cannot do
  this job at all: THIS file names `Samen.AI.Provider.Scripted` a dozen times in prose and
  quotes `async: true` in its own failure message, and so does the moduledoc of every file
  that documents the constraint — a substring scan flags all of them. To the AST those are
  strings and comments, invisible. The guard therefore needs no self-exemption.

  ## Scope and the honest residual

  Detection is **file-scoped and deliberately fail-closed**: ExUnit's `async` is per
  *module*, but a `Scripted` alias ANYWHERE in a file that declares `async: true` is
  refused — a same-file helper module that drives `Scripted` is reachable from the async test
  module beside it, and separating "reachable" from "merely co-located" statically is not
  worth the precision. The guard over-reports before it under-reports, and the fix for a
  legitimate co-location (split the file) is the fix for the real case anyway.

  The residual, the same one the anti-bypass probe documents: a reference laundered through
  runtime data (`Module.concat/1`, `apply/3` on a computed module name) is beyond a static
  scan. Accidental and refactor-introduced re-arming — the way this trap was actually armed —
  IS caught.
  """
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../..", __DIR__)

  # Every test file in the tree. Two globs, not a hand-listed app set: `<app>/test/**` covers
  # every mix project at the root (samen_core, samen_web, driftwood, pawchart, demo, the
  # adapters) and `<dir>/<app>/test/**` covers the nested ones (spikes/*). A newly added app
  # is scanned BY DEFAULT — the fail-closed direction, and the same reason ci-fast.sh derives
  # its covered set from its own source instead of listing it.
  @test_globs ~w(*/test/**/*_test.exs */*/test/**/*_test.exs)

  # Build dirs, vendored deps, and the orchestration scratch trees (`_orch/`, `_orch-runs/`,
  # which hold COPIES of real test files) are not the test tree.
  @excluded_fragments ~w(/_build/ /deps/ /_orch/ /_orch-runs/ /spec/)

  describe "Scripted's :persistent_term seam is never driven from an async: true module" do
    test "no async: true test module references Samen.AI.Provider.Scripted (issue #13)" do
      offenders =
        scan()
        |> Enum.filter(fn info -> info.async? and info.scripted_lines != [] end)
        |> Enum.map(fn info -> {info.path, info.scripted_lines} end)

      assert offenders == [], """
      #{length(offenders)} test file(s) declare `async: true` AND reference the global
      `Scripted` provider double:

      #{Enum.map_join(offenders, "\n", fn {path, lines} -> "  * #{path} — referenced on line(s) #{Enum.join(lines, ", ")}" end)}

      That double keeps its script and its recording in `:persistent_term` (a deliberate
      cross-process seam — `scripted.ex`: "cross-process, the A2 worker seam"), so it is a
      ONE-RUNNER-AT-A-TIME double. Two parallel modules scripting it interleave through one
      global key and go red by seed.

      FIX: move the arms that touch it into their own `async: false` module (see
      `samen_core/test/ai/ai_prompt_masking_provenance_test.exs`, split out of
      `ai_prompt_masking_test.exs` for exactly this reason).

      DO NOT make the double process-scoped to satisfy this guard: the 18 `async: false`
      agent suites need the cross-process seam, and confining writes to the writing
      process's dictionary would make the A2 worker path answer `{:error, :not_configured}`
      for work that was scripted.
      """
    end

    test "the scan is not vacuous: it sees the tree, the async modules, and the consumers" do
      infos = scan()

      assert length(infos) > 200,
             "the test-file scan found only #{length(infos)} files — the globs are not " <>
               "reaching the test tree, so the guard above would pass vacuously"

      consumers = Enum.count(infos, fn info -> info.scripted_lines != [] end)

      assert consumers >= 15,
             "the scan found only #{consumers} file(s) referencing the Scripted double — the " <>
               "alias detector no longer matches the way tests reach it, so the guard above " <>
               "would pass vacuously (expected ~19)"

      async_modules = Enum.count(infos, & &1.async?)

      assert async_modules >= 100,
             "the scan found only #{async_modules} `async: true` file(s) — the async detector " <>
               "no longer matches, so the guard above would pass vacuously"
    end

    test "the detectors are refutable on synthetic sources (positive + negative control)" do
      # The exact shape this guard exists to catch — async: true + the aliased double.
      offender = """
      defmodule OffenderTest do
        use ExUnit.Case, async: true
        alias Samen.AI.Provider
        test "x", do: Provider.Scripted.reset()
      end
      """

      assert analyze_source("offender_test.exs", offender).async?
      assert analyze_source("offender_test.exs", offender).scripted_lines == [4]

      # The sanctioned shape: same reference, async: false.
      sanctioned = String.replace(offender, "async: true", "async: false")
      refute analyze_source("ok_test.exs", sanctioned).async?
      assert analyze_source("ok_test.exs", sanctioned).scripted_lines == [4]

      # Prose and strings are NOT references — the property a text scan cannot have, and the
      # reason this file (which names the double throughout its own docs) is not an offender.
      prose = """
      defmodule ProseTest do
        @moduledoc "mentions Samen.AI.Provider.Scripted and async: true in prose only"
        use ExUnit.Case, async: true
        # Samen.AI.Provider.Scripted in a comment
        test "x", do: assert("Provider.Scripted" == "Provider.Scripted")
      end
      """

      assert analyze_source("prose_test.exs", prose).async?
      assert analyze_source("prose_test.exs", prose).scripted_lines == []
    end
  end

  # --- the scan --------------------------------------------------------------------------

  defp scan do
    @test_globs
    |> Enum.flat_map(fn glob -> Path.wildcard(Path.join(@repo_root, glob)) end)
    |> Enum.reject(fn path -> Enum.any?(@excluded_fragments, &String.contains?(path, &1)) end)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn path ->
      analyze_source(Path.relative_to(path, @repo_root), File.read!(path))
    end)
  end

  # `%{path:, async?:, scripted_lines:}` for one test source. An unparseable test file is a
  # LOUD failure, never a silent skip: a file this guard cannot read is a file in which the
  # trap could be re-armed unseen.
  defp analyze_source(path, source) do
    ast =
      case Code.string_to_quoted(source, file: path) do
        {:ok, ast} ->
          ast

        {:error, reason} ->
          flunk("could not parse #{path} — this guard cannot vouch for it: #{inspect(reason)}")
      end

    {_ast, acc} =
      Macro.prewalk(ast, %{async?: false, scripted_lines: []}, fn node, acc ->
        {node, collect(node, acc)}
      end)

    %{path: path, async?: acc.async?, scripted_lines: acc.scripted_lines |> Enum.uniq() |> Enum.sort()}
  end

  # `use <Case>, async: true` — the only way an ExUnit module opts into parallelism.
  defp collect({:use, _meta, [_module, opts]}, acc) when is_list(opts) do
    if Keyword.get(opts, :async) == true, do: %{acc | async?: true}, else: acc
  end

  # Any alias whose LAST segment is `Scripted`: `Samen.AI.Provider.Scripted`,
  # `Provider.Scripted` (the `alias Samen.AI.Provider` form), and the bare `Scripted` of an
  # `alias Samen.AI.Provider.Scripted`. Nothing else in this tree is named `Scripted`, and an
  # over-match is the fail-closed direction.
  defp collect({:__aliases__, meta, segments}, acc) when is_list(segments) do
    if List.last(segments) == :Scripted do
      %{acc | scripted_lines: [Keyword.get(meta, :line, 0) | acc.scripted_lines]}
    else
      acc
    end
  end

  defp collect(_node, acc), do: acc
end
