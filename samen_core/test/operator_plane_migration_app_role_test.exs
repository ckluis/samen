defmodule Samen.OperatorPlane.MigrationAppRoleTest do
  @moduledoc """
  ADR-045 §4.2 (O4) — the SHARED migration-role derivation `app_role!/2`.

  This is the single source of truth the in-repo host migrations (driftwood/pawchart/demo
  `aud_event` + `aud_chain`) call so a REVOKE role is DERIVED at migration time, never a
  hardcoded developer laptop role (`"clank"`) shipped into an adopter's prod migration.

  Anti-tautology: every red path carries a positive control (a test that cannot fail is a
  bug). The knob-wins and username-fallback proofs demonstrate the derivation returns a REAL
  role; the underivable proof demonstrates it RAISES rather than emitting an arbitrary role;
  and every path asserts the result is never the literal `"clank"`.
  """
  use ExUnit.Case, async: false

  alias Samen.OperatorPlane.Migration

  # A throwaway otp_app + repo module used only for these config-scoped assertions — never a
  # real host, so tests never mutate a shipped app's env.
  @otp :samen_core_app_role_probe
  defmodule ProbeRepo do
  end

  setup do
    on_exit(fn ->
      Application.delete_env(@otp, :aud_event_app_role)
      Application.delete_env(@otp, ProbeRepo)
    end)

    :ok
  end

  test "the :aud_event_app_role knob WINS when set (the prod-deploy path)" do
    Application.put_env(@otp, :aud_event_app_role, "prod_app_rw")
    # Even with a repo username present, the explicit knob takes precedence.
    Application.put_env(@otp, ProbeRepo, username: "ignored_username")

    assert Migration.app_role!(@otp, ProbeRepo) == "prod_app_rw"
  end

  test "falls back to the repo's configured :username when the knob is unset (dev/CI path)" do
    # No knob configured.
    Application.put_env(@otp, ProbeRepo, username: "ci_runner_role")

    role = Migration.app_role!(@otp, ProbeRepo)

    assert role == "ci_runner_role"
    # The regression this closes: never the developer laptop role.
    refute role == "clank"
  end

  test "RAISES a named error when the role is underivable — refuses to guess (never emits 'clank')" do
    # Neither the knob nor a repo :username is configured.
    Application.put_env(@otp, ProbeRepo, [])

    err =
      assert_raise RuntimeError, fn ->
        Migration.app_role!(@otp, ProbeRepo)
      end

    # The message names the fix (the knob) and the app — an operator-actionable failure.
    assert err.message =~ ":aud_event_app_role"
    assert err.message =~ "samen_core_app_role_probe"
    # It refuses to emit an arbitrary role rather than silently defaulting to a laptop name.
    refute err.message =~ ~s(REVOKE UPDATE, DELETE ON aud_event FROM clank)
  end

  test "an empty-string knob is treated as UNSET and falls through to :username (empty is missing)" do
    Application.put_env(@otp, :aud_event_app_role, "")
    Application.put_env(@otp, ProbeRepo, username: "fallback_role")

    assert Migration.app_role!(@otp, ProbeRepo) == "fallback_role"
  end
end
