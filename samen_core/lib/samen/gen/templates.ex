defmodule Samen.Gen.Templates do
  @moduledoc """
  The templated file set for `mix samen.gen.app` (T6.4). Returns `{relative_path, contents}`
  pairs; both are run through `Samen.Gen.App.render/2` (a `<%= key %>` substitution — no EEx,
  so the generator carries no template-runtime dependency).

  Every template is a parametrized copy of the proven `pawchart` reference so the generated
  app is correct-by-construction: it passes the full samen_core verifier gate on first run.

  WS-D D2 (ADR-022): `files/2` grows the set conditionally — `files(false, false)` is the
  original 26-file headless (data-only) output, byte-for-byte unchanged (`--headless`,
  AC-G4-10); `files(true, false)` swaps the `[MOD]` templates (mix.exs, config,
  application.ex, .gitignore, README) for their web variants and adds the web tree (the
  pawchart 5-file `*_web/` shape), the Primitives mount, the operator namespace (the
  driftwood shape), and their migrations.

  WS-D D3 (ADR-022): `files(true, true)` — the default — further swaps the api `[MOD]`
  templates (mix.exs gains ash_json_api; vertical.ex gains the DENY-BY-DEFAULT `json_api`
  allowlist + the bounded `:api_read`; the host router gains the `/api/v1` forward; ci.sh
  gains the `api_contract` step; README) and adds the `*_web/api/` tree (the demo/driftwood
  3-file shape: AshJsonApi router, Plug endpoint, KeyAuthPlug — the PageLimitClamp is the
  CANONICAL `Samen.Web.Api.PageLimitClamp`, inherited, never re-emitted) + the gen'd
  bounded/clamp/allowlist API red-path suite. There is deliberately NO `files(false, true)`
  clause — API-without-web fails closed (`Samen.Gen.App.validate!/1` + no function clause).
  All templates stay PLAIN STRINGS — no web module is referenced by samen_core's compile.
  """

  # ---------------------------------------------------------------- externalized bodies
  # The big heredoc emitters live as raw-text bodies under `priv/templates/*.eex` (edited
  # as files). Read at COMPILE TIME into module attributes (embedded in the BEAM, so no
  # runtime priv-path lookup) and re-emitted verbatim by the `defp <name>, do: @<name>`
  # stubs below. `@external_resource` triggers a recompile when a body file changes. The
  # bytes are IDENTICAL to the former inline heredocs (proven by templates_parity_test).
  # These are RAW TEXT, NOT EEx — the same tiny `Samen.Gen.App.render/2` `<%= key %>`
  # substitution runs over them, so literal `<%= ... %>` HEEx fragments pass through.
  @templates_dir Path.join(__DIR__, "../../../priv/templates")

  @external_resource Path.join(@templates_dir, "aggregate_ex.eex")
  @aggregate_ex File.read!(Path.join(@templates_dir, "aggregate_ex.eex"))
  @external_resource Path.join(@templates_dir, "anti_tautology_probe.eex")
  @anti_tautology_probe File.read!(Path.join(@templates_dir, "anti_tautology_probe.eex"))
  @external_resource Path.join(@templates_dir, "api_case_ex.eex")
  @api_case_ex File.read!(Path.join(@templates_dir, "api_case_ex.eex"))
  @external_resource Path.join(@templates_dir, "api_endpoint_ex.eex")
  @api_endpoint_ex File.read!(Path.join(@templates_dir, "api_endpoint_ex.eex"))
  @external_resource Path.join(@templates_dir, "api_key_auth_plug_ex.eex")
  @api_key_auth_plug_ex File.read!(Path.join(@templates_dir, "api_key_auth_plug_ex.eex"))
  @external_resource Path.join(@templates_dir, "api_router_ex.eex")
  @api_router_ex File.read!(Path.join(@templates_dir, "api_router_ex.eex"))
  @external_resource Path.join(@templates_dir, "approvals_ex.eex")
  @approvals_ex File.read!(Path.join(@templates_dir, "approvals_ex.eex"))
  @external_resource Path.join(@templates_dir, "application_ex.eex")
  @application_ex File.read!(Path.join(@templates_dir, "application_ex.eex"))
  @external_resource Path.join(@templates_dir, "application_ex_web.eex")
  @application_ex_web File.read!(Path.join(@templates_dir, "application_ex_web.eex"))
  @external_resource Path.join(@templates_dir, "billing_ex.eex")
  @billing_ex File.read!(Path.join(@templates_dir, "billing_ex.eex"))
  @external_resource Path.join(@templates_dir, "ci_bootstrap.eex")
  @ci_bootstrap File.read!(Path.join(@templates_dir, "ci_bootstrap.eex"))
  @external_resource Path.join(@templates_dir, "ci_sh.eex")
  @ci_sh File.read!(Path.join(@templates_dir, "ci_sh.eex"))
  @external_resource Path.join(@templates_dir, "ci_sh_api.eex")
  @ci_sh_api File.read!(Path.join(@templates_dir, "ci_sh_api.eex"))
  @external_resource Path.join(@templates_dir, "config_exs.eex")
  @config_exs File.read!(Path.join(@templates_dir, "config_exs.eex"))
  @external_resource Path.join(@templates_dir, "config_exs_web.eex")
  @config_exs_web File.read!(Path.join(@templates_dir, "config_exs_web.eex"))
  @external_resource Path.join(@templates_dir, "config_prod_exs.eex")
  @config_prod_exs File.read!(Path.join(@templates_dir, "config_prod_exs.eex"))
  @external_resource Path.join(@templates_dir, "config_prod_exs_web.eex")
  @config_prod_exs_web File.read!(Path.join(@templates_dir, "config_prod_exs_web.eex"))
  @external_resource Path.join(@templates_dir, "data_case.eex")
  @data_case File.read!(Path.join(@templates_dir, "data_case.eex"))
  @external_resource Path.join(@templates_dir, "deploy_runbook.eex")
  @deploy_runbook File.read!(Path.join(@templates_dir, "deploy_runbook.eex"))
  @external_resource Path.join(@templates_dir, "dev_exs_web.eex")
  @dev_exs_web File.read!(Path.join(@templates_dir, "dev_exs_web.eex"))
  @external_resource Path.join(@templates_dir, "dockerfile.eex")
  @dockerfile File.read!(Path.join(@templates_dir, "dockerfile.eex"))
  @external_resource Path.join(@templates_dir, "endpoint_ex.eex")
  @endpoint_ex File.read!(Path.join(@templates_dir, "endpoint_ex.eex"))
  @external_resource Path.join(@templates_dir, "fly_toml.eex")
  @fly_toml File.read!(Path.join(@templates_dir, "fly_toml.eex"))
  @external_resource Path.join(@templates_dir, "gitignore_deploy.eex")
  @gitignore_deploy File.read!(Path.join(@templates_dir, "gitignore_deploy.eex"))
  @external_resource Path.join(@templates_dir, "home_live_ex.eex")
  @home_live_ex File.read!(Path.join(@templates_dir, "home_live_ex.eex"))
  @external_resource Path.join(@templates_dir, "m_app_resources.eex")
  @m_app_resources File.read!(Path.join(@templates_dir, "m_app_resources.eex"))
  @external_resource Path.join(@templates_dir, "m_approvals.eex")
  @m_approvals File.read!(Path.join(@templates_dir, "m_approvals.eex"))
  @external_resource Path.join(@templates_dir, "m_ash_functions.eex")
  @m_ash_functions File.read!(Path.join(@templates_dir, "m_ash_functions.eex"))
  @external_resource Path.join(@templates_dir, "m_aud_event.eex")
  @m_aud_event File.read!(Path.join(@templates_dir, "m_aud_event.eex"))
  @external_resource Path.join(@templates_dir, "m_catalog.eex")
  @m_catalog File.read!(Path.join(@templates_dir, "m_catalog.eex"))
  @external_resource Path.join(@templates_dir, "m_erasure.eex")
  @m_erasure File.read!(Path.join(@templates_dir, "m_erasure.eex"))
  @external_resource Path.join(@templates_dir, "m_migration_meta.eex")
  @m_migration_meta File.read!(Path.join(@templates_dir, "m_migration_meta.eex"))
  @external_resource Path.join(@templates_dir, "m_mount_operator_scopes.eex")
  @m_mount_operator_scopes File.read!(Path.join(@templates_dir, "m_mount_operator_scopes.eex"))
  @external_resource Path.join(@templates_dir, "m_mount_primitives_scope.eex")
  @m_mount_primitives_scope File.read!(Path.join(@templates_dir, "m_mount_primitives_scope.eex"))
  @external_resource Path.join(@templates_dir, "m_reveal.eex")
  @m_reveal File.read!(Path.join(@templates_dir, "m_reveal.eex"))
  @external_resource Path.join(@templates_dir, "m_tnt_object_record.eex")
  @m_tnt_object_record File.read!(Path.join(@templates_dir, "m_tnt_object_record.eex"))
  @external_resource Path.join(@templates_dir, "m_vault.eex")
  @m_vault File.read!(Path.join(@templates_dir, "m_vault.eex"))
  @external_resource Path.join(@templates_dir, "mix_exs.eex")
  @mix_exs File.read!(Path.join(@templates_dir, "mix_exs.eex"))
  @external_resource Path.join(@templates_dir, "mix_exs_api.eex")
  @mix_exs_api File.read!(Path.join(@templates_dir, "mix_exs_api.eex"))
  @external_resource Path.join(@templates_dir, "mix_exs_web.eex")
  @mix_exs_web File.read!(Path.join(@templates_dir, "mix_exs_web.eex"))
  @external_resource Path.join(@templates_dir, "operator_ex.eex")
  @operator_ex File.read!(Path.join(@templates_dir, "operator_ex.eex"))
  @external_resource Path.join(@templates_dir, "page_controller_ex.eex")
  @page_controller_ex File.read!(Path.join(@templates_dir, "page_controller_ex.eex"))
  @external_resource Path.join(@templates_dir, "primitives_ex.eex")
  @primitives_ex File.read!(Path.join(@templates_dir, "primitives_ex.eex"))
  @external_resource Path.join(@templates_dir, "readme.eex")
  @readme File.read!(Path.join(@templates_dir, "readme.eex"))
  @external_resource Path.join(@templates_dir, "readme_api.eex")
  @readme_api File.read!(Path.join(@templates_dir, "readme_api.eex"))
  @external_resource Path.join(@templates_dir, "readme_web.eex")
  @readme_web File.read!(Path.join(@templates_dir, "readme_web.eex"))
  @external_resource Path.join(@templates_dir, "record_api_test.eex")
  @record_api_test File.read!(Path.join(@templates_dir, "record_api_test.eex"))
  @external_resource Path.join(@templates_dir, "record_vault_test.eex")
  @record_vault_test File.read!(Path.join(@templates_dir, "record_vault_test.eex"))
  @external_resource Path.join(@templates_dir, "release_ex.eex")
  @release_ex File.read!(Path.join(@templates_dir, "release_ex.eex"))
  @external_resource Path.join(@templates_dir, "router_ex.eex")
  @router_ex File.read!(Path.join(@templates_dir, "router_ex.eex"))
  @external_resource Path.join(@templates_dir, "router_ex_api.eex")
  @router_ex_api File.read!(Path.join(@templates_dir, "router_ex_api.eex"))
  @external_resource Path.join(@templates_dir, "runtime_exs.eex")
  @runtime_exs File.read!(Path.join(@templates_dir, "runtime_exs.eex"))
  @external_resource Path.join(@templates_dir, "seed_task_ex.eex")
  @seed_task_ex File.read!(Path.join(@templates_dir, "seed_task_ex.eex"))
  @external_resource Path.join(@templates_dir, "seeds_ex.eex")
  @seeds_ex File.read!(Path.join(@templates_dir, "seeds_ex.eex"))
  @external_resource Path.join(@templates_dir, "seeds_vault_test.eex")
  @seeds_vault_test File.read!(Path.join(@templates_dir, "seeds_vault_test.eex"))
  @external_resource Path.join(@templates_dir, "test_exs.eex")
  @test_exs File.read!(Path.join(@templates_dir, "test_exs.eex"))
  @external_resource Path.join(@templates_dir, "test_helper.eex")
  @test_helper File.read!(Path.join(@templates_dir, "test_helper.eex"))
  @external_resource Path.join(@templates_dir, "vertical_ex.eex")
  @vertical_ex File.read!(Path.join(@templates_dir, "vertical_ex.eex"))
  @external_resource Path.join(@templates_dir, "vertical_ex_api.eex")
  @vertical_ex_api File.read!(Path.join(@templates_dir, "vertical_ex_api.eex"))

  @doc "The full ordered file set. `web?`/`api?` gate the WS-D D2/D3 emissions (ADR-022)."
  def files(web? \\ false), do: files(web?, web?)

  @doc """
  As `files/1`, with the api layer gated independently (WS-D D3). `files/2` never emits
  the deploy layer (WS-D D10 is opt-in, default OFF, ADR-024 §2.6) — it delegates to
  `files/3` with `deploy?: false`.
  """
  def files(web?, api?), do: files(web?, api?, false)

  @doc """
  As `files/2`, with the deploy layer gated independently (WS-D D10, ADR-024 — default
  OFF, opt-in via `--deploy` / `mix samen.gen.deploy`). The deploy layer REQUIRES the web
  layer (the emitted `config/runtime.exs`/`fly.toml` read `PHX_HOST` and the endpoint port
  the web plane owns); `Samen.Gen.App.validate_against!/2` fails closed on `deploy?` without
  `web?`, so there is deliberately NO `files(false, _, true)` clause.

  The deploy emissions are FAIL-HONEST (ADR-024): structurally-correct `fly.toml` +
  `Dockerfile` + release `rel/env.sh.eex` + a fail-CLOSED `config/runtime.exs` (raises a
  named error on any missing required secret rather than booting insecurely) + a per-app
  `docs/runbooks/deploy.md` whose operator-TODO block names what stays human (real Fly
  account, real Neon project, real KMS keys, real OTLP exporter). They compile/parse but do
  NOT claim a live deploy. All templates stay PLAIN STRINGS.
  """
  def files(web?, api?, deploy?)

  def files(false, false, false) do
    [
      {"mix.exs", mix_exs()},
      {".formatter.exs", formatter_exs()},
      {"config/config.exs", config_exs()},
      {"config/dev.exs", dev_exs()},
      {"config/test.exs", test_exs()},
      # ADR-045 §2.1 — a prod.exs so `import_config "#{config_env()}.exs"` does not ABORT a prod
      # config load on the missing file. The web set swaps in the web variant (below) that also
      # re-states the armed tenant-gate + KMS boot posture. Secrets stay in runtime.exs (deploy).
      {"config/prod.exs", config_prod_exs()},
      {"lib/<%= otp_app %>/application.ex", application_ex()},
      {"lib/<%= otp_app %>/repo.ex", repo_ex()},
      {"lib/<%= otp_app %>/billing.ex", billing_ex()},
      {"lib/<%= otp_app %>/vertical.ex", vertical_ex()},
      {"lib/<%= otp_app %>/aggregate.ex", aggregate_ex()},
      {"lib/<%= otp_app %>/approvals.ex", approvals_ex()},
      {"priv/repo/migrations/20260705010000_ash_functions.exs", m_ash_functions()},
      {"priv/repo/migrations/20260705010100_oban.exs", m_oban()},
      {"priv/repo/migrations/20260705010200_vault_tables.exs", m_vault()},
      {"priv/repo/migrations/20260705010300_reveal_grants.exs", m_reveal()},
      {"priv/repo/migrations/20260705010400_erasure.exs", m_erasure()},
      {"priv/repo/migrations/20260705015000_catalog_tables.exs", m_catalog()},
      {"priv/repo/migrations/20260705020000_aud_event.exs", m_aud_event()},
      {"priv/repo/migrations/20260705110000_migration_meta.exs", m_migration_meta()},
      {"priv/repo/migrations/20260706070000_tnt_field.exs", m_tnt_field()},
      {"priv/repo/migrations/20260706080000_tnt_object_record.exs", m_tnt_object_record()},
      {"priv/repo/migrations/20260709100000_app_resources.exs", m_app_resources()},
      {"priv/repo/migrations/20260709150000_add_approvals.exs", m_approvals()},
      {"priv/ci_bootstrap.exs", ci_bootstrap()},
      {"priv/anti_tautology_probe.exs", anti_tautology_probe()},
      {"test/test_helper.exs", test_helper()},
      {"test/support/data_case.ex", data_case()},
      {"test/record_vault_test.exs", record_vault_test()},
      {"ci.sh", ci_sh()},
      {".gitignore", gitignore()},
      {"README.md", readme()}
    ]
  end

  # The RUNNING-product set (ADR-022 default): the headless set with the `[MOD]` templates
  # swapped for their web variants + the `[NEW]` web emissions spliced in.
  def files(true, false, false) do
    mods = %{
      "mix.exs" => mix_exs_web(),
      ".formatter.exs" => formatter_exs_web(),
      "config/config.exs" => config_exs_web(),
      "config/dev.exs" => dev_exs_web(),
      "config/prod.exs" => config_prod_exs_web(),
      "lib/<%= otp_app %>/application.ex" => application_ex_web(),
      ".gitignore" => gitignore_web(),
      "README.md" => readme_web()
    }

    base =
      Enum.map(files(false, false, false), fn {path, template} ->
        {path, Map.get(mods, path, template)}
      end)

    web_new = [
      # Data-layer mounts the web surfaces read (Primitives → notifications/flags;
      # Operator → the ADR-010 control-plane workspace) + their catalog-in-tx migrations.
      {"lib/<%= otp_app %>/primitives.ex", primitives_ex()},
      {"lib/<%= otp_app %>/operator.ex", operator_ex()},
      {"priv/repo/migrations/20260714200000_mount_primitives_scope.exs",
       m_mount_primitives_scope()},
      {"priv/repo/migrations/20260714210000_mount_operator_scopes.exs",
       m_mount_operator_scopes()},
      # The 5-file `*_web/` tree (the pawchart shape, ADR-022).
      {"lib/<%= otp_app %>_web/endpoint.ex", endpoint_ex()},
      {"lib/<%= otp_app %>_web/router.ex", router_ex()},
      {"lib/<%= otp_app %>_web/layouts.ex", layouts_ex()},
      {"lib/<%= otp_app %>_web/page_controller.ex", page_controller_ex()},
      {"lib/<%= otp_app %>_web/error_html.ex", error_html_ex()}
    ]

    base ++ web_new
  end

  # The FULL default set (WS-D D3, ADR-022): the web set with the api `[MOD]` templates
  # swapped in + the `[NEW]` `*_web/api/` tree and the gen'd API red-path suite appended.
  # `api_contract.v1.json` is NOT a template — it is dumped from the COMPILED app by
  # `Samen.Gen.App.compile_and_dump!/1` (`mix samen.verify.api_contract --update`), the
  # same way `schema.dict.json` is.
  def files(true, true, false) do
    mods = %{
      "mix.exs" => mix_exs_api(),
      ".formatter.exs" => formatter_exs_api(),
      "lib/<%= otp_app %>/vertical.ex" => vertical_ex_api(),
      "lib/<%= otp_app %>_web/router.ex" => router_ex_api(),
      "ci.sh" => ci_sh_api(),
      "README.md" => readme_api()
    }

    base =
      Enum.map(files(true, false, false), fn {path, template} ->
        {path, Map.get(mods, path, template)}
      end)

    api_new = [
      # The 3-file `*_web/api/` tree (the demo/driftwood shape). The page-limit clamp is
      # the CANONICAL `Samen.Web.Api.PageLimitClamp` (samen_web is a dep) — inherited,
      # never re-emitted (design §3 drift guard).
      {"lib/<%= otp_app %>_web/api/router.ex", api_router_ex()},
      {"lib/<%= otp_app %>_web/api/endpoint.ex", api_endpoint_ex()},
      {"lib/<%= otp_app %>_web/api/key_auth_plug.ex", api_key_auth_plug_ex()},
      # The gen'd API red-path suite: bounded-by-default / clamp-to-cap / deny-by-default
      # allowlist (AC-G4-2 / AC-G4-3).
      {"test/support/api_case.ex", api_case_ex()},
      {"test/record_api_test.exs", record_api_test()},
      # WS-D D4 seeds (`--seeds`, default ON): a Samen.Factory-backed seeds module +
      # a `<app>.seed` mix task, vault-aware by construction — the seeded 🔒 secret
      # routes through the vault chokepoint (raw domain row holds `vt_*`, plaintext
      # nowhere). Mirrors pawchart's seeds.ex / pawchart.seed.ex shape.
      {"lib/<%= otp_app %>/seeds.ex", seeds_ex()},
      {"lib/mix/tasks/<%= otp_app %>.seed.ex", seed_task_ex()},
      # WS-D D4 red path: the gen'd seed vault-routing test seeds through Factory and
      # asserts the seeded plaintext secret is NOWHERE at rest (raw row holds `vt_*`).
      {"test/seeds_vault_test.exs", seeds_vault_test()}
    ]

    base ++ api_new
  end

  # The DEPLOY layer (WS-D D10, ADR-024 — opt-in, default OFF). Appends the fail-honest
  # deploy artifacts on top of the web (`--no-api`) or full (`--api`) base. It swaps the
  # `[MOD]` `.gitignore` (to ignore the release build output + the local dev keystore that
  # `config/runtime.exs` never uses in prod) and adds the five `[NEW]` deploy emissions.
  # There is NO `files(false, _, true)` clause — deploy-without-web fails closed in
  # `Samen.Gen.App.validate_against!/2` (the runtime/fly.toml read the endpoint the web
  # plane owns).
  def files(true, api?, true) when is_boolean(api?) do
    mods = %{
      ".gitignore" => gitignore_deploy()
    }

    base =
      Enum.map(files(true, api?, false), fn {path, template} ->
        {path, Map.get(mods, path, template)}
      end)

    deploy_new = [
      # Fly.io app manifest — app name, region, `[http_service]` on the endpoint port,
      # a `/healthz` health check, and a `release_command` that runs migrations. Parses
      # as valid TOML; NOT a claim of a live app (the operator's real Fly account is a TODO).
      {"fly.toml", fly_toml()},
      # The release-safe migrator `fly.toml`'s release_command runs. No Mix at runtime —
      # loads the app + runs Ash/Ecto migrations via Ecto.Migrator.
      {"lib/<%= otp_app %>/release.ex", release_ex()},
      # The container image — a two-stage `mix release` build (elixir builder → slim
      # runtime). Structurally correct; not `docker build`-proven in CI (ADR-024 proof bound).
      {"Dockerfile", dockerfile()},
      # The release env shim `mix release` sources — sets node name/cookie from env.
      {"rel/env.sh.eex", rel_env_sh_eex()},
      # The FAIL-CLOSED prod runtime config (ADR-024 / AC-G16-2): reads DATABASE_URL,
      # SECRET_KEY_BASE, PHX_HOST + the KMS env (SAMEN_KMS_*) and RAISES a named error on
      # any missing required secret rather than booting insecurely.
      {"config/runtime.exs", runtime_exs()},
      # The honest operator runbook (AC-G16-3): Neon branch-per-env provisioning, the
      # secrets checklist (incl. KMS + SECRET_KEY_BASE generation), and an explicit
      # OPERATOR-TODO block naming what stays human (Fly account, Neon project, KMS keys,
      # OTLP exporter). No aspirational "just run `fly deploy`".
      {"docs/runbooks/deploy.md", deploy_runbook()}
    ]

    base ++ deploy_new
  end

  # ------------------------------------------------------------------ mix.exs
  defp mix_exs, do: @mix_exs

  # ------------------------------------------------------------------ .formatter.exs
  # A freshly generated app authors Ash DSL (`postgres do ... end`, `attributes do ... end`,
  # `pii do ... end`) via `Samen.Resource` — without `import_deps: [:ash, :ash_postgres]`,
  # `mix format` doesn't know those macros are `locals_without_parens` and will reformat
  # the DSL wrongly. Mirrors the REAL `samen_core/.formatter.exs` (the framework kernel
  # authors the same DSL shape). `mix format`'s `import_deps` requires a DIRECT dep (not
  # just transitively resolved) — `mix_exs/0` lists `ash`/`ash_postgres` directly (pinned
  # to samen_core's exact versions, the same idiom `samen_web/mix.exs` already uses) so
  # this resolves even for the headless (data-only) set.
  defp formatter_exs do
    """
    # Used by "mix format"
    [
      import_deps: [:ash, :ash_postgres],
      inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
    ]
    """
  end

  # ------------------------------------------------------------------ config
  defp config_exs, do: @config_exs

  # ADR-045 §2.1 — the prod compile-time config (base, web-agnostic) + the web variant that
  # re-states the armed tenant-gate + KMS boot posture. Without a prod.exs, a MIX_ENV=prod
  # `import_config "#{config_env()}.exs"` ABORTS on the missing file.
  defp config_prod_exs, do: @config_prod_exs
  defp config_prod_exs_web, do: @config_prod_exs_web

  defp dev_exs do
    """
    import Config

    config :<%= otp_app %>, <%= module %>.Repo,
      username: System.get_env("USER") || "postgres",
      password: "",
      hostname: "localhost",
      database: "<%= otp_app %>_dev",
      pool_size: 10

    config :logger, level: :info
    """
  end

  defp test_exs, do: @test_exs

  # ------------------------------------------------------------------ lib
  defp application_ex, do: @application_ex

  # T37h — the per-app Approvals engine client (ADR-040 §4.7/T35, folded into
  # `mix samen.gen.app` so a generated app's reveal-approve routes through
  # `Samen.Approvals`, not the pre-T35 inline fallback).
  defp approvals_ex, do: @approvals_ex

  defp repo_ex do
    """
    defmodule <%= module %>.Repo do
      @moduledoc "<%= module %>'s single Postgres repo (one-DB-per-product, doc §runs)."
      use AshPostgres.Repo,
        otp_app: :<%= otp_app %>,
        adapter: Ecto.Adapters.Postgres,
        warn_on_missing_ash_functions?: false

      def installed_extensions, do: ["uuid-ossp", "citext"]

      def min_pg_version, do: %Version{major: 14, minor: 0, patch: 0}
    end
    """
  end

  defp billing_ex, do: @billing_ex

  defp vertical_ex, do: @vertical_ex

  defp aggregate_ex, do: @aggregate_ex

  # ------------------------------------------------------------------ substrate migrations
  defp m_ash_functions, do: @m_ash_functions

  defp m_oban do
    """
    defmodule <%= module %>.Repo.Migrations.AddOban do
      @moduledoc "Installs Oban versioned tables."
      use Ecto.Migration

      def up, do: Oban.Migrations.up()
      def down, do: Oban.Migrations.down()
    end
    """
  end

  defp m_vault, do: @m_vault

  defp m_reveal, do: @m_reveal

  defp m_erasure, do: @m_erasure

  defp m_catalog, do: @m_catalog

  defp m_aud_event, do: @m_aud_event

  defp m_migration_meta, do: @m_migration_meta

  defp m_tnt_field do
    """
    defmodule <%= module %>.Repo.Migrations.TntField do
      @moduledoc "Bootstrap the tnt_field table — the Tier-1 tenant custom-field catalog (T3.8)."
      use Samen.Migration

      def up, do: create_tnt_field_table()
      def down, do: drop(table(:tnt_field))
    end
    """
  end

  defp m_tnt_object_record, do: @m_tnt_object_record

  defp m_app_resources, do: @m_app_resources
  defp m_approvals, do: @m_approvals

  # ------------------------------------------------------------------ priv scripts
  defp ci_bootstrap, do: @ci_bootstrap

  defp anti_tautology_probe, do: @anti_tautology_probe

  # ------------------------------------------------------------------ test
  defp test_helper, do: @test_helper

  defp data_case, do: @data_case

  defp record_vault_test, do: @record_vault_test

  # ------------------------------------------------------------------ ci.sh
  defp ci_sh, do: @ci_sh

  defp gitignore do
    """
    /_build/
    /deps/
    /cover/
    /doc/
    /.fetch
    erl_crash.dump
    *.ez
    *.beam
    /config/*.secret.exs
    .elixir_ls/
    """
  end

  defp readme, do: @readme

  # ==================================================================== WS-D D2: --web
  # The RUNNING-product templates (ADR-022). Parametrized ports of the SHIPPED references:
  # pawchart's `pawchart_web/` (endpoint/router/layouts/page_controller/error_html + the
  # Primitives mount) and driftwood's operator namespace (`operator.ex` +
  # `mount_operator_scopes` + the `dpv` movement ledger). Framework code is INHERITED
  # (`Samen.Web.Router` macros, `Samen.Web.Layouts`, every LiveView) — never re-emitted.

  # ------------------------------------------------------------------ mix.exs (web)
  defp mix_exs_web, do: @mix_exs_web

  # ------------------------------------------------------------------ .formatter.exs (web)
  # As `formatter_exs/0`, plus `:phoenix` — the web layer authors a real `Phoenix.Router`
  # (`pipeline do ... end`, `scope ... do ... end`), and `phoenix` is a direct dep
  # (`mix_exs_web/0`), so its exported `locals_without_parens` resolves.
  defp formatter_exs_web do
    """
    # Used by "mix format"
    [
      import_deps: [:ash, :ash_postgres, :phoenix],
      inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
    ]
    """
  end

  # ------------------------------------------------------------------ config (web)
  defp config_exs_web, do: @config_exs_web

  defp dev_exs_web, do: @dev_exs_web

  # ------------------------------------------------------------------ application (web)
  defp application_ex_web, do: @application_ex_web

  # ------------------------------------------------------------------ primitives mount
  defp primitives_ex, do: @primitives_ex

  # ------------------------------------------------------------------ operator namespace
  defp operator_ex, do: @operator_ex

  # ------------------------------------------------------------------ web tree
  defp endpoint_ex, do: @endpoint_ex

  defp router_ex, do: @router_ex

  defp layouts_ex do
    """
    defmodule <%= module %>Web.Layouts do
      @moduledoc \"\"\"
      The <%= module %> root layout — the shared Samen shell (ADR-022, WS-D D1.4).
      Framework code is inherited, not re-emitted: the HTML lives in `Samen.Web.Layouts`.
      \"\"\"
      use Samen.Web.Layouts, title: "<%= module %> — a Samen vertical"
    end
    """
  end

  defp page_controller_ex, do: @page_controller_ex

  defp error_html_ex do
    """
    defmodule <%= module %>Web.ErrorHTML do
      @moduledoc "Minimal error renderer for <%= module %>."
      use Phoenix.Component

      def render(template, _assigns) do
        Phoenix.Controller.status_message_from_template(template)
      end
    end
    """
  end

  # ------------------------------------------------------------ WS-E `--modules` menu landing
  # The `Samen.UI` app-shell landing emitted ONLY when a mountable surface is selected
  # (`--modules`). It turns the mounted framework surfaces into a REAL menu (the "undocumented
  # as a menu" fix): the inherited Inbox/CRM/Billing/Support/Marketing groups come from
  # `Samen.UI.module_nav/1`; the selected end-user surfaces are the `:extra` "Product" nav
  # group (`<%= menu_nav_items %>`, computed by `Samen.Gen.App`). Statically rendered — it
  # renders no field value, so it has no masking surface. A default (no-`--modules`) app does
  # NOT emit this file and keeps `/` → `PageController.index` (byte-for-byte unchanged).
  @doc false
  def home_live_ex, do: @home_live_ex

  # ------------------------------------------------------------ primitives migration
  defp m_mount_primitives_scope, do: @m_mount_primitives_scope

  # ------------------------------------------------------------ operator migration
  defp m_mount_operator_scopes, do: @m_mount_operator_scopes

  # ------------------------------------------------------------------ misc (web)
  defp gitignore_web do
    """
    /_build/
    /deps/
    /cover/
    /doc/
    /.fetch
    erl_crash.dump
    *.ez
    *.beam
    /config/*.secret.exs
    .elixir_ls/
    /priv/dev_keystore/
    """
  end

  defp readme_web, do: @readme_web

  # ==================================================================== WS-D D3: --api
  # The public JSON:API templates (ADR-022). Parametrized ports of the SHIPPED references:
  # demo's `demo_web/api/` (AshJsonApi router / Plug endpoint / KeyAuthPlug) and the
  # demo Contact / driftwood Driver `json_api` DENY-BY-DEFAULT allowlist + bounded
  # `:api_read` idiom. The page-limit clamp is the CANONICAL `Samen.Web.Api.PageLimitClamp`
  # (samen_web is a dep of every --api app) — inherited, NEVER re-emitted (design §3).

  # ------------------------------------------------------------------ mix.exs (api)
  defp mix_exs_api, do: @mix_exs_api

  # ------------------------------------------------------------------ .formatter.exs (api)
  # As `formatter_exs_web/0`, plus `:ash_json_api` — the authored resource's `json_api do
  # ... end` block (`type/1`, `show_fields/1`, `derive_filter?/1`, `routes do ... end`) is
  # AshJsonApi DSL, and `ash_json_api` is a direct dep (`mix_exs_api/0`).
  defp formatter_exs_api do
    """
    # Used by "mix format"
    [
      import_deps: [:ash, :ash_postgres, :phoenix, :ash_json_api],
      inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
    ]
    """
  end

  # ------------------------------------------------------------------ vertical (api)
  defp vertical_ex_api, do: @vertical_ex_api

  # ------------------------------------------------------------------ host router (api)
  defp router_ex_api, do: @router_ex_api

  # ------------------------------------------------------------------ api tree
  defp api_router_ex, do: @api_router_ex

  defp api_endpoint_ex, do: @api_endpoint_ex

  defp api_key_auth_plug_ex, do: @api_key_auth_plug_ex

  # ------------------------------------------------------------------ api test support
  defp api_case_ex, do: @api_case_ex

  # ------------------------------------------------------------------ api red-path test
  defp record_api_test, do: @record_api_test

  # ------------------------------------------------------------------ ci.sh (api)
  defp ci_sh_api, do: @ci_sh_api

  # ------------------------------------------------------------------ seeds (D4)
  defp seeds_ex, do: @seeds_ex

  defp seed_task_ex, do: @seed_task_ex

  defp seeds_vault_test, do: @seeds_vault_test

  # ------------------------------------------------------------------ README (api)
  defp readme_api, do: @readme_api

  # ==================================================================== WS-D D10: --deploy
  # FAIL-HONEST deploy artifacts (ADR-024). Structurally-correct + compile/parse, but they do
  # NOT claim a live deploy: the fresh generation has no Fly account, no Neon project, and no
  # KMS keys (those stay operator-TODO, named in the runbook). `config/runtime.exs` fails
  # CLOSED — it raises a named error on any missing required secret rather than booting
  # insecurely (AC-G16-2). All plain strings; no deploy tooling referenced at samen_core
  # compile time.

  # ------------------------------------------------------------------ .gitignore (deploy)
  # The web `.gitignore` + the release build output (`mix release` writes under _build, but
  # `rel/` overlays are also worth guarding) and an explicit note that runtime SECRETS are
  # env-only (never a committed *.secret.exs) — matching the fail-closed runtime.
  defp gitignore_deploy, do: @gitignore_deploy

  # ------------------------------------------------------------------ fly.toml
  # A valid-TOML Fly.io manifest. app/primary_region are placeholders the operator sets
  # (the runbook says so); `[http_service]` binds the endpoint port; the `[[http_service.checks]]`
  # hits `/readyz` (the emitted page_controller READINESS route — 200 only when Postgres, the
  # KMS wrapped-DEK store, and Oban all answer; a static-200 `/healthz` would let Fly send
  # traffic to a machine whose deps are down); `[deploy] release_command`
  # runs migrations via the release's eval. NOT a claim of a live app — see the runbook's
  # OPERATOR-TODO block (real Fly account is human work).
  defp fly_toml, do: @fly_toml

  # ------------------------------------------------------------------ Dockerfile
  # A two-stage `mix release` build (elixir builder → slim debian runtime). Structurally
  # correct per Elixir/Phoenix release conventions; NOT `docker build`-proven in CI
  # (ADR-024 proof bound: compiles/parses + runtime raises + runbook names TODOs; no live
  # deploy assertion). The generated app is a SIBLING of samen_core/samen_web via `path:`
  # deps, so the build context note in the runbook explains the monorepo-root build.
  defp dockerfile, do: @dockerfile

  # ------------------------------------------------------------------ rel/env.sh.eex
  # The release env shim `mix release` sources on boot. Sets the node name + cookie from
  # env (Fly injects FLY_APP_NAME / RELEASE_COOKIE). Structurally correct release convention.
  defp rel_env_sh_eex do
    """
    #!/bin/sh
    # <%= module %> release env (WS-D D10). Sourced by the release boot scripts.
    # RELEASE_NODE / RELEASE_COOKIE let the running node be reachable + clustered; on Fly
    # the platform injects FLY_APP_NAME and a RELEASE_COOKIE secret.
    export RELEASE_DISTRIBUTION=name
    export RELEASE_NODE="<%= otp_app %>@127.0.0.1"
    """
  end

  # ------------------------------------------------------------------ config/runtime.exs
  # FAIL-CLOSED prod runtime config (ADR-024 / AC-G16-2). Evaluated at BOOT (not compile),
  # so it is the right place to read secrets. In :prod it reads DATABASE_URL, SECRET_KEY_BASE,
  # PHX_HOST + the KMS env (SAMEN_KMS_KEY_ID / SAMEN_KMS_REGION) and RAISES a clear, NAMED
  # error via `fetch_secret!/2` if any required secret is absent — a vaulted SaaS must fail
  # closed on a missing KMS key or secret_key_base, never boot with an empty-password/localhost
  # fallback (ADR-024 §2 "Boot with insecure defaults" rejected). Sabotaging the raise (making
  # a required secret optional) flips the D10 deploy probe's red path.
  defp runtime_exs, do: @runtime_exs

  # ------------------------------------------------------------------ lib/<app>/release.ex
  # The release-safe migrator `fly.toml`'s `release_command` invokes (`<app> eval
  # <module>.Release.migrate`). No Mix at runtime — it loads the app and runs the same
  # `Ecto.Migrator.run(Repo, :up, all: true)` the ci_bootstrap uses, so a prod deploy
  # applies the substrate + resource migrations before taking traffic.
  defp release_ex, do: @release_ex

  # ------------------------------------------------------------------ docs/runbooks/deploy.md
  # The HONEST operator runbook (AC-G16-3). Neon branch-per-env provisioning, the secrets
  # checklist (incl. KMS + SECRET_KEY_BASE generation), and an explicit OPERATOR-TODO block
  # naming the four human prerequisites: real Fly account, real Neon project, real KMS keys,
  # real OTLP exporter. The structural doc test asserts this block exists with all four named
  # items (AC-G16-3). No aspirational "just run `fly deploy`".
  defp deploy_runbook, do: @deploy_runbook
end
