defmodule Mix.Tasks.Samen.Gen.App do
  @shortdoc "Scaffold a new Samen vertical app (correct-by-construction, gate-green on first run)."

  @moduledoc """
  `mix samen.gen.app` — the T6.4 GENERATOR (WS-D D2: emits a RUNNING product, ADR-022).
  Scaffolds a new Samen vertical app shaped exactly like `demo` / `driftwood` / `pawchart`:
  a sibling Mix project that depends on `samen_core` (`path: "../samen_core"`), mounts one
  universal scope AS-IS, authors one vertical resource with a `pii do` scalar-vault field,
  defines one token-blind aggregate projection, ships all substrate migrations + a
  catalog-in-transaction resource migration (`Samen.Migration`), and wires its own `ci.sh`
  to the FULL samen_core verifier gate.

  By DEFAULT (`--web`, ADR-022) the app is a running product: the 5-file `*_web/` tree
  (thin emitted endpoint, router of `Samen.Web.Router` macro mounts, `use Samen.Web.Layouts`
  one-liner, page controller with `/healthz`, error html), a Primitives mount (notifications
  inbox + FeatureFlag rows), an ADR-010 OPERATOR namespace, the web deps + web plane +
  endpoint/pubsub config. By DEFAULT WITH the web layer (`--api`, WS-D D3) it also ships
  the public `/api/v1` JSON:API: the 3-file `*_web/api/` tree (AshJsonApi router, Plug
  endpoint with KeyAuthPlug → the inherited `Samen.Web.Api.PageLimitClamp`, the two-key-
  class bearer resolver), a DENY-BY-DEFAULT `json_api` allowlist + BOUNDED `:api_read`
  (default_limit 50 / max_page_size 200) on the authored resource, the gen'd
  bounded/clamp/allowlist red-path suite, a committed `api_contract.v1.json` snapshot and
  the `api_contract` ci.sh step. `--headless` reproduces the original data-only output
  exactly.

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
      aggregate-plane abbrev (`<p>a`). With `--web` the FIRST prefix letter also derives the
      Primitives abbrevs (`<p1>nt/np/fl/sh/wh/ff`) and the operator namespace
      (`<p1>o?/<p1>p?/<p1>q?` — the driftwood per-plane convention). Must not collide with
      abbrevs already reserved in the registry (checked; fails closed on collision — this
      includes prefixes ending in `o/p/q/n`, which collide internally with the derived
      operator/primitives sets).
    * `--abbrev`  (required) — the **3-letter lowercase** abbrev for the authored vertical
      resource (e.g. `wid`). Reserved permanently in the registry.
    * `--target`  (optional) — the PARENT directory the new app dir is created under. Defaults
      to the parent of `samen_core` (i.e. the monorepo root) so `../samen_core` resolves.
    * `--web` / `--no-web` (default: `--web`, ADR-022) — emit the web layer (the `*_web/`
      tree, the Primitives + Operator mounts and their migrations, samen_web/phoenix deps,
      web plane + endpoint config).
    * `--api` / `--no-api` (default: follows `--web`, WS-D D3) — emit the public `/api/v1`
      JSON:API layer (the `*_web/api/` tree, the deny-by-default allowlist + bounded
      `:api_read` on the authored resource, the API red-path tests, the `api_contract.v1.json`
      snapshot + ci.sh step). REQUIRES the web layer (the host router forwards `/api/v1`);
      `--no-web --api` fails closed.
    * `--headless` — the escape hatch: all product layers off; reproduces the original
      26-file data-only output exactly (AC-G4-10). Conflicts with an explicit `--web`/`--api`.
    * `--port` (optional, default 4050) — the dev HTTP port wired into the endpoint config.
    * `--no-reserve-abbrevs` — do NOT append the reserved abbrevs to
      `samen_core/priv/abbrev_registry.json`. Produces an app whose resource abbrev is
      UNRESERVED — used by the red-path test to prove the compile-time gate catches a
      missing abbrev. (Default: reserve.)

  ## What it produces

      <app>/
        mix.exs                 # samen_core (+ samen_web/phoenix/bandit under --web,
                                # + ash_json_api under --api) deps
        config/{config,dev,test}.exs
        lib/<app>/{application,repo,billing,<resource_domain>,aggregate}.ex
        lib/<app>/{primitives,operator}.ex          # --web: framework-surface mounts
        lib/<app>_web/{endpoint,router,layouts,page_controller,error_html}.ex   # --web
        lib/<app>_web/api/{router,endpoint,key_auth_plug}.ex                    # --api
        priv/repo/migrations/…  # the substrate tables + catalog-in-tx resource migrations
        priv/ci_bootstrap.exs
        priv/anti_tautology_probe.exs
        test/{test_helper,<resource>_vault_test}.exs + test/support/data_case.ex
        test/record_api_test.exs + test/support/api_case.ex                     # --api
        schema.dict.json        # committed drift baseline (dumped from the compiled app)
        api_contract.v1.json    # --api: committed structural-break snapshot (post-compile)
        ci.sh                   # the full verifier gate, wired to the app

  The abbrev registry (`samen_core/priv/abbrev_registry.json`) is a GLOBAL, permanent file
  (`Samen.AbbrevRegistry`). Reserving abbrevs appends rows to it (append-only, idempotent) —
  this is the deliberate global-registry coupling the T6.1 extraction retro documents.

  ## Correct-by-construction post-steps

  When `--compile` is set (the default), after writing files the generator:

    1. `mix deps.get` + `mix compile --warnings-as-errors` in the new app,
    2. dumps `schema.dict.json` (`mix samen.catalog.dump`) so the drift check is green,
    3. with `--api`, dumps `api_contract.v1.json` (`mix samen.verify.api_contract --update`)
       so the gate's `api_contract` step is green.

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
    compile: :boolean,
    web: :boolean,
    api: :boolean,
    headless: :boolean,
    port: :integer
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

    # WS-D D2 (ADR-022): web ON by default; `--headless` turns the product layers off.
    # An explicit `--web --headless` (or `--api --headless`) is contradictory — fail closed.
    headless? = Keyword.get(opts, :headless, false)

    if headless? and Keyword.get(opts, :web) == true do
      Mix.raise("mix samen.gen.app: --headless conflicts with an explicit --web")
    end

    if headless? and Keyword.get(opts, :api) == true do
      Mix.raise("mix samen.gen.app: --headless conflicts with an explicit --api")
    end

    web? = if headless?, do: false, else: Keyword.get(opts, :web, true)

    # WS-D D3: the JSON:API layer follows the web layer by default (`--no-api` opts out;
    # `--api` without the web layer fails closed in Gen.validate!/1).
    api? = if headless?, do: false, else: Keyword.get(opts, :api, web?)

    spec =
      Gen.build_spec(
        module: module,
        prefix: prefix,
        abbrev: abbrev,
        target: target,
        web: web?,
        api: api?,
        port: Keyword.get(opts, :port, 4050)
      )

    Gen.validate!(spec)

    if reserve?, do: Gen.reserve_abbrevs!(spec)

    Gen.write_app!(spec)

    Mix.shell().info("samen.gen.app: wrote #{spec.app_dir}")

    if compile? do
      Gen.compile_and_dump!(spec)

      dumped =
        if spec.api?, do: "schema.dict.json + api_contract.v1.json", else: "schema.dict.json"

      Mix.shell().info("samen.gen.app: compiled + dumped #{dumped} — app is gate-ready.")
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
