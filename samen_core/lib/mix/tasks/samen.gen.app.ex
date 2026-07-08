defmodule Mix.Tasks.Samen.Gen.App do
  @shortdoc "Scaffold a new Samen vertical app (correct-by-construction, gate-green on first run)."

  @moduledoc """
  `mix samen.gen.app` — the T6.4 GENERATOR. Scaffolds a new Samen vertical app shaped
  exactly like `demo` / `driftwood` / `pawchart`: a sibling Mix project that depends on
  `samen_core` (`path: "../samen_core"`), mounts one universal scope AS-IS, authors one
  vertical resource with a `pii do` scalar-vault field, defines one token-blind aggregate
  projection, ships all substrate migrations + a catalog-in-transaction resource migration
  (`Samen.Migration`), and wires its own `ci.sh` to the FULL samen_core verifier gate.

  The generated app is **correct-by-construction**: after generation it PASSES its own
  `ci.sh` immediately, with no hand-editing. That is the load-bearing claim of this task —
  the generator's output is the gate's own reference for "shaped right."

  ## Usage

      mix samen.gen.app --module Widgetco --prefix wg --abbrev wid \\
        --target /path/to/parent_of_samen_core

  Options:

    * `--module`  (required) — the app's base module, e.g. `Widgetco`. The otp_app is the
      Macro.underscore of this (`:widgetco`).
    * `--prefix`  (required) — a **2-letter lowercase** app prefix used to derive the eight
      permanent Billing-scope abbrevs (`<p>c/<p>s/<p>l/<p>p/<p>i/<p>y/<p>u/<p>e`) and the
      aggregate-plane abbrev (`<p>a`). Must not collide with abbrevs already reserved in the
      registry (checked; fails closed on collision).
    * `--abbrev`  (required) — the **3-letter lowercase** abbrev for the authored vertical
      resource (e.g. `wid`). Reserved permanently in the registry.
    * `--target`  (optional) — the PARENT directory the new app dir is created under. Defaults
      to the parent of `samen_core` (i.e. the monorepo root) so `../samen_core` resolves.
    * `--no-reserve-abbrevs` — do NOT append the reserved abbrevs to
      `samen_core/priv/abbrev_registry.json`. Produces an app whose resource abbrev is
      UNRESERVED — used by the red-path test to prove the compile-time gate catches a
      missing abbrev. (Default: reserve.)

  ## What it produces

      <app>/
        mix.exs                 # samen_core path dep + jason/stream_data/simple_sat
        config/{config,dev,test}.exs
        lib/<app>/{application,repo,billing,<resource_domain>,aggregate}.ex
        priv/repo/migrations/…  # the substrate tables + a catalog-in-tx resource migration
        priv/ci_bootstrap.exs
        priv/anti_tautology_probe.exs
        test/{test_helper,<resource>_vault_test}.exs + test/support/data_case.ex
        schema.dict.json        # committed drift baseline (dumped from the compiled app)
        ci.sh                   # the full verifier gate, wired to the app

  The abbrev registry (`samen_core/priv/abbrev_registry.json`) is a GLOBAL, permanent file
  (`Samen.AbbrevRegistry`). Reserving abbrevs appends rows to it (append-only, idempotent) —
  this is the deliberate global-registry coupling the T6.1 extraction retro documents.

  ## Correct-by-construction post-steps

  When `--compile` is set (the default), after writing files the generator:

    1. `mix deps.get` + `mix compile --warnings-as-errors` in the new app,
    2. dumps `schema.dict.json` (`mix samen.catalog.dump`) so the drift check is green.

  Pass `--no-compile` to only emit files (used when the caller drives compile itself).
  """

  use Mix.Task

  alias Samen.Gen.App, as: Gen

  @switches [
    module: :string,
    prefix: :string,
    abbrev: :string,
    target: :string,
    reserve_abbrevs: :boolean,
    compile: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, strict: @switches)

    module = require_opt!(opts, :module)
    prefix = require_opt!(opts, :prefix)
    abbrev = require_opt!(opts, :abbrev)

    reserve? = Keyword.get(opts, :reserve_abbrevs, true)
    compile? = Keyword.get(opts, :compile, true)

    target = Keyword.get(opts, :target) || Gen.default_target()

    spec = Gen.build_spec(module: module, prefix: prefix, abbrev: abbrev, target: target)

    Gen.validate!(spec)

    if reserve?, do: Gen.reserve_abbrevs!(spec)

    Gen.write_app!(spec)

    Mix.shell().info("samen.gen.app: wrote #{spec.app_dir}")

    if compile? do
      Gen.compile_and_dump!(spec)
      Mix.shell().info("samen.gen.app: compiled + dumped schema.dict.json — app is gate-ready.")
    end

    :ok
  end

  defp require_opt!(opts, key) do
    case Keyword.get(opts, key) do
      nil -> Mix.raise("mix samen.gen.app: missing required --#{key}")
      "" -> Mix.raise("mix samen.gen.app: --#{key} may not be empty")
      val -> val
    end
  end
end
