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

  ## `config/runtime.exs` (ADR-052 §2.1.2 item 3)

  A release evaluates `config/runtime.exs` at BOOT, after the compiled config — so a
  `config :logger, level: String.to_atom(System.get_env("LOG_LEVEL"))` there undoes check (2)
  with an env var nobody reviews. Evaluating runtime.exs here would need the deploy's secrets
  (it raises on a missing `DATABASE_URL` by design) and would still only prove the env vars the
  check happened to pick, so the file is checked STATICALLY, fail closed. Every level it can
  set — `config :logger, …` (any `level:` under it, handler sub-keys included),
  `Logger.configure/1`, `Logger.put_*_level/2`, and `:logger.set_*` / `:logger.update_*` — must
  be a LITERAL at or above `:info`, or `Samen.Observability.prod_log_level/1` (which clamps an
  env-var level to `:info` or above). A non-literal level, a `config :logger` whose options are
  not a literal keyword list, or a runtime.exs that does not parse is a violation. A host with
  no runtime.exs has nothing to check.

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
    ) ++ runtime_findings(read_runtime_config())
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

  @doc """
  The `config/runtime.exs` decision (ADR-052 §2.1.2 item 3) over its source: `:absent` (no
  file — nothing to check), `{:ok, source}`, or `{:error, reason}` (unreadable — fail closed).
  """
  @spec runtime_findings(:absent | {:ok, String.t()} | {:error, term()}) :: [Finding.t()]
  def runtime_findings(:absent), do: []

  def runtime_findings({:error, reason}) do
    [runtime_violation("could not read config/runtime.exs (#{inspect(reason)})")]
  end

  def runtime_findings({:ok, source}) when is_binary(source) do
    case Code.string_to_quoted(source) do
      {:ok, ast} ->
        ast
        |> runtime_level_problems()
        |> Enum.map(&runtime_violation/1)

      {:error, _} ->
        [runtime_violation("config/runtime.exs does not parse — its Logger level is unproven")]
    end
  end

  defp runtime_violation(problem) do
    Finding.violation(
      @tier,
      "logger level (runtime.exs)",
      problem <>
        ". A release applies runtime.exs at boot, after config/prod.exs, so a level set there " <>
        "must provably stay at :info or above: use a literal (`level: :info`) or clamp an env " <>
        "var with `Samen.Observability.prod_log_level(System.get_env(\"LOG_LEVEL\"))`."
    )
  end

  # Every Logger-level write in the runtime.exs AST, judged; returns the problem strings.
  defp runtime_level_problems(ast) do
    {_, problems} = Macro.prewalk(ast, [], &collect_level_writes/2)
    Enum.reverse(problems)
  end

  # `config :logger, …` — config/2 and config/3: every option list must be a literal keyword
  # list, and any `level:` in it (at any depth) a provable level.
  defp collect_level_writes({:config, _, [:logger | rest]} = node, acc) do
    problems =
      Enum.flat_map(rest, fn
        sub_key when is_atom(sub_key) ->
          []

        opts ->
          if literal_keyword?(opts),
            do: keyword_level_problems(opts, "config :logger"),
            else: ["`config :logger` takes a non-literal option list #{Macro.to_string(opts)}"]
      end)

    {node, Enum.reverse(problems, acc)}
  end

  # Logger.configure(kw) / Logger.configure_backend(_, kw)
  defp collect_level_writes(
         {{:., _, [{:__aliases__, _, [:Logger]}, fun]}, _, args} = node,
         acc
       )
       when fun in [:configure, :configure_backend] do
    opts = List.last(args)

    problems =
      if literal_keyword?(opts),
        do: keyword_level_problems(opts, "Logger.#{fun}"),
        else: ["`Logger.#{fun}` takes a non-literal option list #{Macro.to_string(opts)}"]

    {node, Enum.reverse(problems, acc)}
  end

  # Logger.put_module_level(m, level) / put_application_level / put_process_level
  defp collect_level_writes(
         {{:., _, [{:__aliases__, _, [:Logger]}, fun]}, _, [_target, level]} = node,
         acc
       )
       when fun in [:put_module_level, :put_application_level, :put_process_level] do
    {node, Enum.reverse(level_problems(level, "Logger.#{fun}"), acc)}
  end

  # :logger.set_* / :logger.update_* — the Erlang API underneath (primary, handler, module,
  # application levels).
  defp collect_level_writes({{:., _, [:logger, fun]}, _, args} = node, acc)
       when is_atom(fun) and is_list(args) do
    name = Atom.to_string(fun)

    if String.starts_with?(name, ["set_", "update_"]) do
      {node, Enum.reverse(erlang_logger_problems(name, args), acc)}
    else
      {node, acc}
    end
  end

  defp collect_level_writes(node, acc), do: {node, acc}

  defp erlang_logger_problems(name, args) do
    cond do
      # set_primary_config(:level, L) / set_handler_config(id, :level, L)
      (i = Enum.find_index(args, &(&1 == :level))) != nil ->
        level_problems(Enum.at(args, i + 1), ":logger.#{name}")

      # set_module_level(m, L) / set_application_level(app, L)
      String.ends_with?(name, "_level") ->
        level_problems(List.last(args), ":logger.#{name}")

      # set_primary_config(%{level: L}) / update_handler_config(id, %{…})
      true ->
        Enum.flat_map(args, fn
          {:%{}, _, pairs} = map ->
            if literal_keyword?(pairs),
              do: keyword_level_problems(pairs, ":logger.#{name}"),
              else: [":logger.#{name} takes a non-literal map #{Macro.to_string(map)}"]

          arg when is_atom(arg) or is_binary(arg) or is_number(arg) ->
            []

          {:__aliases__, _, _} ->
            []

          other ->
            [":logger.#{name} takes a non-literal argument #{Macro.to_string(other)}"]
        end)
    end
  end

  defp literal_keyword?(list) when is_list(list),
    do: Enum.all?(list, &match?({key, _} when is_atom(key), &1))

  defp literal_keyword?(_), do: false

  # Any `level:` at any depth of a literal keyword list (handler sub-configs nest).
  defp keyword_level_problems(opts, where) do
    Enum.flat_map(opts, fn
      {:level, level} -> level_problems(level, where)
      {_key, nested} when is_list(nested) -> keyword_level_problems_nested(nested, where)
      {_key, {:%{}, _, pairs}} -> keyword_level_problems_nested(pairs, where)
      _ -> []
    end)
  end

  defp keyword_level_problems_nested(value, where) do
    if literal_keyword?(value), do: keyword_level_problems(value, where), else: []
  end

  defp level_problems(level, where) when is_atom(level) do
    if level in @ok_levels,
      do: [],
      else: ["#{where} sets the Logger level to #{inspect(level)} — below :info"]
  end

  # The sanctioned clamp: whatever the env var says, the result is :info or above.
  defp level_problems(
         {{:., _, [{:__aliases__, _, [:Samen, :Observability]}, :prod_log_level]}, _, [_]},
         _where
       ),
       do: []

  defp level_problems(level, where) do
    [
      "#{where} sets the Logger level from a non-literal expression " <>
        "#{Macro.to_string(level)} — it cannot be proven to stay at :info or above (fail closed)"
    ]
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

  # Mix's own location for it: next to the project's config.exs.
  defp read_runtime_config do
    path =
      (Mix.Project.config()[:config_path] || "config/config.exs")
      |> Path.dirname()
      |> Path.join("runtime.exs")

    if File.exists?(path), do: File.read(path), else: :absent
  end

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
