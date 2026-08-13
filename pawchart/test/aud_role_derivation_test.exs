defmodule PawChart.AudRoleDerivationTest do
  @moduledoc """
  ADR-045 §4.2 (O4) fold-in — PawChart's `aud_event` + `aud_chain` prod migrations must
  DERIVE their `REVOKE UPDATE, DELETE` role at migration time (the `:aud_event_app_role`
  knob → `PawChart.Repo`'s configured `:username` → RAISE), NEVER a hardcoded developer
  laptop role (`"clank"`).

  Before this fold-in both migrations set `@app_role Application.compile_env(:pawchart,
  :aud_event_app_role, "clank")` — so a fresh prod deploy that did not set the knob at
  BUILD time emitted `REVOKE UPDATE, DELETE ON aud_event FROM clank` and the first
  `release_command` aborted with `role "clank" does not exist`. The O7 fix (reading
  pawchart's OWN `:pawchart` otp_app, not driftwood's key) is preserved — the derivation
  reads `:pawchart`. Mirrors the generated-template O4 proof for the shipped vet vertical.
  """
  use ExUnit.Case, async: true

  @migrations_dir Path.join(__DIR__, "../priv/repo/migrations")

  defp source(file), do: File.read!(Path.join(@migrations_dir, file))

  for file <- ["20260705020000_aud_event.exs", "20260807110500_aud_chain.exs"] do
    @mig_file file

    test "#{@mig_file} derives its REVOKE role and never ships the literal 'clank'" do
      src = source(@mig_file)

      refute src =~ "clank",
             "#{@mig_file} must not carry the hardcoded 'clank' laptop role — derive it instead"

      refute src =~ "Application.compile_env",
             "#{@mig_file} must derive the role at MIGRATION time, not compile_env a static default"

      # Positive control — derived through the shared helper off PawChart's OWN otp_app (O7).
      assert src =~ "Samen.OperatorPlane.Migration.app_role!(:pawchart, PawChart.Repo)"
    end
  end

  test "the aud_event migration still REVOKEs UPDATE/DELETE (the append-only control is intact)" do
    src = source("20260705020000_aud_event.exs")
    assert src =~ "REVOKE UPDATE, DELETE ON aud_event"
  end

  test "the shared derivation resolves the CONFIGURED repo role in this env (derived, not a hardcoded literal)" do
    role = Samen.OperatorPlane.Migration.app_role!(:pawchart, PawChart.Repo)
    configured = Application.get_env(:pawchart, PawChart.Repo)[:username]

    # The guarantee is DERIVATION, not the absence of a particular string: the role tracks the
    # repo's REAL configured `:username` (read off pawchart's OWN otp_app — the O7 fix) rather
    # than a compile-time hardcoded default.
    assert role != "" and role == configured
  end
end
