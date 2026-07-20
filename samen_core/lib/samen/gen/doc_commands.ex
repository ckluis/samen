defmodule Samen.Gen.DocCommands do
  @moduledoc """
  WS-D D9 — the DOC-COMMAND EXTRACTOR (AC-G10-1 / AC-G10-2; design.md §1.3 "Docs
  verified against reality").

  The repo's ethos is claim-evidence parity: no aspirational docs. The root `README.md`
  and `docs/guides/getting-started.md` are *tutorials of commands*, so their claims ARE
  their commands — and every fenced command must be backed by something that actually
  runs in CI. This module is the pure engine behind `test/doc_commands_test.exs`:

    1. `extract/2` parses a markdown doc and pulls every command out of `bash`/`sh`/
       `shell`/`console` fenced blocks (splitting `&&` chains, stripping `$ ` prompts,
       env-var prefixes and comments).
    2. `rules/0` is the COVERAGE TABLE: each documented command shape maps to evidence
       substrings that must be present in the sources that execute it — the flagship
       probe (`priv/gen_app_flagship_probe.exs`), the post-app generator probe
       (`priv/gen_post_probe.exs`), the `mix samen.gen.app` task (which drives the
       byte-identical `build_spec → validate! → reserve_abbrevs! → write_app! →
       compile_and_dump!` pipeline the probes execute), the generator engine
       (`lib/samen/gen/app.ex`) and the emitted templates (`lib/samen/gen/templates.ex`).
    3. `verify/2` fails CLOSED in both directions:
       * a doc command with NO matching rule is an ASPIRATIONAL command → failure
         (the red path: adding `mix samen.deploy.magic` to the tutorial fails CI);
       * a rule whose evidence substring is GONE from its source is DOC DRIFT → failure
         (the probes stopped executing what the doc claims → the doc test flips).

  A command may instead carry an explicit `# operator-TODO` marker (or live in a
  ```` ```bash operator-todo ```` block) — the design's escape hatch for steps that are
  deliberately human (real accounts/credentials, ADR-024). Marked commands are allowed
  without probe evidence, because they explicitly claim NOT to be automated.

  The module is pure (no file IO): the test supplies the doc + source contents, so the
  fail-closed rules are unit-testable, including the red paths.
  """

  @typedoc "One command extracted from a fenced block."
  @type command :: %{
          doc: String.t(),
          line: pos_integer(),
          raw: String.t(),
          env: [String.t()],
          argv: [String.t()],
          operator_todo?: boolean()
        }

  @type rule :: %{
          id: atom(),
          match: (argv :: [String.t()] -> boolean()),
          evidence: [{source_key :: atom(), substring :: String.t()}]
        }

  @fence_langs ~w(bash sh shell console)

  # ------------------------------------------------------------------ extraction

  @doc """
  Extracts every command from the `bash`/`sh`/`shell`/`console` fenced blocks of a
  markdown document. Prompt prefixes (`$ `), comment lines, blank lines and leading
  `VAR=value` env assignments are stripped; `a && b` chains split into two commands.
  A trailing `# operator-TODO …` comment (or an `operator-todo` word on the fence
  info string) marks the command as explicitly human.
  """
  @spec extract(String.t(), String.t()) :: [command()]
  def extract(doc_name, markdown) when is_binary(doc_name) and is_binary(markdown) do
    markdown
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce({:out, false, []}, fn {line, n}, {state, block_todo?, acc} ->
      trimmed = String.trim(line)

      case {state, trimmed} do
        {:out, "```" <> info} ->
          case String.split(String.trim(info)) do
            [lang | rest] when lang in @fence_langs ->
              {:in, "operator-todo" in rest, acc}

            _ ->
              # A non-command fence (elixir/diff/text/…) — skip to its closing fence.
              {:skip, false, acc}
          end

        {:skip, "```"} ->
          {:out, false, acc}

        {:skip, _} ->
          {:skip, false, acc}

        {:in, "```"} ->
          {:out, false, acc}

        {:in, _} ->
          {:in, block_todo?, parse_line(doc_name, n, trimmed, block_todo?) ++ acc}

        {:out, _} ->
          {:out, false, acc}
      end
    end)
    |> then(fn {_state, _todo?, acc} -> Enum.reverse(acc) end)
  end

  defp parse_line(_doc, _n, "", _todo?), do: []
  defp parse_line(_doc, _n, "#" <> _, _todo?), do: []

  defp parse_line(doc, n, line, block_todo?) do
    line = String.replace_prefix(line, "$ ", "")

    {line, inline_todo?} =
      case String.split(line, "#", parts: 2) do
        [cmd] -> {String.trim(cmd), false}
        [cmd, comment] -> {String.trim(cmd), String.contains?(comment, "operator-TODO")}
      end

    line
    |> String.split("&&")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn part ->
      {env, argv} =
        part
        |> String.split(~r/\s+/)
        |> Enum.split_while(&Regex.match?(~r/\A[A-Z][A-Z0-9_]*=\S*\z/, &1))

      %{
        doc: doc,
        line: n,
        raw: part,
        env: env,
        argv: argv,
        operator_todo?: block_todo? or inline_todo?
      }
    end)
  end

  # ------------------------------------------------------------------ coverage rules

  @doc """
  The coverage table: every command shape the docs are ALLOWED to claim, each bound to
  the evidence substrings that must exist in the sources that execute it. A doc command
  matching no rule — or a rule whose evidence has vanished — fails `verify/2`.
  """
  @spec rules() :: [rule()]
  def rules do
    ci_sh_evidence = [
      {:flagship_probe, ~s|System.cmd("bash", ["ci.sh"]|},
      {:post_probe, ~s|System.cmd("bash", ["ci.sh"]|}
    ]

    # The task↔probe pipeline equivalence: `mix samen.gen.app` and the flagship probe
    # drive the SAME four engine calls; asserting both sides keeps "the probe executed
    # the tutorial's generate command" honest rather than asserted.
    gen_pipeline = [
      "Gen.build_spec(",
      "Gen.reserve_abbrevs!(spec)",
      "Gen.write_app!(spec)",
      "Gen.compile_and_dump!(spec)"
    ]

    [
      %{
        id: :cd,
        # Navigation claims nothing executes — allowed with a single target argument.
        match: fn argv -> match?(["cd", _], argv) end,
        evidence: []
      },
      %{
        id: :gen_app,
        # The flagship shape ONLY: defaults-on full product, the three required flags.
        # Any other flag (e.g. an aspirational `--deploy`) fails to match → red path.
        match: fn argv -> task_with_flags?(argv, "samen.gen.app", ~w(--module --prefix --abbrev)) end,
        evidence:
          Enum.map(gen_pipeline, &{:flagship_probe, &1}) ++
            Enum.map(gen_pipeline, &{:gen_app_task, &1}) ++
            [{:flagship_probe, "web: true"}, {:flagship_probe, "api: true"}]
      },
      %{
        id: :gen_scope,
        match: fn argv -> task_with_flags?(argv, "samen.gen.scope", ~w(--scope)) end,
        evidence: [{:post_probe, ~s|"samen.gen.scope"|}]
      },
      %{
        id: :gen_resource,
        match: fn argv ->
          task_with_flags?(argv, "samen.gen.resource", ~w(--scope --resource --abbrev))
        end,
        evidence: [{:post_probe, ~s|"samen.gen.resource"|}]
      },
      %{
        # WS-D D7a `--live`: the resource generator ALSO scaffolds index/show/form
        # LiveViews. The post-app probe executes exactly this shape (the trailing
        # boolean `--live` carries no value, so the flag-pair matcher above cannot
        # cover it — this dedicated rule pins the shape the probe runs).
        id: :gen_resource_live,
        match: fn argv ->
          match?(
            ["mix", "samen.gen.resource", "--scope", _, "--resource", _, "--abbrev", _, "--live"],
            argv
          )
        end,
        evidence: [{:post_probe, ~s|"--live"|}]
      },
      %{
        id: :ci_sh,
        match: fn argv -> argv == ["bash", "ci.sh"] end,
        evidence: ci_sh_evidence
      },
      %{
        id: :deps_get,
        match: fn argv -> argv == ["mix", "deps.get"] end,
        evidence: [
          {:gen_engine, ~s|run_mix!(s, ["deps.get"])|},
          {:flagship_probe, "Gen.compile_and_dump!(spec)"}
        ]
      },
      %{
        id: :ecto_create,
        # Executed (as storage_up) by the emitted ci_bootstrap the probes' ci.sh runs.
        match: fn argv -> argv == ["mix", "ecto.create"] end,
        evidence: [{:templates, "Ecto.Adapters.Postgres.storage_up"} | ci_sh_evidence]
      },
      %{
        id: :ecto_migrate,
        match: fn argv -> argv == ["mix", "ecto.migrate"] end,
        evidence: [{:templates, "Ecto.Migrator.run(Repo, :up, all: true)"} | ci_sh_evidence]
      },
      %{
        id: :app_seed,
        # `mix <app>.seed` — the emitted task wraps exactly `<App>.Seeds.run()`, and the
        # flagship probe executes that exact call (then raw-scans the rows for vt_*).
        match: fn argv ->
          match?(["mix", task] when is_binary(task), argv) and
            Regex.match?(~r/\A[a-z][a-z0-9_]*\.seed\z/, Enum.at(argv, 1))
        end,
        evidence: [
          {:flagship_probe, ".Seeds.run()"},
          {:templates, "org_id = <%= module %>.Seeds.run()"}
        ]
      },
      %{
        id: :phx_server,
        # The serving claim: the flagship probe boots the generated endpoint with
        # `server: true` and asserts /healthz (+ every mounted route) over real HTTP;
        # the emitted dev config sets `server: true` so `mix phx.server` serves the same.
        match: fn argv -> argv == ["mix", "phx.server"] end,
        evidence: [
          {:flagship_probe, "server: true"},
          {:flagship_probe, ~s|check.("/healthz", "ok")|},
          {:templates, "Web.Endpoint, server: true"}
        ]
      },
      %{
        id: :compile,
        match: fn argv -> argv == ["mix", "compile", "--warnings-as-errors"] end,
        evidence: [{:post_probe, ~s|["compile", "--warnings-as-errors"]|}]
      },
      %{
        id: :catalog_dump,
        match: fn argv ->
          argv == ["mix", "samen.catalog.dump", "--output", "schema.dict.json"]
        end,
        evidence: [{:post_probe, ~s|["samen.catalog.dump", "--output", "schema.dict.json"]|}]
      },
      %{
        id: :api_contract_update,
        match: fn argv ->
          argv == ["mix", "samen.verify.api_contract", "--version", "v1", "--update"]
        end,
        evidence: [
          {:gen_engine, ~s|run_mix!(s, ["samen.verify.api_contract", "--version", "v1", "--update"])|},
          {:flagship_probe, "Gen.compile_and_dump!(spec)"}
        ]
      },
      %{
        id: :mix_test,
        match: fn argv ->
          match?(["mix", "test" | rest] when is_list(rest), argv) and
            argv |> Enum.drop(2) |> Enum.all?(&(not String.starts_with?(&1, "--")))
        end,
        evidence: [{:post_probe, ~s|mix.(app_dir, ["test"|}]
      },
      %{
        # The T2.9 destruction oracle in post-shred mode (cookbook Recipe 8 — crypto-shred):
        # `--tiers all` is the ONLY value the task accepts (the shape is pinned in the task's
        # own moduledoc/flag-parsing, not asserted by a CI probe — no probe has a real
        # erased subject to run this against). Evidence proves the flag contract is real,
        # not invented; a doc drifting to a different flag shape (e.g. a partial `--tiers`
        # value) fails to match and falls to the aspirational red path.
        id: :verify_no_plaintext_pii_post_shred,
        match: fn argv ->
          match?(
            ["mix", "samen.verify.no_plaintext_pii", "--subject", _, "--tiers", "all"],
            argv
          )
        end,
        evidence: [
          {:no_plaintext_pii_task, "post-shred mode requires `--tiers all` (got "}
        ]
      }
    ]
  end

  # `mix <task> --flag value …` with EXACTLY the given flag set, each flag carrying one
  # non-flag value, no positional arguments. Unknown/extra flags do not match (fail
  # closed: an aspirational flag is an aspirational command).
  defp task_with_flags?(["mix", task | rest], task, required_flags) do
    case parse_flag_pairs(rest, %{}) do
      {:ok, flags} -> Enum.sort(Map.keys(flags)) == Enum.sort(required_flags)
      :error -> false
    end
  end

  defp task_with_flags?(_argv, _task, _flags), do: false

  defp parse_flag_pairs([], acc), do: {:ok, acc}

  defp parse_flag_pairs(["--" <> _ = flag, value | rest], acc) do
    if String.starts_with?(value, "--") or Map.has_key?(acc, flag) do
      :error
    else
      parse_flag_pairs(rest, Map.put(acc, flag, value))
    end
  end

  defp parse_flag_pairs(_other, _acc), do: :error

  # ------------------------------------------------------------------ verification

  @doc """
  Verifies docs against the executing sources. `docs` is `[{doc_name, markdown}]`;
  `sources` is a map of source-key → source contents (see `rules/0` for the keys).
  Returns `:ok` or `{:error, [failure_message]}` — one message per aspirational
  command, unknown source key, or drifted evidence.
  """
  @spec verify([{String.t(), String.t()}], %{optional(atom()) => String.t()}) ::
          :ok | {:error, [String.t()]}
  def verify(docs, sources) when is_list(docs) and is_map(sources) do
    failures =
      docs
      |> Enum.flat_map(fn {name, markdown} -> extract(name, markdown) end)
      |> Enum.flat_map(&check_command(&1, sources))

    if failures == [], do: :ok, else: {:error, failures}
  end

  defp check_command(%{operator_todo?: true}, _sources), do: []

  defp check_command(cmd, sources) do
    case Enum.find(rules(), fn rule -> rule.match.(cmd.argv) end) do
      nil ->
        [
          "#{cmd.doc}:#{cmd.line}: `#{cmd.raw}` is NOT in the probes' executed set — " <>
            "an aspirational command. Either make a probe/CI step execute it (and add " <>
            "a coverage rule with evidence), or mark it `# operator-TODO`."
        ]

      rule ->
        Enum.flat_map(rule.evidence, fn {source_key, substring} ->
          case Map.fetch(sources, source_key) do
            :error ->
              [
                "#{cmd.doc}:#{cmd.line}: `#{cmd.raw}` (rule #{inspect(rule.id)}) needs " <>
                  "source #{inspect(source_key)}, which was not supplied."
              ]

            {:ok, source} ->
              if String.contains?(source, substring) do
                []
              else
                [
                  "#{cmd.doc}:#{cmd.line}: `#{cmd.raw}` (rule #{inspect(rule.id)}) claims " <>
                    "probe coverage, but the evidence #{inspect(substring)} is GONE from " <>
                    "#{inspect(source_key)} — the doc has drifted from what CI executes."
                ]
              end
          end
        end)
    end
  end
end
