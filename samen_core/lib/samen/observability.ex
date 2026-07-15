defmodule Samen.Observability do
  @moduledoc """
  One-call observability wiring for a Samen host app (WS-D D1.1; ADR-022).

  `child_specs/2` returns the supervised pieces a builder splices into
  `Application.start/2` — the OTel-Ecto telemetry attach, the metrics contention
  handlers, and any configured wide-event sinks — so the observability plane the
  guides describe (`docs/observability-guide.md`) is wired in ONE line instead of
  hand-copied setup calls:

      def start(_type, _args) do
        children =
          Samen.Observability.child_specs(:my_app) ++
            [MyApp.Repo, {Oban, ...}, MyAppWeb.Endpoint]

        Supervisor.start_link(children, strategy: :one_for_one)
      end

  ## The un-forgettable `db_statement: :disabled` (the trap this kills)

  `OpentelemetryEcto` records SQL text into trace spans unless `db_statement:
  :disabled` — on a Samen substrate that surface must be proven token-only, so
  the posture is categorical (doc §runs 4a; `no_plaintext_pii` LogTelemetry
  tier). Before this helper, a builder had to remember to write
  `OpentelemetryEcto.setup([:app, :repo], db_statement: :disabled)` by hand and
  forgetting the option only surfaced LATER, at CI time.

  This module **owns** the `db_statement: :disabled` default and makes it
  structurally un-removable:

    * the returned OTel-Ecto child spec always carries `db_statement: :disabled`
      in its start MFA (inspectable — the D1.1 unit test asserts it);
    * `attach_otel_ecto/2` refuses to start with any other value — a sabotaged
      spec (option removed or flipped to `:enabled`) raises a named error at
      boot instead of leaking silently (fail-loud red-path);
    * a host app config (`config :my_app, :opentelemetry_ecto, db_statement: …`)
      that contradicts `:disabled` raises at `child_specs/2` build time, naming
      the offending key.

  ## What is wired

  1. **OTel-Ecto** — `OpentelemetryEcto.setup(prefix, db_statement: :disabled)`
     as a setup-only child (`:ignore` after attach; idempotent on restart).
     Default event prefix is `[otp_app, :repo]`; override with `:repo_event_prefix`.
  2. **Metrics contention handlers** — `Samen.Metrics.ContentionHandlers.attach/1`
     with the same repo prefix (pool-saturation + Oban stop/exception signals,
     T2.8). Opt out with `metrics: false`.
  3. **Wide-event sinks** — none by default (matching the reference verticals:
     sinks are a debug surface attached on demand). Opt in with
     `wide_event_sinks: [:in_memory | :file]` or
     `config :my_app, Samen.Observability, wide_event_sinks: [...]`.

  `Samen.Tracer` needs no supervision — it is a macro layer over the OTel API;
  the SDK application starts as an ordinary dependency app.

  ## Options

    * `:repo_event_prefix` — Ecto telemetry prefix (default `[otp_app, :repo]`)
    * `:metrics` — attach the contention handlers (default `true`)
    * `:pool_saturation_threshold_ms` — forwarded to the contention handlers
    * `:wide_event_sinks` — list of `:in_memory` / `:file` (default from
      `config otp_app, Samen.Observability`, else `[]`)
  """

  alias Samen.Metrics.ContentionHandlers
  alias Samen.WideEvent.Sinks

  @db_statement_posture :disabled
  @known_sinks [:in_memory, :file]

  @doc """
  The child specs wiring the observability plane for `otp_app`.

  Splice the result at the FRONT of the supervision children so telemetry
  handlers are attached before the Repo issues its first query.

  Raises `ArgumentError` if the host config declares
  `config otp_app, :opentelemetry_ecto, db_statement:` with any value other
  than `:disabled` (fail loud at build time, not at CI time).
  """
  @spec child_specs(atom(), keyword()) :: [Supervisor.child_spec()]
  def child_specs(otp_app, opts \\ []) when is_atom(otp_app) and is_list(opts) do
    assert_host_config_posture!(otp_app)

    prefix = Keyword.get(opts, :repo_event_prefix, [otp_app, :repo])

    [otel_ecto_spec(otp_app, prefix)] ++
      metrics_specs(otp_app, prefix, opts) ++
      wide_event_sink_specs(otp_app, opts)
  end

  # ---------------------------------------------------------------------------
  # OTel-Ecto (the un-forgettable db_statement: :disabled)
  # ---------------------------------------------------------------------------

  defp otel_ecto_spec(otp_app, prefix) do
    %{
      id: {__MODULE__, :otel_ecto, otp_app},
      start: {__MODULE__, :attach_otel_ecto, [prefix, [db_statement: @db_statement_posture]]},
      restart: :transient,
      type: :worker
    }
  end

  @doc """
  Setup-only child start: attaches `OpentelemetryEcto` and returns `:ignore`.

  Refuses (raises, naming the guarantee) unless `config` carries
  `db_statement: :disabled` — so a sabotaged child spec fails the boot loudly
  instead of silently recording SQL text into the trace sink.
  """
  @spec attach_otel_ecto([atom()], keyword()) :: :ignore
  def attach_otel_ecto(prefix, config) when is_list(prefix) and is_list(config) do
    case Keyword.fetch(config, :db_statement) do
      {:ok, @db_statement_posture} ->
        :ok

      {:ok, other} ->
        raise ArgumentError,
              "Samen.Observability: OpentelemetryEcto db_statement is #{inspect(other)}, " <>
                "expected :disabled. SQL text in trace spans is a plaintext-PII leak surface " <>
                "on a Samen substrate (no_plaintext_pii LogTelemetry tier) — refusing to boot."

      :error ->
        raise ArgumentError,
              "Samen.Observability: db_statement: :disabled is missing from the OpentelemetryEcto " <>
                "setup config. This helper owns that default — use " <>
                "Samen.Observability.child_specs/2 rather than hand-building the spec."
    end

    case OpentelemetryEcto.setup(prefix, config) do
      :ok -> :ignore
      # Restart-safe: the handler survives a supervisor restart of this child.
      {:error, :already_exists} -> :ignore
    end
  end

  defp assert_host_config_posture!(otp_app) do
    declared =
      otp_app
      |> Application.get_env(:opentelemetry_ecto, [])
      |> Keyword.get(:db_statement, @db_statement_posture)

    unless declared == @db_statement_posture do
      raise ArgumentError,
            "Samen.Observability: `config #{inspect(otp_app)}, :opentelemetry_ecto` declares " <>
              "db_statement: #{inspect(declared)}, expected :disabled. Fix the config — the " <>
              "observability plane will not start with SQL text recording enabled."
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Metrics (contention handlers)
  # ---------------------------------------------------------------------------

  defp metrics_specs(otp_app, prefix, opts) do
    if Keyword.get(opts, :metrics, true) do
      attach_opts =
        [repo_event_prefix: prefix] ++
          Keyword.take(opts, [:pool_saturation_threshold_ms])

      [
        %{
          id: {__MODULE__, :contention_handlers, otp_app},
          start: {__MODULE__, :attach_contention_handlers, [attach_opts]},
          restart: :transient,
          type: :worker
        }
      ]
    else
      []
    end
  end

  @doc false
  @spec attach_contention_handlers(keyword()) :: :ignore
  def attach_contention_handlers(opts) do
    # attach/1 is restart-safe: :telemetry.attach of an existing handler id
    # returns {:error, :already_exists}, which ContentionHandlers ignores.
    :ok = ContentionHandlers.attach(opts)
    :ignore
  end

  # ---------------------------------------------------------------------------
  # Wide-event sinks (opt-in; default none — a sink is a debug surface)
  # ---------------------------------------------------------------------------

  defp wide_event_sink_specs(otp_app, opts) do
    sinks =
      Keyword.get(
        opts,
        :wide_event_sinks,
        Application.get_env(otp_app, __MODULE__, [])
        |> Keyword.get(:wide_event_sinks, [])
      )

    Enum.flat_map(sinks, fn
      :in_memory ->
        [
          Sinks.InMemory,
          %{
            id: {__MODULE__, :in_memory_attach, otp_app},
            start: {__MODULE__, :attach_sink, [Sinks.InMemory, []]},
            restart: :transient,
            type: :worker
          }
        ]

      :file ->
        [
          %{
            id: {__MODULE__, :file_attach, otp_app},
            start: {__MODULE__, :attach_sink, [Sinks.File, []]},
            restart: :transient,
            type: :worker
          }
        ]

      other ->
        raise ArgumentError,
              "Samen.Observability: unknown wide-event sink #{inspect(other)} — " <>
                "supported: #{inspect(@known_sinks)} (the OTLP sink is operator-wired; " <>
                "see docs/observability-guide.md §3)."
    end)
  end

  @doc false
  @spec attach_sink(module(), keyword()) :: :ignore
  def attach_sink(Sinks.InMemory, _opts) do
    case Sinks.InMemory.attach() do
      :ok -> :ignore
      {:error, :already_exists} -> :ignore
    end
  end

  def attach_sink(Sinks.File, opts) do
    case Sinks.File.attach(opts) do
      :ok -> :ignore
      {:error, :already_exists} -> :ignore
    end
  end
end
