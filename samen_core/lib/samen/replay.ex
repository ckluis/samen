defmodule Samen.Replay do
  @moduledoc """
  `Samen.Replay` — tenant-plane LiveView session CAPTURE that never stores plaintext
  (ADR-052 §2.2, P2). The player and who may watch are P3; this module records.

  ## Shape (inspired by `phoenix_replay`, rebuilt — no code or storage model taken)

    * **Recorder** — `Samen.Web.Replay.Recorder` (samen_web): attached on the CONNECTED mount of
      every framework TENANT `live_session` by `Samen.Web.TenantAuthz` (the hook every tenant
      session already carries, so a vertical adopts at 0 authored lines). It attaches
      `:handle_params` / `:after_render` / `:handle_info` lifecycle hooks.
    * **Events** — `Samen.Replay.Capture`, a `:telemetry` handler on
      `[:phoenix, :live_view | :live_component, :handle_event, :start]`, so an event halted by
      another hook is still seen.
    * **Sanitizer** — `Samen.Replay.Sanitizer`: record by reference, default-deny. Nothing
      reaches a frame without passing it.
    * **Buffer** — `Samen.Replay.Buffer`: an ETS table written from the LiveView process.
    * **Monitor** — `Samen.Replay.Monitor`: monitors each recorded LiveView, and on exit
      persists the session (only if it saw ≥ 1 user interaction) through `Samen.Replay.Store`.
    * **Storage** — `Samen.Replay.Session` + `Samen.Replay.Frame` (framework-owned Ash resources,
      `Samen.Replay.Domain`, JSONB payloads), TTL via `Samen.Retention` (default 14 days,
      max #{90}).

  ## Off by default, per-org opt-in (ADR-052 §2.2 rule 5, R11)

  Two independent switches, both required:

    1. the host turns the capture plane on (`Samen.Observability.child_specs(app, replay: true)`
       or `config :my_app, Samen.Observability, replay: [...]`) — otherwise no supervisor, no
       table, no handler: the recorder is a no-op;
    2. the org's `#{"samen.replay"}` flag is ON in the feature-flag engine (ADR-020;
       `Samen.FeatureFlags.evaluate/3`, an `org_id` allow rule or a rollout). An unknown flag
       is OFF (the engine fails safe).

  Tenant plane only: the operator plane never records (the recorder is attached only on
  `TenantAuthz`'s tenant legs, and refuses an operator-plane mount itself).

  ## The keep-list declaration API

  A LiveView (or LiveComponent) declares which of ITS assigns may keep a bare string, and which
  params of which events may keep a bounded value:

      use Samen.Replay,
        keep_assigns: [:tab],
        keep_params: %{"sort" => [{"field", ["name", "inserted_at"]}], "select" => ["id"]},
        keep_url_params: [{"tab", ["billing", "usage"]}]

  Declarations accumulate (a mixin such as `Samen.Web.ListLive` contributes its own) into one
  `__samen_replay__/0`. A declared value is still bounded: a kept assign string must be ≤ 120
  codepoints and not email/SSN/phone-shaped. A kept param value is an integer, a boolean or a
  UUID for a bare name (`"id"`), and additionally a member of the closed set for
  `{name, [allowed]}` — a client-chosen string is never kept (ADR-052 §2.2.1 gate fix).
  """

  @flag "samen.replay"
  @default_retention_days 14
  @max_retention_days 90
  @config_key {__MODULE__, :config}

  @defaults [
    sample_rate: 1.0,
    max_frames: 500,
    max_bytes: 512 * 1024,
    max_sessions: 1_000,
    retention_days: @default_retention_days,
    flag_opts: []
  ]

  @typedoc "Resolved capture configuration."
  @type config :: %{
          sample_rate: float(),
          max_frames: pos_integer(),
          max_bytes: pos_integer(),
          max_sessions: pos_integer(),
          retention_days: pos_integer(),
          flag_opts: keyword()
        }

  @doc "The feature flag that opts an org into capture."
  @spec flag_name() :: String.t()
  def flag_name, do: @flag

  @doc "The default retention window (days)."
  @spec default_retention_days() :: pos_integer()
  def default_retention_days, do: @default_retention_days

  @doc "The largest retention window a host may configure (days)."
  @spec max_retention_days() :: pos_integer()
  def max_retention_days, do: @max_retention_days

  # ---------------------------------------------------------------------------
  # Keep-list declarations

  defmacro __using__(opts) do
    decl = normalize_decl!(opts, __CALLER__)

    quote do
      unless Module.get_attribute(__MODULE__, :__samen_replay_registered__) do
        Module.register_attribute(__MODULE__, :samen_replay_keep, accumulate: true)
        Module.put_attribute(__MODULE__, :__samen_replay_registered__, true)
        @before_compile Samen.Replay
      end

      @samen_replay_keep unquote(Macro.escape(decl))
    end
  end

  defmacro __before_compile__(env) do
    decls = Module.get_attribute(env.module, :samen_replay_keep) || []
    merged = merge_decls(decls)

    quote do
      @doc false
      def __samen_replay__, do: unquote(Macro.escape(merged))
    end
  end

  @doc false
  def normalize_decl!(opts, caller) do
    assigns = Keyword.get(opts, :keep_assigns, [])
    params = Keyword.get(opts, :keep_params, %{})
    url = Keyword.get(opts, :keep_url_params, [])

    unless is_list(assigns) and Enum.all?(assigns, &is_atom/1) do
      raise CompileError,
        file: caller.file,
        line: caller.line,
        description: "use Samen.Replay: :keep_assigns must be a list of atoms"
    end

    params =
      case params do
        {:%{}, _, kv} -> Map.new(kv)
        m when is_map(m) -> m
        _ -> :invalid
      end

    unless is_map(params) and
             Enum.all?(params, fn {k, v} -> is_binary(k) and param_specs?(v) end) do
      raise CompileError,
        file: caller.file,
        line: caller.line,
        description:
          "use Samen.Replay: :keep_params must be a literal %{\"event\" => [\"param\" | " <>
            "{\"param\", [\"allowed\", ...]}, ...]} map"
    end

    unless param_specs?(url) do
      raise CompileError,
        file: caller.file,
        line: caller.line,
        description:
          "use Samen.Replay: :keep_url_params must be a list of \"param\" | " <>
            "{\"param\", [\"allowed\", ...]}"
    end

    %{assigns: assigns, params: params, url_params: url}
  end

  # A param spec list: bare names, or `{name, [allowed string]}` closed sets (literals).
  defp param_specs?(specs) when is_list(specs) do
    Enum.all?(specs, fn
      name when is_binary(name) -> true
      {name, allowed} when is_binary(name) and is_list(allowed) -> Enum.all?(allowed, &is_binary/1)
      _ -> false
    end)
  end

  defp param_specs?(_), do: false

  @doc false
  def merge_decls(decls) do
    # `accumulate: true` attributes read back newest-first; merge in declaration order.
    decls
    |> Enum.reverse()
    |> Enum.reduce(%{assigns: [], params: %{}, url_params: []}, fn d, acc ->
      %{
        assigns: Enum.uniq(acc.assigns ++ d.assigns),
        params: Map.merge(acc.params, d.params, fn _k, a, b -> Enum.uniq(a ++ b) end),
        url_params: Enum.uniq(acc.url_params ++ d.url_params)
      }
    end)
  end

  @doc """
  The keep declaration of a view/component module (empty when it declares none).
  """
  @spec keep(module()) :: %{assigns: [atom()], params: map(), url_params: [String.t()]}
  def keep(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__samen_replay__, 0),
      do: module.__samen_replay__(),
      else: %{assigns: [], params: %{}, url_params: []}
  rescue
    _ -> %{assigns: [], params: %{}, url_params: []}
  end

  def keep(_), do: %{assigns: [], params: %{}, url_params: []}

  @doc """
  The bounded label recorded for a client-sent `event` on `module`: the view's own
  `handle_event/3` literal (`Samen.Observability.LiveEvents`), else a key the view DECLARED in
  `keep_params` (a developer literal), else `"other"`. The client string is only ever a lookup
  key — never recorded, never interned.
  """
  @spec event_label(module(), term(), map() | nil) :: String.t()
  def event_label(module, event, keep \\ nil) do
    case Samen.Observability.LiveEvents.resolve(module, event) do
      :other ->
        params = (keep || keep(module)).params

        case is_binary(event) and Map.has_key?(params, event) and
               Samen.Replay.Sanitizer.label?(event) do
          true -> declared_literal(params, event)
          false -> "other"
        end

      atom ->
        Atom.to_string(atom)
    end
  end

  # Return the DECLARED key (the developer's literal from the module), not the client's binary.
  defp declared_literal(params, event) do
    Enum.find_value(params, "other", fn {k, _} -> if k == event, do: k end)
  end

  # ---------------------------------------------------------------------------
  # Configuration + runtime state

  @doc """
  Resolve + validate a capture configuration. Raises `ArgumentError` (fail-honest, at boot) on
  a retention window above `max_retention_days/0` or below 1, a sample rate outside 0..1, or a
  non-positive cap.
  """
  @spec config!(keyword()) :: config()
  def config!(opts) when is_list(opts) do
    cfg = Keyword.merge(@defaults, opts)
    days = cfg[:retention_days]

    unless is_integer(days) and days >= 1 and days <= @max_retention_days do
      raise ArgumentError,
            "Samen.Replay: retention_days #{inspect(days)} is outside 1..#{@max_retention_days}. " <>
              "Replays are bounded by design (ADR-052 §2.2): refusing to start capture with an " <>
              "unbounded or over-long retention window."
    end

    rate = cfg[:sample_rate]

    unless is_number(rate) and rate >= 0 and rate <= 1 do
      raise ArgumentError, "Samen.Replay: sample_rate #{inspect(rate)} must be in 0.0..1.0"
    end

    for key <- [:max_frames, :max_bytes, :max_sessions] do
      unless is_integer(cfg[key]) and cfg[key] > 0 do
        raise ArgumentError,
              "Samen.Replay: #{key} must be a positive integer, got #{inspect(cfg[key])}"
      end
    end

    %{
      sample_rate: rate / 1,
      max_frames: cfg[:max_frames],
      max_bytes: cfg[:max_bytes],
      max_sessions: cfg[:max_sessions],
      retention_days: days,
      flag_opts: List.wrap(cfg[:flag_opts])
    }
  end

  @doc false
  @spec put_runtime_config(config()) :: :ok
  def put_runtime_config(cfg), do: :persistent_term.put(@config_key, cfg)

  @doc false
  @spec erase_runtime_config() :: :ok
  def erase_runtime_config do
    _ = :persistent_term.erase(@config_key)
    :ok
  end

  @doc "The running capture configuration, or `nil` when capture is not running on this node."
  @spec runtime_config() :: config() | nil
  def runtime_config, do: :persistent_term.get(@config_key, nil)

  @doc "Is the capture plane running on this node (supervisor up, buffer table present)?"
  @spec running?() :: boolean()
  def running? do
    runtime_config() != nil and Samen.Replay.Buffer.table_exists?()
  end

  @doc """
  Decide whether a session of `org_id` is captured: the org's flag must be ON
  (`Samen.FeatureFlags.evaluate/3`, assignment emit suppressed — rendering a page is not an
  experiment exposure) and the session must fall in the sample. Returns `:on` or `:off`.
  """
  @spec decide(String.t() | nil, config() | nil) :: :on | :off
  def decide(org_id, cfg \\ runtime_config())

  def decide(org_id, %{} = cfg) when is_binary(org_id) do
    if flag_on?(org_id, cfg) and sampled?(cfg.sample_rate), do: :on, else: :off
  end

  def decide(_org_id, _cfg), do: :off

  @doc false
  @spec flag_on?(String.t(), config()) :: boolean()
  def flag_on?(org_id, cfg) do
    opts = Keyword.put(cfg.flag_opts, :emit, false)
    Samen.FeatureFlags.evaluate(@flag, %{org_id: org_id}, opts).on === true
  rescue
    _ -> false
  end

  @doc false
  @spec sampled?(float(), float()) :: boolean()
  def sampled?(rate, draw \\ :rand.uniform())
  def sampled?(rate, _draw) when rate >= 1.0, do: true
  def sampled?(rate, _draw) when rate <= 0.0, do: false
  def sampled?(rate, draw), do: draw <= rate

  # ---------------------------------------------------------------------------
  # Retention (ADR-052 §2.2 rule 4, R12)

  @doc """
  The `Samen.Retention` specs for replay storage: sessions and frames older than
  `retention_days` (default #{@default_retention_days}, max #{@max_retention_days}) are deleted.
  Raises on an out-of-range window (see `config!/1`).
  """
  @spec retention_specs(keyword()) :: [Samen.Retention.Spec.t()]
  def retention_specs(opts \\ []) do
    %{retention_days: days} = config!(opts)
    ttl = days * 86_400

    for resource <- [Samen.Replay.Session, Samen.Replay.Frame] do
      %Samen.Retention.Spec{
        resource: resource,
        ttl_seconds: ttl,
        action: :delete,
        timestamp_field: :inserted_at
      }
    end
  end

  @doc """
  Merge the replay retention specs into `:samen_core, :retention_specs` (the registry the daily
  `Samen.Retention.SweepWorker` sweeps). A host entry for the same resource wins only when its
  window is within the bound; an over-long host entry RAISES (fail-honest). Idempotent.
  """
  @spec install_retention_specs(keyword()) :: [Samen.Retention.Spec.t()]
  def install_retention_specs(opts \\ []) do
    specs = retention_specs(opts)
    existing = Application.get_env(:samen_core, :retention_specs, [])
    ours = MapSet.new(specs, & &1.resource)

    host =
      Enum.filter(existing, fn spec ->
        normalized = Samen.Retention.Spec.normalize(spec)

        if MapSet.member?(ours, normalized.resource) do
          ttl = normalized.ttl_seconds

          unless is_integer(ttl) and ttl > 0 and ttl <= @max_retention_days * 86_400 do
            raise ArgumentError,
                  "Samen.Replay: the host's :retention_specs entry for " <>
                    "#{inspect(normalized.resource)} has ttl_seconds #{inspect(ttl)}, outside " <>
                    "1..#{@max_retention_days * 86_400}. Replays are bounded by design."
          end

          true
        else
          false
        end
      end)

    host_covered = MapSet.new(host, &Samen.Retention.Spec.normalize(&1).resource)
    added = Enum.reject(specs, &MapSet.member?(host_covered, &1.resource))

    Application.put_env(:samen_core, :retention_specs, existing ++ added)
    specs
  end
end
