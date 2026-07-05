defmodule Samen.NoPlaintextPii.Tiers.LogTelemetry do
  @moduledoc """
  CI-mode tier (c): **config-level assertion — `db_statement` must be disabled if
  `opentelemetry_ecto` is present** (T1.8d clause (c); doc §runs 4a
  "`OpentelemetryEcto db_statement: :disabled`").

  `OpentelemetryEcto` attaches to Ecto's telemetry and, by default, records the
  full SQL statement (and, depending on config, bind parameters) as a span
  attribute. On a Samen substrate the SQL text is a projected surface: a query
  filtering/among vaulted rows would put tokens (safe) — but a query that ever
  touches plaintext, or a bind param carrying a revealed value, would leak into
  the trace sink. The doc's posture is therefore categorical: if
  `opentelemetry_ecto` is a dependency, its `db_statement` MUST be `:disabled`.

  ## Config-level check (acceptable now, per T1.8d)

  The full runtime assertion (inspecting the LIVE `OpentelemetryEcto.setup/2`
  options a host wired at boot) is Phase 2 observability (T2.6). At the kernel
  layer we assert the CONFIG-LEVEL invariant:

    * If `opentelemetry_ecto` is NOT a dependency → the tier passes (the leak
      surface does not exist). This is the state today (no OTel dep pinned).

    * If `opentelemetry_ecto` IS a dependency → the app config must set
      `config :samen_core, :opentelemetry_ecto, db_statement: :disabled` (or the
      host must set the equivalent for its own otp_app). If the setting is present
      and is `:disabled`, the tier passes. If it is missing or set to anything
      other than `:disabled`, the tier FAILS CLOSED — a present OTel-Ecto dep with
      an unproven/enabled `db_statement` is a leak until proven disabled.

  This keeps the invariant honest without depending on OTel being installed: the
  moment a host adds `opentelemetry_ecto`, the build fails until they disable
  `db_statement`.
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
    do: "opentelemetry_ecto (if present) has db_statement: :disabled — no SQL text in traces"

  @impl true
  def check(%Context{} = context) do
    if Context.dep_present?(context, @otel_dep) do
      check_db_statement_disabled()
    else
      # The leak surface does not exist — nothing to assert.
      []
    end
  end

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
            "opentelemetry_ecto db_statement",
            "opentelemetry_ecto is a dependency but db_statement is NOT configured as " <>
              ":disabled. A present OTel-Ecto integration records the SQL statement into the " <>
              "trace sink by default — that surface must be proven token-only. Set " <>
              "`config :samen_core, :opentelemetry_ecto, db_statement: :disabled` (fail closed " <>
              "until disabled)."
          )
        ]

      other ->
        [
          Finding.violation(
            @tier,
            "opentelemetry_ecto db_statement",
            "opentelemetry_ecto db_statement is #{inspect(other)}, expected :disabled. " <>
              "Recording SQL text/bind params into traces is a plaintext leak surface — it " <>
              "must be :disabled on a Samen substrate (doc §runs 4a)."
          )
        ]
    end
  end

  # The configured db_statement for the OTel-Ecto integration. A host app (or the
  # kernel's own config for its OTP app) declares:
  #
  #     config :samen_core, :opentelemetry_ecto, db_statement: :disabled
  #
  # We read from :samen_core first (the kernel's config), then the running mix
  # project's otp_app, so a host app's own setting is honoured.
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
end
