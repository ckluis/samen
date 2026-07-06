defmodule Samen.LogTelemetryLiveHandlerTest do
  @moduledoc """
  T2.6 extension to the LogTelemetry tier: live telemetry handler check.

  The T1.8d (Phase 1) check only inspected the config-level `db_statement` key.
  T2.6 adds a second check: inspect ALL registered `:telemetry` handlers whose
  handler_id matches `{OpentelemetryEcto, _}` and verify that the attached config
  has `db_statement: :disabled` (or omitted, which defaults to :disabled).

  ## Red path

  A live handler registered via `OpentelemetryEcto.setup/2` with `db_statement: :enabled`
  triggers a violation even if the config-level key says `:disabled`.

  ## Anti-tautology probe

  The anti-tautology is built into the test design: the red path test explicitly
  registers an `:enabled` handler, then asserts a violation. The green path test
  registers a `:disabled` handler, then asserts no violation (from the live check).
  If the live check did nothing, the red path test would fail (violation expected
  but not found).
  """

  use ExUnit.Case, async: false

  alias Samen.NoPlaintextPii
  alias Samen.NoPlaintextPii.Finding

  @clean_domains [
    SamenCore.Support.Crm,
    SamenCore.Support.Clinical,
    SamenCore.Support.PropDomain
  ]

  setup do
    # Ensure the config key is set to :disabled (the required posture)
    # so the config-level check passes; we only want to test the live handler check.
    prev = Application.get_env(:samen_core, :opentelemetry_ecto)
    Application.put_env(:samen_core, :opentelemetry_ecto, db_statement: :disabled)

    on_exit(fn ->
      if prev do
        Application.put_env(:samen_core, :opentelemetry_ecto, prev)
      else
        Application.delete_env(:samen_core, :opentelemetry_ecto)
      end
    end)

    :ok
  end

  defp run_check(opts) do
    {:ok, findings} =
      NoPlaintextPii.run(
        Keyword.merge(
          [
            domains: @clean_domains,
            deps: [:opentelemetry_ecto]
          ],
          opts
        )
      )

    findings
  end

  # ---------------------------------------------------------------------------
  # Green path: no live handler, or live handler with :disabled
  # ---------------------------------------------------------------------------

  describe "live handler check — green paths" do
    test "passes with no live OpentelemetryEcto handlers registered" do
      # No setup — no handlers registered for this event prefix
      findings =
        run_check(tiers: [Samen.NoPlaintextPii.Tiers.LogTelemetry])

      live_violations =
        Enum.filter(NoPlaintextPii.violations(findings), fn f ->
          f.tier == :log_telemetry and
            String.contains?(f.subject, "live handler")
        end)

      assert live_violations == [],
             "Expected no live-handler violations when no handlers are registered"
    end

    test "passes when a live handler has db_statement: :disabled" do
      event_prefix = [:log_tel_green, :repo]
      OpentelemetryEcto.setup(event_prefix, db_statement: :disabled)

      findings =
        run_check(tiers: [Samen.NoPlaintextPii.Tiers.LogTelemetry])

      violations = NoPlaintextPii.violations(findings)
      # No live-handler violations (the handler has :disabled)
      live_violations =
        Enum.filter(violations, fn f ->
          f.tier == :log_telemetry and String.contains?(f.subject, "live handler")
        end)

      assert live_violations == [],
             "Expected no live-handler violations with db_statement: :disabled; got: #{inspect(live_violations)}"

      :telemetry.detach({OpentelemetryEcto, event_prefix ++ [:query]})
    end

    test "passes when a live handler has db_statement omitted (default :disabled)" do
      # omitting db_statement in OpentelemetryEcto.setup defaults to :disabled
      event_prefix = [:log_tel_default, :repo]
      # Do NOT pass db_statement at all — the default in opentelemetry_ecto is :disabled
      OpentelemetryEcto.setup(event_prefix)

      findings =
        run_check(tiers: [Samen.NoPlaintextPii.Tiers.LogTelemetry])

      violations = NoPlaintextPii.violations(findings)
      live_violations =
        Enum.filter(violations, fn f ->
          f.tier == :log_telemetry and String.contains?(f.subject, "live handler")
        end)

      assert live_violations == [],
             "Expected no violation with default (omitted) db_statement; got: #{inspect(live_violations)}"

      :telemetry.detach({OpentelemetryEcto, event_prefix ++ [:query]})
    end
  end

  # ---------------------------------------------------------------------------
  # RED PATH: live handler with db_statement: :enabled
  # ---------------------------------------------------------------------------

  describe "live handler check — red path" do
    @tag :red_path
    test "flags a live OpentelemetryEcto handler with db_statement: :enabled" do
      # Register a handler that WOULD record SQL text — this is the violation
      event_prefix = [:log_tel_red, :repo]
      OpentelemetryEcto.setup(event_prefix, db_statement: :enabled)

      findings =
        run_check(tiers: [Samen.NoPlaintextPii.Tiers.LogTelemetry])

      live_violations =
        Enum.filter(NoPlaintextPii.violations(findings), fn f ->
          f.tier == :log_telemetry and String.contains?(f.subject, "live handler")
        end)

      assert live_violations != [],
             "Expected a live-handler violation for db_statement: :enabled, but none found. " <>
               "The live check is not working."

      formatted = Enum.map_join(live_violations, "\n", &Finding.format/1)
      assert String.contains?(formatted, "db_statement"),
             "Violation message should mention db_statement; got: #{formatted}"
      assert String.contains?(formatted, "enabled") or String.contains?(formatted, ":enabled"),
             "Violation message should mention :enabled; got: #{formatted}"

      :telemetry.detach({OpentelemetryEcto, event_prefix ++ [:query]})
    end
  end
end
