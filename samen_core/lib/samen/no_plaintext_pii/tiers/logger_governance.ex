defmodule Samen.NoPlaintextPii.Tiers.LoggerGovernance do
  @moduledoc """
  CI-mode tier **`:logger`** (ADR-052 §2.1 item 3, red path R4): the application LOG is a
  projected surface too, and it is governed.

  Phoenix logs request params (`Phoenix.Logger`) and every LiveView `handle_event`'s params
  (`Phoenix.LiveView.Logger`, at `:debug`) through ONE filter, `config :phoenix,
  :filter_parameters`. Phoenix's default filters only `"password"` — so an unconfigured host
  logs every form value a user types, before any of it reaches the vault. This tier asserts:

    1. **`filter_parameters` is a keep-list** — `{:keep, [key, …]}`: default-DENY, every
       param value not on the list prints as `[FILTERED]`. A deny-list (the Phoenix default
       shape, `["password", …]`) fails: it is default-ALLOW, and the next PII key nobody
       listed leaks. A kept key that is PII-named (`Samen.PiiClassify.pii_name?/1`) or
       secret-named (`password`/`secret`/`token`) fails too. Checked in the host's PROD config
       AND in the running app env. Only asserted when Phoenix is a dependency (the surface
       does not exist otherwise).
    2. **The prod Logger level is `:info` or above** — so `:debug` call sites (including
       LiveView's `handle_event` log line, which prints the client-sent event name) never
       reach the production log. A missing level counts as below `:info` (Logger's default
       logs everything).

  The prod config is read with `Config.Reader` from the host's `config/config.exs` evaluated
  for `env: :prod` (its `import_config "\#{config_env()}.exs"` pulls in `prod.exs`). A host
  whose prod config cannot be read FAILS (fail closed — "I couldn't check" is a violation).

  LiveView `log:` — with (1) and (2) both enforced, LiveView's `:debug` event logging is
  dropped in prod and its params are keep-list filtered in every env, so the framework does
  not additionally set `log:` per LiveView (ADR-052 as-built note).
  """

  @behaviour Samen.NoPlaintextPii.Tier

  alias Samen.NoPlaintextPii.{Context, Finding}

  @tier :logger

  # Levels at or above :info. Anything else (:debug, :all, nil/unset) is below the floor.
  @ok_levels [:info, :notice, :warning, :warn, :error, :critical, :alert, :emergency, :none]
  @secret_tokens ~w(password passwd secret token)
  @phoenix_deps [:phoenix, :phoenix_live_view]

  @impl true
  def tier_name, do: @tier

  @impl true
  def mode, do: :ci

  @impl true
  def describe,
    do:
      "logger governance — :phoenix filter_parameters is a {:keep, [...]} keep-list (no PII/secret " <>
        "keys) and the prod Logger level is :info or above"

  @impl true
  def check(%Context{} = context) do
    phoenix? = Enum.any?(@phoenix_deps, &Context.dep_present?(context, &1))

    check_config(
      read_prod_config(),
      Application.get_env(:phoenix, :filter_parameters),
      phoenix?
    )
  end

  @doc """
  The tier's decision over explicit inputs (exposed so the red paths drive it directly):

    * `prod_config` — the host's prod config (`{:ok, keyword}`), or `{:error, reason}` when it
      could not be read;
    * `live_filter` — the running app env's `:phoenix, :filter_parameters`;
    * `phoenix?` — whether Phoenix (the filter's consumer) is a dependency.
  """
  @spec check_config({:ok, keyword()} | {:error, term()}, term(), boolean()) :: [Finding.t()]
  def check_config({:error, reason}, _live_filter, _phoenix?) do
    [
      Finding.violation(
        @tier,
        "prod config",
        "could not read the host's prod config (#{inspect(reason)}) — the prod Logger level and " <>
          "filter_parameters cannot be proven. Fail closed: make `config/config.exs` load for " <>
          "env :prod (it must be able to import a `config/prod.exs`)."
      )
    ]
  end

  def check_config({:ok, prod}, live_filter, phoenix?) do
    level_findings(prod) ++ filter_findings(prod, live_filter, phoenix?)
  end

  # ---------------------------------------------------------------------------

  defp level_findings(prod) do
    level = get_in(prod, [:logger, :level])

    if level in @ok_levels do
      []
    else
      [
        Finding.violation(
          @tier,
          "logger level (prod config)",
          "the prod Logger level is #{inspect(level)} — below :info (an unset level logs " <>
            "everything). :debug call sites (incl. LiveView's handle_event log line) would " <>
            "reach the prod log. Set `config :logger, level: :info` in config/prod.exs."
        )
      ]
    end
  end

  defp filter_findings(_prod, _live_filter, false), do: []

  defp filter_findings(prod, live_filter, true) do
    keep_list_findings(
      "filter_parameters (prod config)",
      get_in(prod, [:phoenix, :filter_parameters])
    ) ++
      keep_list_findings("filter_parameters (running app env)", live_filter)
  end

  defp keep_list_findings(subject, {:keep, keys}) when is_list(keys) do
    case Enum.reject(keys, &bounded_key?/1) do
      [] ->
        []

      bad ->
        [
          Finding.violation(
            @tier,
            subject,
            "the filter_parameters keep-list keeps #{inspect(bad)} — a PII-named, secret-named " <>
              "or non-string key. Keep only bounded ids / paging / sort keys."
          )
        ]
    end
  end

  defp keep_list_findings(subject, other) do
    [
      Finding.violation(
        @tier,
        subject,
        "`config :phoenix, :filter_parameters` is #{inspect(other)}, not a {:keep, [...]} " <>
          "keep-list. A deny-list (Phoenix's default is [\"password\"]) is default-ALLOW: every " <>
          "param nobody listed — an email, a name — is logged in the clear. Use the framework " <>
          "keep-list (docs/observability-guide.md §5)."
      )
    ]
  end

  defp bounded_key?(key) when is_binary(key) do
    not Samen.PiiClassify.pii_name?(key) and
      not String.contains?(String.downcase(key), @secret_tokens)
  end

  defp bounded_key?(_), do: false

  defp read_prod_config do
    path = Mix.Project.config()[:config_path] || "config/config.exs"

    if File.exists?(path) do
      {:ok, Config.Reader.read!(path, env: :prod, target: Mix.target())}
    else
      {:error, {:no_config, path}}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end
end
