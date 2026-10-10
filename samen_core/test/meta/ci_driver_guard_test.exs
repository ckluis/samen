defmodule Samen.Meta.CiDriverGuard do
  @moduledoc """
  ADR-053 — the CI driver's red paths, as NAMED ExUnit tests so the sabotage harness can flip them.

  The driver (`scripts/ci` → `scripts/ci_driver.py`) and the `./ci.sh` / `./ci-fast.sh` wrappers
  are root-level scripts, but `scripts/sabotage.sh` proves a guard by running `mix test` in an APP
  and requiring NAMED tests to fail. This module is that app-level owner: each test runs one case
  of `scripts/ci_test.sh` — the REAL driver against a throwaway git repo and a FAKE manifest (no
  mix, no DB, seconds) — and asserts it passed. The sabotages `scripts/sabotages/496-…` onward
  each break one contract in the driver or a wrapper and name the test below that must go red.

  The cases themselves (and every positive control) live in `scripts/ci_test.sh`; this file only
  gives them names the harness can match. `scripts/ci`'s `ci_selftest` step runs the same script
  directly at the root. One module per case, so ExUnit runs the cases concurrently (tests inside a
  single module run one after another).
  """
  import ExUnit.Assertions

  @repo_root Path.expand("../../..", __DIR__)
  @script Path.join(@repo_root, "scripts/ci_test.sh")

  # The nested driver must not inherit an outer run's state dir / manifest / repo override.
  @scrub ~w(SAMEN_CI_HOME SAMEN_CI_MANIFEST SAMEN_CI_REPO SAMEN_CI_DRIVER SAMEN_CI_TOOLCHAIN)
         |> Enum.map(&{&1, nil})

  def run_case!(name) do
    {out, rc} = System.cmd("bash", [@script, name], stderr_to_stdout: true, env: @scrub)

    assert rc == 0 and out =~ "CASE #{name}: PASS",
           "scripts/ci_test.sh #{name} failed (exit #{rc}):\n#{out}"
  end
end

defmodule Samen.Meta.CiDriverGuardTest.C1Budget do
  use ExUnit.Case, async: true

  test "C1 budget/resume never reports PASS over a deferred, interrupted or unrun step" do
    Samen.Meta.CiDriverGuard.run_case!("C1")
  end
end

defmodule Samen.Meta.CiDriverGuardTest.C2Cache do
  use ExUnit.Case, async: true

  test "C2 the cache invalidates on any input change, an untracked file, a definition change" do
    Samen.Meta.CiDriverGuard.run_case!("C2")
  end
end

defmodule Samen.Meta.CiDriverGuardTest.C3NoFailCache do
  use ExUnit.Case, async: true

  test "C3 a failing step is never cached" do
    Samen.Meta.CiDriverGuard.run_case!("C3")
  end
end

defmodule Samen.Meta.CiDriverGuardTest.C4QuickNotPrReady do
  use ExUnit.Case, async: true

  test "C4 quick never prints a PR-ready verdict" do
    Samen.Meta.CiDriverGuard.run_case!("C4")
  end
end

defmodule Samen.Meta.CiDriverGuardTest.C5Flaky do
  use ExUnit.Case, async: true

  test "C5 a flaky test still fails the run" do
    Samen.Meta.CiDriverGuard.run_case!("C5")
  end
end

defmodule Samen.Meta.CiDriverGuardTest.C6Wrapper do
  use ExUnit.Case, async: true

  test "C6 a wrapper never prints ALL PASSED after a failed step, concurrent ones included" do
    Samen.Meta.CiDriverGuard.run_case!("C6")
  end
end

defmodule Samen.Meta.CiDriverGuardTest.C9Selection do
  use ExUnit.Case, async: true

  test "C9 quick selection follows the dependency graph and sees untracked files" do
    Samen.Meta.CiDriverGuard.run_case!("C9")
  end
end

defmodule Samen.Meta.CiDriverGuardTest.Locks do
  use ExUnit.Case, async: true

  test "steps sharing a lock never overlap and a serial step runs alone" do
    Samen.Meta.CiDriverGuard.run_case!("LOCKS")
  end
end

defmodule Samen.Meta.CiDriverGuardTest.Equiv do
  use ExUnit.Case, async: true

  test "the wrappers keep the pre-ADR-053 step list and markers" do
    Samen.Meta.CiDriverGuard.run_case!("EQUIV")
  end
end

defmodule Samen.Meta.CiDriverGuardTest.A1ActionsPlan do
  use ExUnit.Case, async: true

  test "A1 the Actions plan is a partition: a step in no job, in two, or excluded without a reason fails" do
    Samen.Meta.CiDriverGuard.run_case!("A1")
  end
end

defmodule Samen.Meta.CiDriverGuardTest.A2ActionsCoverage do
  use ExUnit.Case, async: true

  test "A2 the Actions aggregate fails unless every planned step ran once, PASS, on the PR base" do
    Samen.Meta.CiDriverGuard.run_case!("A2")
  end
end

defmodule Samen.Meta.CiDriverGuardTest.A3ActionsSlices do
  use ExUnit.Case, async: true

  test "A3 sliced corpus: the sum of what the slices processed must equal the selected total" do
    Samen.Meta.CiDriverGuard.run_case!("A3")
  end
end
