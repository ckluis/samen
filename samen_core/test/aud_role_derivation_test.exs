defmodule SamenCore.AudRoleDerivationTest do
  @moduledoc """
  ADR-045 §4.2 (O4), kernel test repo — samen_core's own `aud_event` + `aud_chain` test-repo
  migrations must DERIVE their `REVOKE UPDATE, DELETE` role at migration time (the
  `:aud_event_app_role` knob → `SamenCore.TestRepo`'s configured `:username` → RAISE), the
  same way the verticals (`driftwood/test/aud_role_derivation_test.exs`,
  `pawchart/test/aud_role_derivation_test.exs`) and the generated template already do.

  Before this, both migrations set `@app_role Application.compile_env(:samen_core,
  :aud_event_app_role, "clank")` — the maintainer's laptop role. Any contributor (or CI runner)
  whose Postgres role was not `clank` could not migrate the kernel test database
  (`role "clank" does not exist`), so GitHub Actions had to impersonate it.

  Anti-tautology: the source assertions carry positive controls (the REVOKE still happens, via
  the shared helper), and the runtime proof shows the derivation returns the CONFIGURED role.
  """
  use ExUnit.Case, async: true

  @migrations_dir Path.join(__DIR__, "../priv/test_repo/migrations")

  defp source(file), do: File.read!(Path.join(@migrations_dir, file))

  # Written out per file (not a `for` over file names) so each test's name is a literal the
  # sabotage harness can locate (MUST_FAIL headers are matched against the test source).
  defp assert_derived!(file) do
    src = source(file)

    refute src =~ "clank",
           "#{file} must not carry the hardcoded 'clank' laptop role — derive it instead"

    refute src =~ "Application.compile_env",
           "#{file} must derive the role at MIGRATION time, not compile_env a static default"

    # Positive control — the derivation IS wired through the shared helper.
    assert src =~ "Samen.OperatorPlane.Migration.app_role!(:samen_core, SamenCore.TestRepo)"
  end

  test "test-repo aud_event migration derives its REVOKE role and never ships the literal 'clank'" do
    assert_derived!("20260705080000_aud_event.exs")
  end

  test "test-repo aud_chain migration derives its REVOKE role and never ships the literal 'clank'" do
    assert_derived!("20260707020000_aud_chain.exs")
  end

  test "the test-repo aud_event migration still REVOKEs UPDATE/DELETE (append-only control intact)" do
    assert source("20260705080000_aud_event.exs") =~ "REVOKE UPDATE, DELETE ON aud_event"
  end

  # Repo-wide: no migration in ANY app (kernel, web, verticals, spikes, adapters) may name the
  # maintainer's laptop role. samen_web's aud_event migration slipped past the per-app guards
  # (it read `compile_env(:driftwood, …, <laptop role>)`); a new vertical copying it would too.
  # Matches the role as a literal or a REVOKE/GRANT target, not prose paths like /Users/<name>.
  test "no app's migrations hardcode the maintainer's laptop role (repo-wide)" do
    root = Path.expand("../..", __DIR__)
    role_literal = ~r/["']clank["']|\b(FROM|TO)\s+clank\b/

    offenders =
      Path.wildcard(Path.join(root, "*/priv/**/migrations/*.exs")) ++
        Path.wildcard(Path.join(root, "spikes/*/priv/**/migrations/*.exs"))

    offenders =
      offenders
      |> Enum.uniq()
      |> Enum.filter(&(File.read!(&1) =~ role_literal))
      |> Enum.map(&Path.relative_to(&1, root))

    # Positive control: the scan actually sees the migrations it guards.
    assert Path.join(root, "samen_web/priv/repo/migrations/20260705020000_aud_event.exs") in Path.wildcard(
             Path.join(root, "*/priv/**/migrations/*.exs")
           )

    assert offenders == [],
           "migrations hardcoding the laptop role (derive it via Samen.OperatorPlane.Migration.app_role!/2): " <>
             inspect(offenders)
  end

  test "the shared derivation resolves SamenCore.TestRepo's configured role in this env" do
    role = Samen.OperatorPlane.Migration.app_role!(:samen_core, SamenCore.TestRepo)
    configured = Application.get_env(:samen_core, SamenCore.TestRepo)[:username]
    assert role != "" and role == configured
  end
end
