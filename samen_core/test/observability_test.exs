defmodule Samen.ObservabilityTest do
  @moduledoc """
  D1.1 (WS-D; ADR-022) — `Samen.Observability.child_specs/1` owns the
  `db_statement: :disabled` default so it is un-forgettable.

  ## Anti-tautology / sabotage design (the AC)

  The AC demands two things: (1) the returned specs CARRY
  `db_statement: :disabled`, and (2) a sabotage REMOVING it is detectable.
  Detection is two-layered here:

    * **boot-time fail-loud** — `attach_otel_ecto/2` raises a named error when
      the option is removed or flipped to `:enabled` (the sabotaged spec cannot
      start silently);
    * **CI-tier live check** — a handler that somehow got attached with
      `db_statement: :enabled` is flagged by the `no_plaintext_pii`
      LogTelemetry tier (mirrors `log_telemetry_live_handler_test.exs`).

  If the helper stopped injecting the option, the green-path spec assertion
  fails; if it stopped refusing bad options, the red-path raises fail.
  """

  use ExUnit.Case, async: false

  alias Samen.NoPlaintextPii
  alias Samen.NoPlaintextPii.Finding
  alias Samen.Observability
  alias Samen.WideEvent.Sinks

  @clean_domains [
    SamenCore.Support.Crm,
    SamenCore.Support.Clinical,
    SamenCore.Support.PropDomain
  ]

  setup do
    on_exit(fn ->
      # Detach anything a test attached, so tests stay order-independent.
      :telemetry.detach({OpentelemetryEcto, [:obs_test_app, :repo, :query]})
      :telemetry.detach({OpentelemetryEcto, [:obs_sabotage_app, :repo, :query]})
      Samen.Metrics.ContentionHandlers.detach()
      Sinks.InMemory.detach()
      Application.delete_env(:obs_test_app, :opentelemetry_ecto)
      Application.delete_env(:obs_test_app, Samen.Observability)
      :ok
    end)
  end

  defp otel_spec(specs) do
    Enum.find(specs, fn
      %{id: {Observability, :otel_ecto, _}} -> true
      _ -> false
    end)
  end

  defp start_all(specs) do
    Enum.each(specs, fn
      %{start: {m, f, a}} -> apply(m, f, a)
      mod when is_atom(mod) -> start_supervised!(mod)
    end)
  end

  defp run_tier(opts) do
    {:ok, findings} =
      NoPlaintextPii.run(
        Keyword.merge(
          [
            domains: @clean_domains,
            deps: [:opentelemetry_ecto],
            tiers: [Samen.NoPlaintextPii.Tiers.LogTelemetry]
          ],
          opts
        )
      )

    findings
    |> NoPlaintextPii.violations()
    |> Enum.filter(&(&1.tier == :log_telemetry))
  end

  describe "child_specs/2 — the un-forgettable db_statement: :disabled" do
    test "the returned OTel-Ecto spec carries db_statement: :disabled in its start MFA" do
      specs = Observability.child_specs(:obs_test_app)

      assert %{start: {Observability, :attach_otel_ecto, [prefix, config]}} = otel_spec(specs)
      assert prefix == [:obs_test_app, :repo]
      assert Keyword.fetch!(config, :db_statement) == :disabled
    end

    test "green path: starting the specs attaches a handler the LogTelemetry tier accepts" do
      :obs_test_app
      |> Observability.child_specs(metrics: false)
      |> start_all()

      handler_id = {OpentelemetryEcto, [:obs_test_app, :repo, :query]}

      assert [handler] =
               Enum.filter(:telemetry.list_handlers([]), &(Map.get(&1, :id) == handler_id))

      assert Keyword.get(handler.config, :db_statement) == :disabled

      # The CI tier's live-handler check finds no violation for this handler.
      violations = run_tier([])

      refute Enum.any?(violations, fn %Finding{subject: subject} ->
               subject =~ "live handler" and subject =~ "obs_test_app"
             end)
    end

    test "restart-safe: attaching twice is a no-op, not a crash" do
      specs = Observability.child_specs(:obs_test_app, metrics: false)
      %{start: {m, f, a}} = otel_spec(specs)

      assert :ignore = apply(m, f, a)
      assert :ignore = apply(m, f, a)
    end
  end

  describe "sabotage red-paths (fail-loud)" do
    test "SABOTAGE: removing db_statement from the setup config raises at boot" do
      assert_raise ArgumentError, ~r/db_statement: :disabled is missing/, fn ->
        Observability.attach_otel_ecto([:obs_sabotage_app, :repo], [])
      end

      # Nothing got attached — the sabotage cannot half-succeed.
      handler_id = {OpentelemetryEcto, [:obs_sabotage_app, :repo, :query]}
      refute Enum.any?(:telemetry.list_handlers([]), &(Map.get(&1, :id) == handler_id))
    end

    test "SABOTAGE: flipping db_statement to :enabled raises at boot, naming the leak" do
      assert_raise ArgumentError, ~r/expected :disabled/, fn ->
        Observability.attach_otel_ecto([:obs_sabotage_app, :repo], db_statement: :enabled)
      end
    end

    test "SABOTAGE: an :enabled handler that bypassed the helper is caught by the CI tier" do
      # Simulate a builder hand-wiring OpentelemetryEcto.setup(..., db_statement: :enabled)
      # instead of using the helper — the LogTelemetry live check must flag it.
      :ok = OpentelemetryEcto.setup([:obs_sabotage_app, :repo], db_statement: :enabled)

      violations = run_tier([])

      assert Enum.any?(violations, fn %Finding{subject: subject} ->
               subject =~ "live handler" and subject =~ "obs_sabotage_app"
             end)
    end

    test "host config contradicting :disabled fails child_specs/2 loudly, naming the key" do
      Application.put_env(:obs_test_app, :opentelemetry_ecto, db_statement: :enabled)

      assert_raise ArgumentError, ~r/config :obs_test_app, :opentelemetry_ecto/, fn ->
        Observability.child_specs(:obs_test_app)
      end
    end

    test "host config declaring :disabled (the generated-app posture) is accepted" do
      Application.put_env(:obs_test_app, :opentelemetry_ecto, db_statement: :disabled)
      assert [_ | _] = Observability.child_specs(:obs_test_app)
    end
  end

  describe "metrics contention handlers" do
    test "attached by default with the host repo prefix; opt-out honored" do
      :obs_test_app |> Observability.child_specs() |> start_all()

      assert Enum.any?(
               :telemetry.list_handlers([]),
               &(Map.get(&1, :id) == "samen-pool-saturation-handler")
             )

      refute Enum.any?(Observability.child_specs(:obs_test_app, metrics: false), fn
               %{id: {Observability, :contention_handlers, _}} -> true
               _ -> false
             end)
    end
  end

  describe "wide-event sinks" do
    test "default is none (a sink is a debug surface, matching the reference verticals)" do
      refute Enum.any?(Observability.child_specs(:obs_test_app), fn
               Sinks.InMemory -> true
               %{id: {Observability, :in_memory_attach, _}} -> true
               _ -> false
             end)
    end

    test ":in_memory opt-in yields the GenServer child + attach, and events flow" do
      specs = Observability.child_specs(:obs_test_app, wide_event_sinks: [:in_memory])
      assert Sinks.InMemory in specs

      start_all(specs -- [otel_spec(specs)])

      :ok = Samen.WideEvent.emit([action: :obs_test_sink_flow, row_count: 1], :build)

      assert Enum.any?(Sinks.InMemory.events(), &(&1.action == :obs_test_sink_flow))
    end

    test "unknown sink names raise (no silent misconfiguration)" do
      assert_raise ArgumentError, ~r/unknown wide-event sink/, fn ->
        Observability.child_specs(:obs_test_app, wide_event_sinks: [:honeycomb])
      end
    end
  end
end
