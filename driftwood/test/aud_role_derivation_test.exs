defmodule Driftwood.AudRoleDerivationTest do
  @moduledoc """
  ADR-045 §4.2 (O4) fold-in — Driftwood's `aud_event` + `aud_chain` prod migrations must
  DERIVE their `REVOKE UPDATE, DELETE` role at migration time (the `:aud_event_app_role`
  knob → `Driftwood.Repo`'s configured `:username` → RAISE), NEVER a hardcoded developer
  laptop role (`"clank"`).

  Before this fold-in both migrations set `@app_role Application.compile_env(:driftwood,
  :aud_event_app_role, "clank")` — a COMPILE-time default of a developer's local Postgres
  role. A fresh prod deploy that did not set the knob at BUILD time therefore emitted
  `REVOKE UPDATE, DELETE ON aud_event FROM clank`, and the first `release_command` aborted
  with `role "clank" does not exist`. This mirrors the generated-template O4 proof
  (`samen_core/test/gen_deploy_bootability_test.exs`) for the shipped vertical.

  Anti-tautology: the source assertions carry positive controls (the REVOKE still happens,
  just against a derived role), and the runtime proof shows the derivation returns a REAL
  role in this env rather than the removed literal.
  """
  use ExUnit.Case, async: true

  @migrations_dir Path.join(__DIR__, "../priv/repo/migrations")

  defp source(file), do: File.read!(Path.join(@migrations_dir, file))

  for file <- ["20260705020000_aud_event.exs", "20260707200000_aud_chain.exs"] do
    @mig_file file

    test "#{@mig_file} derives its REVOKE role and never ships the literal 'clank'" do
      src = source(@mig_file)

      # The defect: a hardcoded developer laptop role anywhere in the migration.
      refute src =~ "clank",
             "#{@mig_file} must not carry the hardcoded 'clank' laptop role — derive it instead"

      # The old shape is gone (a compile-time default of a laptop role).
      refute src =~ "Application.compile_env",
             "#{@mig_file} must derive the role at MIGRATION time, not compile_env a static default"

      # Positive control — the derivation IS wired through the shared helper.
      assert src =~ "Samen.OperatorPlane.Migration.app_role!(:driftwood, Driftwood.Repo)"
    end
  end

  test "the aud_event migration still REVOKEs UPDATE/DELETE (the append-only control is intact)" do
    src = source("20260705020000_aud_event.exs")
    assert src =~ "REVOKE UPDATE, DELETE ON aud_event"
  end

  test "the shared derivation resolves the CONFIGURED repo role in this env (derived, not a hardcoded literal)" do
    role = Samen.OperatorPlane.Migration.app_role!(:driftwood, Driftwood.Repo)
    configured = Application.get_env(:driftwood, Driftwood.Repo)[:username]

    # The guarantee is DERIVATION, not the absence of a particular string: the role tracks the
    # repo's REAL configured `:username` rather than a compile-time hardcoded default. (On this
    # dev laptop the connection role genuinely IS the local user — which is exactly why a
    # HARDCODED default of someone's laptop role was the O4 hazard on a PROD host where it isn't.)
    assert role != "" and role == configured
  end
end
