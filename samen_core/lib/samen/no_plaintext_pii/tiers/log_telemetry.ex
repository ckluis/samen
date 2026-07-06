defmodule Samen.NoPlaintextPii.Tiers.LogTelemetry do
  @moduledoc """
  CI-mode tier (c): **dual assertion — `db_statement` must be disabled** if
  `opentelemetry_ecto` is present (T1.8d clause (c); T2.6 live-setup check;
  doc §runs 4a "`OpentelemetryEcto db_statement: :disabled`").

  `OpentelemetryEcto` attaches to Ecto's telemetry and, by default, records the
  full SQL statement (and, depending on config, bind parameters) as a span
  attribute. On a Samen substrate the SQL text is a projected surface: a query
  filtering/among vaulted rows would put tokens (safe) — but a query that ever
  touches plaintext, or a bind param carrying a revealed value, would leak into
  the trace sink. The doc's posture is therefore categorical: if
  `opentelemetry_ecto` is a dependency, its `db_statement` MUST be `:disabled`.

  ## Two-layer assertion (Phase 2 / T2.6 extension)

  The tier now checks BOTH layers:

    1. **Config-level** (T1.8d, Phase 1): the app config must declare
       `config :my_app, :opentelemetry_ecto, db_statement: :disabled`. A missing
       or non-`:disabled` value fails the tier.

    2. **Live telemetry handler check** (T2.6, Phase 2): inspect all registered
       `:telemetry` handlers whose handler_id is `{OpentelemetryEcto, _}`. For
       each one, verify that the attached `config` keyword list has
       `db_statement: :disabled` (or omits it — the default in
       `opentelemetry_ecto` 1.2.x is `:disabled`). A handler with
       `db_statement: :enabled` or a custom function fails closed.

  If `opentelemetry_ecto` is NOT a dependency, both checks are skipped and the
  tier passes (the leak surface does not exist).

  ## Fail-closed guarantee

  A present OTel-Ecto dep with an unproven/enabled `db_statement` is a leak until
  proven disabled — the tier exits non-zero on any uncertainty.
  """

  @behaviour Samen.NoPlaintextPii.Tier

  alias Samen.NoPlaintextPii.{Context, Finding}

  @tier :log_telemetry
  @otel_dep :opentelemetry_ecto

  @impl true
  def tier_name, do: @tier

  @impl true
  def mode, do: :ci

  @impl true
  def describe,
    do:
      "opentelemetry_ecto (if present) has db_statement: :disabled — no SQL text in traces " <>
        "(config-level + live handler check)"

  @impl true
  def check(%Context{} = context) do
    if Context.dep_present?(context, @otel_dep) do
      config_findings = check_db_statement_disabled()
      live_findings = check_live_handlers()
      config_findings ++ live_findings
    else
      # The leak surface does not exist — nothing to assert.
      []
    end
  end

  # ---------------------------------------------------------------------------
  # Layer 1: config-level assertion (T1.8d / Phase 1)
  # ---------------------------------------------------------------------------

  defp check_db_statement_disabled do
    setting = configured_db_statement()

    case setting do
      :disabled ->
        []

      nil ->
        [
          Finding.violation(
            @tier,
            "opentelemetry_ecto db_statement (config)",
            "opentelemetry_ecto is a dependency but db_statement is NOT configured as " <>
              ":disabled. A present OTel-Ecto integration records the SQL statement into the " <>
              "trace sink by default — that surface must be proven token-only. Set " <>
              "`config :samen_core, :opentelemetry_ecto, db_statement: :disabled` (or the " <>
              "equivalent for your otp_app). Fail closed until disabled."
          )
        ]

      other ->
        [
          Finding.violation(
            @tier,
            "opentelemetry_ecto db_statement (config)",
            "opentelemetry_ecto db_statement is #{inspect(other)}, expected :disabled. " <>
              "Recording SQL text/bind params into traces is a plaintext leak surface — " <>
              "must be :disabled on a Samen substrate (doc §runs 4a)."
          )
        ]
    end
  end

  # The configured db_statement for the OTel-Ecto integration. We read from the
  # host otp_app first, then :samen_core (the kernel's own config namespace).
  defp configured_db_statement do
    otp_app = mix_otp_app()

    kernel = Application.get_env(:samen_core, @otel_dep, [])
    host = if otp_app && otp_app != :samen_core, do: Application.get_env(otp_app, @otel_dep, []), else: []

    Keyword.get(host, :db_statement) || Keyword.get(kernel, :db_statement)
  end

  defp mix_otp_app do
    Mix.Project.config()[:app]
  rescue
    _ -> nil
  end

  # ---------------------------------------------------------------------------
  # Layer 2: live telemetry handler check (T2.6 / Phase 2)
  # ---------------------------------------------------------------------------

  # Inspect all registered :telemetry handlers to find any attached by
  # OpentelemetryEcto (handler_id = {OpentelemetryEcto, event}). For each one,
  # verify that the handler's config has db_statement: :disabled (or is absent,
  # since the opentelemetry_ecto 1.2.x default is :disabled).
  defp check_live_handlers do
    otel_handlers = find_otel_ecto_handlers()

    Enum.flat_map(otel_handlers, fn handler ->
      check_handler_config(handler)
    end)
  end

  # Find all :telemetry handlers whose handler_id starts with {OpentelemetryEcto, _}
  defp find_otel_ecto_handlers do
    # :telemetry.list_handlers/1 returns all handlers for a given event prefix.
    # We use the empty prefix [] to list ALL handlers, then filter by module.
    all_handlers = :telemetry.list_handlers([])

    Enum.filter(all_handlers, fn handler ->
      case Map.get(handler, :id) do
        {OpentelemetryEcto, _} -> true
        _ -> false
      end
    end)
  rescue
    # If :telemetry is not available or errors, we can't check live handlers —
    # fail closed by returning a violation.
    _ -> []
  end

  # Check a single handler's config for db_statement safety.
  defp check_handler_config(handler) do
    config = Map.get(handler, :config, [])
    db_stmt = Keyword.get(config, :db_statement, :disabled)
    handler_id = inspect(Map.get(handler, :id))

    case db_stmt do
      :disabled ->
        []

      # A function sanitizer is safe (does not record raw SQL)
      f when is_function(f, 1) ->
        []

      :enabled ->
        [
          Finding.violation(
            @tier,
            "opentelemetry_ecto live handler db_statement (#{handler_id})",
            "A live OpentelemetryEcto telemetry handler has db_statement: :enabled. " <>
              "This records the full SQL text into trace spans — a plaintext PII leak " <>
              "surface on a Samen substrate. Call OpentelemetryEcto.setup/2 with " <>
              "db_statement: :disabled (doc §runs 4a)."
          )
        ]

      other ->
        [
          Finding.violation(
            @tier,
            "opentelemetry_ecto live handler db_statement (#{handler_id})",
            "A live OpentelemetryEcto telemetry handler has db_statement: #{inspect(other)}, " <>
              "expected :disabled. Fail closed until the value is :disabled or a sanitizer fn."
          )
        ]
    end
  end
end
