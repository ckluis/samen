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
      {"config/config.exs", config_exs()},
      {"config/dev.exs", dev_exs()},
      {"config/test.exs", test_exs()},
      {"lib/<%= otp_app %>/application.ex", application_ex()},
      {"lib/<%= otp_app %>/repo.ex", repo_ex()},
      {"lib/<%= otp_app %>/billing.ex", billing_ex()},
      {"lib/<%= otp_app %>/vertical.ex", vertical_ex()},
      {"lib/<%= otp_app %>/aggregate.ex", aggregate_ex()},
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
      "config/config.exs" => config_exs_web(),
      "config/dev.exs" => dev_exs_web(),
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
  defp mix_exs do
    """
    defmodule <%= module %>.MixProject do
      use Mix.Project

      # <%= module %> — a Samen vertical app scaffolded by `mix samen.gen.app` (T6.4).
      # Shaped like demo/driftwood/pawchart: mounts the samen_core Billing scope AS-IS,
      # authors one vertical resource (<%= module %>.Vertical.Record) with a pii_ scalar
      # vault field, defines one token-blind aggregate projection, and runs the FULL
      # samen_core verifier gate in its own ci.sh. Correct-by-construction: green on
      # first `bash ci.sh`.
      def project do
        [
          app: :<%= otp_app %>,
          version: "0.1.0",
          elixir: "~> 1.18",
          elixirc_paths: elixirc_paths(Mix.env()),
          consolidate_protocols: Mix.env() != :test,
          start_permanent: Mix.env() == :prod,
          deps: deps(),
          aliases: aliases()
        ]
      end

      def application do
        [
          extra_applications: [:logger],
          mod: {<%= module %>.Application, []}
        ]
      end

      defp elixirc_paths(:test), do: ["lib", "test/support"]
      defp elixirc_paths(_), do: ["lib"]

      defp deps do
        [
          {:samen_core, path: "<%= samen_core_path %>"},
          {:jason, "~> 1.4"},
          {:stream_data, "~> 1.3"},
          # simple_sat: the Ash policy authorizer's pure-Elixir SAT solver, needed by the
          # mounted Billing scope's OrgScope policies + the authored resource's policies.
          {:simple_sat, "~> 0.1"}
        ]
      end

      defp aliases, do: []
    end
    """
  end

  # ------------------------------------------------------------------ config
  defp config_exs do
    """
    import Config

    # <%= module %> — a Samen vertical scaffolded by `mix samen.gen.app`. Mounts the
    # samen_core Billing scope AS-IS, authors the vertical resource, and defines a
    # token-blind aggregate projection.
    config :<%= otp_app %>,
      ecto_repos: [<%= module %>.Repo],
      ash_domains: [<%= module %>.Billing, <%= module %>.Vertical, <%= module %>.Aggregate]

    # The samen_core verifiers discover domains from :samen_core :ash_domains. Register
    # this app's domains so the gate scans the mounted Billing scope + the vertical
    # resource + the token-blind aggregate plane.
    config :samen_core, :ash_domains, [
      <%= module %>.Billing,
      <%= module %>.Vertical,
      <%= module %>.Aggregate
    ]

    config :ash, disable_async?: true

    config :<%= otp_app %>, <%= module %>.Repo,
      migration_primary_key: [name: :id, type: :binary_id]

    # Reveal-grant + non_pii + verify + vault + tnt_record repos: wire this app's repo.
    config :samen_core, :reveal_grant, Samen.Reveal.Grants
    config :samen_core, :reveal_grant_repo, <%= module %>.Repo
    config :samen_core, :non_pii_repo, <%= module %>.Repo
    config :samen_core, :verify_repo, <%= module %>.Repo
    config :samen_core, :vault_repo, <%= module %>.Repo
    config :samen_core, :tnt_record_repo, <%= module %>.Repo

    # T4.5 aggregate-privacy floors. samen_core defaults are k=5/l=2; a fresh app's
    # dogfood datasets are small, so — exactly as demo/driftwood/pawchart — use a
    # small-but-non-trivial floor (k=2/l=2): a count-of-one cohort still suppresses.
    # Production hosts keep k=5.
    config :samen_core, :k_anonymity_min_cohort, 2
    config :samen_core, :l_diversity_min_distinct, 2

    # The query-budget ledger repo (SCAFFOLD — accounting only, WARN-not-enforce).
    config :samen_core, :query_budget_ledger_repo, <%= module %>.Repo

    # Oban: the canonical queue taxonomy (reused verbatim from the substrate convention).
    config :samen_core, Oban,
      repo: <%= module %>.Repo,
      queues: [
        default: 10,
        rollups: 2,
        webhooks_out: 5,
        erasure: 1,
        maintenance: 1,
        reveal: 5
      ],
      plugins: [
        {Oban.Plugins.Pruner, max_age: 7 * 24 * 60 * 60}
      ]

    import_config "\#{config_env()}.exs"
    """
  end

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

  defp test_exs do
    """
    import Config

    config :<%= otp_app %>, <%= module %>.Repo,
      username: System.get_env("USER") || "postgres",
      password: "",
      hostname: "localhost",
      database: "<%= otp_app %>_test",
      pool: Ecto.Adapters.SQL.Sandbox,
      pool_size: 10

    config :logger, level: :warning

    config :<%= otp_app %>, start_repo?: false

    # In test: manual Oban (job rows visible but not auto-executed) + no plugins.
    config :samen_core, Oban, testing: :manual, plugins: false
    """
  end

  # ------------------------------------------------------------------ lib
  defp application_ex do
    """
    defmodule <%= module %>.Application do
      @moduledoc "<%= module %> OTP application (scaffolded by mix samen.gen.app)."
      use Application

      @impl true
      def start(_type, _args) do
        children =
          if Application.get_env(:<%= otp_app %>, :start_repo?, true) do
            [<%= module %>.Repo, {Oban, Application.fetch_env!(:samen_core, Oban)}]
          else
            []
          end

        opts = [strategy: :one_for_one, name: <%= module %>.Supervisor]
        Supervisor.start_link(children, opts)
      end
    end
    """
  end

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

  defp billing_ex do
    """
    defmodule <%= module %>.Billing do
      @moduledoc \"\"\"
      <%= module %>'s Billing domain — the samen_core Billing scope MOUNTED AS-IS.

      ONE `use Samen.Scopes.Billing` expands into the eight host-owned Billing resources
      (Customer🔒 → Subscription → Plan/Price → Invoice → Payment → Usage → Entitlement)
      with ZERO vertical billing code and ZERO reshape — the doc's EASY ADDITIVE case.

      The `abbrevs:` override takes FRESH abbrevs derived from this app's 2-letter prefix,
      reserved in the GLOBAL registry (samen_core/priv/abbrev_registry.json) by the
      generator. The scope defaults (bcu/bsb/…) are already owned by the demo mount — the
      global-registry reality every mount documents.
      \"\"\"
      use Ash.Domain, validate_config_inclusion?: false

      use Samen.Scopes.Billing,
        otp_app: :<%= otp_app %>,
        repo: <%= module %>.Repo,
        namespace: <%= module %>.Billing,
        abbrevs: %{
          customer: "<%= bc %>",
          subscription: "<%= bs %>",
          plan: "<%= bl %>",
          price: "<%= bp %>",
          invoice: "<%= bi %>",
          payment: "<%= by %>",
          usage: "<%= bu %>",
          entitlement: "<%= be %>",
          subscription_event: "<%= bv %>"
        }
    end
    """
  end

  defp vertical_ex do
    """
    defmodule <%= module %>.Vertical do
      @moduledoc \"\"\"
      <%= module %>'s vertical-authored domain — the "20%" this app writes itself.

      Ships ONE authored resource, `<%= module %>.Vertical.Record`, a Tier-3 code
      composition (`use Samen.Resource`, abbrev `<%= abbrev %>`) that inherits the ENTIRE
      substrate — abbrev storage, vault routing, masking, OrgScope, catalog parity, audit,
      crypto-shred — with no vertical infrastructure code. It carries a SCALAR pii_ vault
      field (`pii_<%= abbrev %>_secret`) to exercise the vault/mask/reveal path end to end.
      \"\"\"
      use Ash.Domain, validate_config_inclusion?: false

      resources do
        resource(<%= module %>.Vertical.Record)
      end
    end

    defmodule <%= module %>.Vertical.Record do
      @moduledoc \"\"\"
      The authored vertical record (abbrev `<%= abbrev %>`), with:

        * `pii_<%= abbrev %>_secret` — a SCALAR pii_ vault field
          (`pii_attribute :secret, :string, vault: :pii_secret`). Masked `••••` by default;
          plaintext only via `:reveal_<%= abbrev %>` under a distinct-party grant;
          crypto-shreddable with the record. The column name is what the storage
          transformer produces from the abbrev + the pii_ scalar rule.
        * `name` / `segment` — plain non-PII columns (`segment` is the aggregate cohort key).
        * OrgScope on every action.
      \"\"\"
      use Samen.Resource,
        otp_app: :<%= otp_app %>,
        domain: <%= module %>.Vertical,
        data_layer: AshPostgres.DataLayer,
        authorizers: [Ash.Policy.Authorizer],
        abbrev: "<%= abbrev %>"

      postgres do
        table("<%= resource_table %>")
        repo(<%= module %>.Repo)
      end

      attributes do
        attribute(:name, :string, public?: true)
        attribute(:segment, :string, public?: true)
      end

      pii do
        vault(:pii_secret)
        pii_attribute(:secret, :string, vault: :pii_secret)
        reveal(:reveal_<%= abbrev %>)
      end

      # The inherited two-key-class PII-resolution rule on all reads.
      preparations do
        prepare(Samen.Api.PiiResolution)
      end

      actions do
        defaults([:read, :destroy, create: :*, update: :*])

        action :reveal_<%= abbrev %>, :map do
          argument(:actor_id, :string, allow_nil?: false)
          argument(:subject_id, :string, allow_nil?: false)

          run(fn input, _ctx ->
            ctx = %Samen.Reveal.Context{
              actor: input.arguments.actor_id,
              subject_id: input.arguments.subject_id,
              resource: __MODULE__,
              action: :reveal_<%= abbrev %>,
              label: :secret
            }

            if Samen.Reveal.grant_checker().granted?(ctx) do
              {:ok, %{status: "granted", subject_id: input.arguments.subject_id}}
            else
              {:error, :denied}
            end
          end)
        end
      end

      policies do
        policy action_type([:read, :create, :update, :destroy]) do
          authorize_if(Samen.Policy.OrgScope)
        end

        policy action(:reveal_<%= abbrev %>) do
          authorize_if(always())
        end
      end
    end
    """
  end

  defp aggregate_ex do
    """
    defmodule <%= module %>.Aggregate do
      @moduledoc \"\"\"
      <%= module %>'s token-blind aggregate plane (doc §control "Cross-tenant views run on
      a separate token-blind actor"). The SEPARATE, DEFAULT-DENY Ash domain whose only
      admissible actor is the singleton `Samen.Aggregate.Actor`. Inherited machinery — this
      app writes no aggregate infrastructure, only the projection.
      \"\"\"
      use Ash.Domain, validate_config_inclusion?: false

      resources do
        resource(<%= module %>.Aggregate.RecordCountBySegment)
      end
    end

    defmodule <%= module %>.Aggregate.RecordCountBySegment do
      @moduledoc \"\"\"
      Cross-tenant RECORD COUNT by segment. A `use Samen.Aggregate.Resource` projection
      over the vault-excluded `<%= agg_table %>` summary table. Every column is bounded /
      non-PII: `segment` (a coarse bucket, NOT a subject), `tenant_count` (cohort size for
      k-anon), `record_count` (a count). NO pii_attribute, NO vault, NO PII relationship —
      the C7 verifier enforces this at compile time. Cross-tenant (no org boundary).
      \"\"\"
      use Samen.Aggregate.Resource,
        otp_app: :<%= otp_app %>,
        domain: <%= module %>.Aggregate,
        data_layer: AshPostgres.DataLayer,
        authorizers: [Ash.Policy.Authorizer],
        abbrev: "<%= agg_abbrev %>"

      postgres do
        table("<%= agg_table %>")
        repo(<%= module %>.Repo)
      end

      attributes do
        attribute(:org_id, :uuid, public?: true, allow_nil?: true)
        attribute(:segment, :string, public?: true, allow_nil?: false)
        attribute(:tenant_count, :integer, public?: true, default: 0)
        attribute(:record_count, :integer, public?: true, default: 0)
        attribute(:refreshed_at, :utc_datetime, public?: true)
      end

      actions do
        defaults([:read])
      end

      # DEFAULT DENY. Only the token-blind aggregate actor is admitted. No fallthrough.
      policies do
        policy always() do
          authorize_if(Samen.Policy.AggregateActorOnly)
        end
      end

      @doc \"\"\"
      The T4.5 cohort spec: the segment cohort's SIZE (k-anonymity) is `tenant_count`. The
      RELEASABLE value `record_count` is suppressed when `tenant_count < k`.
      \"\"\"
      def aggregate_cohort_spec do
        %Samen.Aggregate.CohortSpec{
          cohort_key_columns: [:segment],
          cohort_count_column: :tenant_count,
          distinct_sensitive_column: nil,
          value_columns: [:record_count],
          sensitive_attribute: nil
        }
      end
    end
    """
  end

  # ------------------------------------------------------------------ substrate migrations
  defp m_ash_functions do
    ~S'''
    defmodule <%= module %>.Repo.Migrations.AshFunctions do
      @moduledoc "Installs AshPostgres helper functions."
      use Ecto.Migration

      def up do
        execute("""
        CREATE OR REPLACE FUNCTION ash_elixir_or(left BOOLEAN, in right ANYCOMPATIBLE, out f1 ANYCOMPATIBLE)
        AS $$ SELECT COALESCE(NULLIF($1, FALSE), $2) $$
        LANGUAGE SQL SET search_path = '' IMMUTABLE;
        """)

        execute("""
        CREATE OR REPLACE FUNCTION ash_elixir_or(left ANYCOMPATIBLE, in right ANYCOMPATIBLE, out f1 ANYCOMPATIBLE)
        AS $$ SELECT COALESCE($1, $2) $$
        LANGUAGE SQL SET search_path = '' IMMUTABLE;
        """)

        execute("""
        CREATE OR REPLACE FUNCTION ash_elixir_and(left BOOLEAN, in right ANYCOMPATIBLE, out f1 ANYCOMPATIBLE) AS $$
          SELECT CASE WHEN $1 IS TRUE THEN $2 ELSE $1 END $$
        LANGUAGE SQL SET search_path = '' IMMUTABLE;
        """)

        execute("""
        CREATE OR REPLACE FUNCTION ash_elixir_and(left ANYCOMPATIBLE, in right ANYCOMPATIBLE, out f1 ANYCOMPATIBLE) AS $$
          SELECT CASE WHEN $1 IS NOT NULL THEN $2 ELSE $1 END $$
        LANGUAGE SQL SET search_path = '' IMMUTABLE;
        """)

        execute("""
        CREATE OR REPLACE FUNCTION ash_trim_whitespace(arr text[])
        RETURNS text[] AS $$
        DECLARE
            start_index INT = 1;
            end_index INT = array_length(arr, 1);
        BEGIN
            WHILE start_index <= end_index AND arr[start_index] = '' LOOP
                start_index := start_index + 1;
            END LOOP;
            WHILE end_index >= start_index AND arr[end_index] = '' LOOP
                end_index := end_index - 1;
            END LOOP;
            IF start_index > end_index THEN
                RETURN ARRAY[]::text[];
            ELSE
                RETURN arr[start_index : end_index];
            END IF;
        END; $$
        LANGUAGE plpgsql SET search_path = '' IMMUTABLE;
        """)

        execute("""
        CREATE OR REPLACE FUNCTION ash_raise_error(json_data jsonb)
        RETURNS BOOLEAN AS $$
        BEGIN
            RAISE EXCEPTION 'ash_error: %', json_data::text;
            RETURN NULL;
        END;
        $$ LANGUAGE plpgsql STABLE SET search_path = '';
        """)

        execute("""
        CREATE OR REPLACE FUNCTION ash_raise_error(json_data jsonb, type_signal ANYCOMPATIBLE)
        RETURNS ANYCOMPATIBLE AS $$
        BEGIN
            RAISE EXCEPTION 'ash_error: %', json_data::text;
            RETURN NULL;
        END;
        $$ LANGUAGE plpgsql STABLE SET search_path = '';
        """)

        execute("""
        CREATE OR REPLACE FUNCTION ash_required(value ANYCOMPATIBLE, payload jsonb)
        RETURNS ANYCOMPATIBLE AS $$
        BEGIN
          IF value IS NULL THEN
            RETURN ash_raise_error(payload, value);
          END IF;
          RETURN value;
        END;
        $$ LANGUAGE plpgsql STABLE SET search_path = '';
        """)

        execute("""
        CREATE OR REPLACE FUNCTION uuid_generate_v7()
        RETURNS UUID AS $$
        DECLARE
          timestamp    TIMESTAMPTZ;
          microseconds INT;
        BEGIN
          timestamp    = clock_timestamp();
          microseconds = (cast(extract(microseconds FROM timestamp)::INT - (floor(extract(milliseconds FROM timestamp))::INT * 1000) AS DOUBLE PRECISION) * 4.096)::INT;
          RETURN encode(
            set_byte(set_byte(
                overlay(uuid_send(gen_random_uuid()) placing substring(int8send(floor(extract(epoch FROM timestamp) * 1000)::BIGINT) FROM 3) FROM 1 FOR 6),
                6, (b'0111' || (microseconds >> 8)::bit(4))::bit(8)::int),
              7, microseconds::bit(8)::int), 'hex')::UUID;
        END
        $$ LANGUAGE PLPGSQL SET search_path = '' VOLATILE;
        """)
      end

      def down do
        execute(
          "DROP FUNCTION IF EXISTS uuid_generate_v7(), ash_raise_error(jsonb), ash_raise_error(jsonb, ANYCOMPATIBLE), ash_elixir_and(BOOLEAN, ANYCOMPATIBLE), ash_elixir_and(ANYCOMPATIBLE, ANYCOMPATIBLE), ash_elixir_or(ANYCOMPATIBLE, ANYCOMPATIBLE), ash_elixir_or(BOOLEAN, ANYCOMPATIBLE), ash_trim_whitespace(text[]), ash_required(ANYCOMPATIBLE, jsonb)"
        )
      end
    end
    '''
  end

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

  defp m_vault do
    """
    defmodule <%= module %>.Repo.Migrations.VaultTables do
      @moduledoc "Creates the pii_vault table."
      use Ecto.Migration

      def up do
        create table(:pii_vault, primary_key: false) do
          add(:token, :string, null: false, primary_key: true)
          add(:subject_id, :string, null: false)
          add(:vault_name, :string, null: false)
          add(:field_name, :string, null: false)
          add(:ciphertext, :binary, null: false)
          add(:label, :string)
          add(:state, :string, null: false, default: "active")
          add(:erased_at, :utc_datetime_usec)
          timestamps(type: :utc_datetime_usec)
        end

        create(index(:pii_vault, [:subject_id]))
        create(index(:pii_vault, [:subject_id, :vault_name]))
        create(index(:pii_vault, [:subject_id, :state]))
      end

      def down, do: drop(table(:pii_vault))
    end
    """
  end

  defp m_reveal do
    ~S'''
    defmodule <%= module %>.Repo.Migrations.RevealGrants do
      @moduledoc "T1.6 reveal-grant tables."
      use Ecto.Migration

      def up do
        create table(:rvq_reveal_request, primary_key: false) do
          add(:rvq_id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()"))
          add(:rvq_subject_id, :string, null: false)
          add(:rvq_requestor_id, :string, null: false)
          add(:rvq_reason, :text, null: false)
          add(:rvq_resource, :text)
          add(:rvq_action, :text)
          add(:rvq_status, :text, null: false, default: "pending")
          timestamps(type: :utc_datetime_usec, inserted_at: :rvq_inserted_at, updated_at: :rvq_updated_at)
        end

        create(index(:rvq_reveal_request, [:rvq_subject_id]))
        create(index(:rvq_reveal_request, [:rvq_requestor_id]))

        create table(:rvg_reveal_grant, primary_key: false) do
          add(:rvg_id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()"))
          add(:rvg_request_id, :uuid, null: false)
          add(:rvg_subject_id, :string, null: false)
          add(:rvg_requestor_id, :string, null: false)
          add(:rvg_granted_by, :string, null: false)
          add(:rvg_reason, :text, null: false)
          add(:rvg_resource, :text)
          add(:rvg_action, :text)
          add(:rvg_expires_at, :utc_datetime_usec, null: false)
          add(:rvg_revoked_at, :utc_datetime_usec)
          timestamps(type: :utc_datetime_usec, inserted_at: :rvg_inserted_at, updated_at: :rvg_updated_at)
        end

        create(
          constraint(:rvg_reveal_grant, :rvg_distinct_party,
            check: "rvg_granted_by <> rvg_requestor_id"
          )
        )

        create(index(:rvg_reveal_grant, [:rvg_subject_id]))
        create(index(:rvg_reveal_grant, [:rvg_requestor_id]))
        create(index(:rvg_reveal_grant, [:rvg_request_id]))

        create table(:rvl_reveal_audit, primary_key: false) do
          add(:rvl_id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()"))
          add(:rvl_event, :text, null: false)
          add(:rvl_subject_id, :string, null: false)
          add(:rvl_actor_id, :string)
          add(:rvl_request_id, :uuid)
          add(:rvl_grant_id, :uuid)
          add(:rvl_detail, :text)
          add(:rvl_recorded_at, :utc_datetime_usec, null: false, default: fragment("now()"))
        end

        create(index(:rvl_reveal_audit, [:rvl_subject_id]))
      end

      def down do
        drop(table(:rvl_reveal_audit))
        drop(constraint(:rvg_reveal_grant, :rvg_distinct_party))
        drop(table(:rvg_reveal_grant))
        drop(table(:rvq_reveal_request))
      end
    end
    '''
  end

  defp m_erasure do
    ~S'''
    defmodule <%= module %>.Repo.Migrations.Erasure do
      @moduledoc "T1.7 crypto-shred: non_pii! registry + erasure report table."
      use Ecto.Migration

      def up do
        create table(:npi_non_pii, primary_key: false) do
          add(:npi_id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()"))
          add(:npi_table_name, :text, null: false)
          add(:npi_column_name, :text, null: false)
          add(:npi_cleared_by, :text, null: false)
          add(:npi_reviewed_by, :text, null: false)
          add(:npi_reason, :text, null: false)
          add(:npi_subject_column, :text, null: false)
          add(:npi_redaction, :text, null: false, default: "[REDACTED]")
          add(:npi_registered_at, :utc_datetime_usec, null: false, default: fragment("now()"))
        end

        create(
          unique_index(:npi_non_pii, [:npi_table_name, :npi_column_name],
            name: "npi_non_pii_table_column_index"
          )
        )

        create table(:era_erasure_report, primary_key: false) do
          add(:era_id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()"))
          add(:era_subject_id, :string, null: false)
          add(:era_attestation_id, :text)
          add(:era_outcome, :text, null: false)
          add(:era_tiers, :map, null: false)
          add(:era_vault_rows_sealed, :integer, null: false, default: 0)
          add(:era_non_pii_rows_redacted, :integer, null: false, default: 0)
          add(:era_recorded_at, :utc_datetime_usec, null: false, default: fragment("now()"))
        end

        create(index(:era_erasure_report, [:era_subject_id]))
      end

      def down do
        drop(index(:era_erasure_report, [:era_subject_id]))
        drop(table(:era_erasure_report))
        drop(constraint(:npi_non_pii, "npi_non_pii_table_column_index"))
        drop(table(:npi_non_pii))
      end
    end
    '''
  end

  defp m_catalog do
    """
    defmodule <%= module %>.Repo.Migrations.CatalogTables do
      @moduledoc \"\"\"
      Bootstraps the catalog tables (tam_table / fld_field) BEFORE any migration that calls
      catalog_sync/1 (aud_event, app_resources).
      \"\"\"
      use Samen.Migration

      def up, do: create_catalog_tables()

      def down do
        drop(table(:fld_field))
        drop(table(:tam_table))
      end
    end
    """
  end

  defp m_aud_event do
    ~S'''
    defmodule <%= module %>.Repo.Migrations.AudEvent do
      @moduledoc "T2.2: the aud_event append-only event/audit tier."
      use Ecto.Migration

      @app_role Application.compile_env(:<%= otp_app %>, :aud_event_app_role, "clank")

      @resource "Samen.AuditEvent"
      @table "aud_event"
      @fields [
        {"aud_id", "id", "UUID"},
        {"aud_event_type", "event_type", "String"},
        {"aud_subject_id", "subject_id", "String"},
        {"aud_actor_id", "actor_id", "String"},
        {"aud_correlation_id", "correlation_id", "UUID"},
        {"aud_detail", "detail", "String"},
        {"aud_occurred_at", "occurred_at", "UTCDatetime"}
      ]

      def up do
        execute """
        CREATE TABLE aud_event (
          aud_id             UUID        NOT NULL DEFAULT gen_random_uuid(),
          aud_event_type     TEXT        NOT NULL,
          aud_subject_id     TEXT,
          aud_actor_id       TEXT,
          aud_correlation_id UUID,
          aud_detail         TEXT,
          aud_occurred_at    TIMESTAMPTZ NOT NULL,
          PRIMARY KEY (aud_id, aud_occurred_at)
        ) PARTITION BY RANGE (aud_occurred_at)
        """,
        "DROP TABLE IF EXISTS aud_event"

        execute """
        CREATE TABLE IF NOT EXISTS aud_event_y2026m07
        PARTITION OF aud_event
        FOR VALUES FROM ('2026-07-01 00:00:00+00') TO ('2026-08-01 00:00:00+00')
        """,
        "DROP TABLE IF EXISTS aud_event_y2026m07"

        execute """
        CREATE INDEX aud_event_brin_occurred_at
        ON aud_event USING BRIN (aud_occurred_at)
        """,
        "DROP INDEX IF EXISTS aud_event_brin_occurred_at"

        execute """
        CREATE OR REPLACE FUNCTION aud_event_enforce_append_only()
        RETURNS TRIGGER LANGUAGE plpgsql AS $$
        BEGIN
          RAISE EXCEPTION 'aud_event is append-only: UPDATE and DELETE are not permitted. '
            'Event id: %, type: %',
            COALESCE(OLD.aud_id::text, '?'),
            COALESCE(OLD.aud_event_type, '?');
        END;
        $$
        """,
        "DROP FUNCTION IF EXISTS aud_event_enforce_append_only()"

        execute """
        CREATE TRIGGER aud_event_append_only_tg
        BEFORE UPDATE OR DELETE ON aud_event
        FOR EACH ROW EXECUTE FUNCTION aud_event_enforce_append_only()
        """,
        "DROP TRIGGER IF EXISTS aud_event_append_only_tg ON aud_event"

        execute """
        REVOKE UPDATE, DELETE ON aud_event FROM #{@app_role}
        """,
        """
        GRANT UPDATE, DELETE ON aud_event TO #{@app_role}
        """

        execute """
        INSERT INTO tam_table (tam_table_name, tam_resource)
        VALUES ('#{@table}', '#{@resource}')
        ON CONFLICT (tam_table_name) DO NOTHING
        """,
        """
        DELETE FROM tam_table WHERE tam_table_name = '#{@table}'
        """

        for {col, logical, type} <- @fields do
          execute """
          INSERT INTO fld_field (fld_table_name, fld_column_name, fld_logical_name, fld_type)
          VALUES ('#{@table}', '#{col}', '#{logical}', '#{type}')
          ON CONFLICT (fld_table_name, fld_column_name) DO NOTHING
          """,
          """
          DELETE FROM fld_field
          WHERE fld_table_name = '#{@table}' AND fld_column_name = '#{col}'
          """
        end
      end

      def down do
        for {col, _logical, _type} <- Enum.reverse(@fields) do
          execute """
          DELETE FROM fld_field
          WHERE fld_table_name = '#{@table}' AND fld_column_name = '#{col}'
          """
        end

        execute "DELETE FROM tam_table WHERE tam_table_name = '#{@table}'"

        execute "GRANT UPDATE, DELETE ON aud_event TO #{@app_role}"
        execute "DROP TRIGGER IF EXISTS aud_event_append_only_tg ON aud_event"
        execute "DROP FUNCTION IF EXISTS aud_event_enforce_append_only()"
        execute "DROP INDEX IF EXISTS aud_event_brin_occurred_at"
        execute "DROP TABLE IF EXISTS aud_event_y2026m07"
        execute "DROP TABLE IF EXISTS aud_event"
      end
    end
    '''
  end

  defp m_migration_meta do
    """
    defmodule <%= module %>.Repo.Migrations.MigrationMeta do
      @moduledoc "T2.4: bootstrap the samen_migration_meta bake-window ledger."
      use Ecto.Migration

      def up do
        execute(
          Samen.Migration.Meta.create_table_sql(),
          Samen.Migration.Meta.drop_table_sql()
        )
      end

      def down, do: execute(Samen.Migration.Meta.drop_table_sql())
    end
    """
  end

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

  defp m_tnt_object_record do
    """
    defmodule <%= module %>.Repo.Migrations.TntObjectRecord do
      @moduledoc "Bootstrap the Tier-2 tables (tnt_object catalog + tnt_record store; T3.9)."
      use Samen.Migration

      def up do
        create_tnt_object_table()
        create_tnt_record_table()
      end

      def down do
        drop(table(:tnt_record))
        drop(table(:tnt_object))
      end
    end
    """
  end

  defp m_app_resources do
    ~S'''
    defmodule <%= module %>.Repo.Migrations.AppResources do
      @moduledoc """
      Creates <%= module %>'s Billing scope (abbrevs <%= bc %>/<%= bs %>/<%= bl %>/<%= bp %>/<%= bi %>/<%= by %>/<%= bu %>/<%= be %>/<%= bv %>)
      mounted AS-IS, the authored vertical table (<%= resource_table %> with the scalar vault
      field pii_<%= abbrev %>_secret), and the token-blind aggregate projection (<%= agg_table %>),
      and catalogs every resource in the SAME migration transaction (ADR-004 catalog-in-tx).
      """
      use Samen.Migration

      @resources [
        <%= module %>.Billing.Customer,
        <%= module %>.Billing.Subscription,
        <%= module %>.Billing.Plan,
        <%= module %>.Billing.Price,
        <%= module %>.Billing.Invoice,
        <%= module %>.Billing.Payment,
        <%= module %>.Billing.Usage,
        <%= module %>.Billing.Entitlement,
        <%= module %>.Billing.SubscriptionEvent,
        <%= module %>.Vertical.Record,
        <%= module %>.Aggregate.RecordCountBySegment
      ]

      def up do
        # ---- Billing scope (Stripe-mirror shape) — mounted AS-IS ----
        create table(:<%= bc %>_customer, primary_key: false) do
          add(:<%= bc %>_stripe_customer_id, :text)
          add(:<%= bc %>_status, :text, default: "active")
          add(:<%= bc %>_currency, :text, default: "USD")
          add(:<%= bc %>_custom, :map, default: fragment("'{}'::jsonb"))
          add(:pii_<%= bc %>_billing_name, :text)
          add(:pii_<%= bc %>_billing_email, :text)
          add(:<%= bc %>_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
          add(:<%= bc %>_org_id, :uuid, null: false)
          add(:<%= bc %>_inserted_at, :utc_datetime, null: false)
          add(:<%= bc %>_updated_at, :utc_datetime, null: false)
        end

        create table(:<%= bl %>_plan, primary_key: false) do
          add(:<%= bl %>_name, :text, null: false)
          add(:<%= bl %>_label, :text)
          add(:<%= bl %>_description, :text)
          add(:<%= bl %>_stripe_plan_id, :text)
          add(:<%= bl %>_interval, :text, default: "monthly")
          add(:<%= bl %>_enabled, :boolean, default: true)
          add(:<%= bl %>_features, :map, default: fragment("'{}'::jsonb"))
          add(:<%= bl %>_custom, :map, default: fragment("'{}'::jsonb"))
          add(:<%= bl %>_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
          add(:<%= bl %>_org_id, :uuid, null: false)
          add(:<%= bl %>_inserted_at, :utc_datetime, null: false)
          add(:<%= bl %>_updated_at, :utc_datetime, null: false)
        end

        create table(:<%= bp %>_price, primary_key: false) do
          add(:<%= bp %>_stripe_price_id, :text)
          add(:<%= bp %>_unit_amount_cents, :integer, null: false)
          add(:<%= bp %>_currency, :text, null: false, default: "USD")
          add(:<%= bp %>_interval, :text, default: "monthly")
          add(:<%= bp %>_active, :boolean, default: true)
          add(:<%= bp %>_custom, :map, default: fragment("'{}'::jsonb"))

          add(
            :<%= bp %>_plan_id,
            references(:<%= bl %>_plan,
              column: :<%= bl %>_id,
              name: "<%= bp %>_price_<%= bp %>_plan_id_fkey",
              type: :uuid,
              prefix: "public"
            )
          )

          add(:<%= bp %>_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
          add(:<%= bp %>_org_id, :uuid, null: false)
          add(:<%= bp %>_inserted_at, :utc_datetime, null: false)
          add(:<%= bp %>_updated_at, :utc_datetime, null: false)
        end

        create table(:<%= bs %>_subscription, primary_key: false) do
          add(:<%= bs %>_stripe_subscription_id, :text)
          add(:<%= bs %>_status, :text, default: "active")
          add(:<%= bs %>_current_period_start, :utc_datetime)
          add(:<%= bs %>_current_period_end, :utc_datetime)
          add(:<%= bs %>_trial_end, :utc_datetime)
          add(:<%= bs %>_cancel_at, :utc_datetime)
          add(:<%= bs %>_cancelled_at, :utc_datetime)
          add(:<%= bs %>_custom, :map, default: fragment("'{}'::jsonb"))

          add(
            :<%= bs %>_customer_id,
            references(:<%= bc %>_customer,
              column: :<%= bc %>_id,
              name: "<%= bs %>_subscription_<%= bs %>_customer_id_fkey",
              type: :uuid,
              prefix: "public"
            )
          )

          add(
            :<%= bs %>_plan_id,
            references(:<%= bl %>_plan,
              column: :<%= bl %>_id,
              name: "<%= bs %>_subscription_<%= bs %>_plan_id_fkey",
              type: :uuid,
              prefix: "public"
            )
          )

          add(:<%= bs %>_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
          add(:<%= bs %>_org_id, :uuid, null: false)
          add(:<%= bs %>_inserted_at, :utc_datetime, null: false)
          add(:<%= bs %>_updated_at, :utc_datetime, null: false)
        end

        create table(:<%= bi %>_invoice, primary_key: false) do
          add(:<%= bi %>_stripe_invoice_id, :text)
          add(:<%= bi %>_status, :text, default: "draft")
          add(:<%= bi %>_amount_due_cents, :integer, default: 0)
          add(:<%= bi %>_amount_paid_cents, :integer, default: 0)
          add(:<%= bi %>_currency, :text, default: "USD")
          add(:<%= bi %>_period_start, :utc_datetime)
          add(:<%= bi %>_period_end, :utc_datetime)
          add(:<%= bi %>_due_date, :utc_datetime)
          add(:<%= bi %>_paid_at, :utc_datetime)
          add(:<%= bi %>_line_items, {:array, :map}, default: fragment("ARRAY[]::jsonb[]"))
          add(:<%= bi %>_custom, :map, default: fragment("'{}'::jsonb"))

          add(
            :<%= bi %>_customer_id,
            references(:<%= bc %>_customer,
              column: :<%= bc %>_id,
              name: "<%= bi %>_invoice_<%= bi %>_customer_id_fkey",
              type: :uuid,
              prefix: "public"
            )
          )

          add(
            :<%= bi %>_subscription_id,
            references(:<%= bs %>_subscription,
              column: :<%= bs %>_id,
              name: "<%= bi %>_invoice_<%= bi %>_subscription_id_fkey",
              type: :uuid,
              prefix: "public"
            )
          )

          add(:<%= bi %>_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
          add(:<%= bi %>_org_id, :uuid, null: false)
          add(:<%= bi %>_inserted_at, :utc_datetime, null: false)
          add(:<%= bi %>_updated_at, :utc_datetime, null: false)
        end

        create table(:<%= by %>_payment, primary_key: false) do
          add(:<%= by %>_stripe_payment_intent_id, :text)
          add(:<%= by %>_status, :text, default: "pending")
          add(:<%= by %>_amount_cents, :integer, null: false)
          add(:<%= by %>_currency, :text, default: "USD")
          add(:<%= by %>_payment_method_type, :text, default: "card")
          add(:<%= by %>_last4, :text)
          add(:<%= by %>_paid_at, :utc_datetime)
          add(:<%= by %>_failure_code, :text)
          add(:<%= by %>_custom, :map, default: fragment("'{}'::jsonb"))

          add(
            :<%= by %>_invoice_id,
            references(:<%= bi %>_invoice,
              column: :<%= bi %>_id,
              name: "<%= by %>_payment_<%= by %>_invoice_id_fkey",
              type: :uuid,
              prefix: "public"
            )
          )

          add(
            :<%= by %>_customer_id,
            references(:<%= bc %>_customer,
              column: :<%= bc %>_id,
              name: "<%= by %>_payment_<%= by %>_customer_id_fkey",
              type: :uuid,
              prefix: "public"
            )
          )

          add(:<%= by %>_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
          add(:<%= by %>_org_id, :uuid, null: false)
          add(:<%= by %>_inserted_at, :utc_datetime, null: false)
          add(:<%= by %>_updated_at, :utc_datetime, null: false)
        end

        create table(:<%= bu %>_usage, primary_key: false) do
          add(:<%= bu %>_metric, :text, null: false)
          add(:<%= bu %>_quantity, :integer, default: 0)
          add(:<%= bu %>_period_start, :utc_datetime)
          add(:<%= bu %>_period_end, :utc_datetime)
          add(:<%= bu %>_reported_at, :utc_datetime)

          add(
            :<%= bu %>_subscription_id,
            references(:<%= bs %>_subscription,
              column: :<%= bs %>_id,
              name: "<%= bu %>_usage_<%= bu %>_subscription_id_fkey",
              type: :uuid,
              prefix: "public"
            )
          )

          add(:<%= bu %>_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
          add(:<%= bu %>_org_id, :uuid, null: false)
          add(:<%= bu %>_inserted_at, :utc_datetime, null: false)
          add(:<%= bu %>_updated_at, :utc_datetime, null: false)
        end

        create table(:<%= be %>_entitlement, primary_key: false) do
          add(:<%= be %>_feature, :text, null: false)
          add(:<%= be %>_granted, :boolean, default: true)
          add(:<%= be %>_expires_at, :utc_datetime)
          add(:<%= be %>_custom, :map, default: fragment("'{}'::jsonb"))

          add(
            :<%= be %>_subscription_id,
            references(:<%= bs %>_subscription,
              column: :<%= bs %>_id,
              name: "<%= be %>_entitlement_<%= be %>_subscription_id_fkey",
              type: :uuid,
              prefix: "public"
            )
          )

          add(
            :<%= be %>_plan_id,
            references(:<%= bl %>_plan,
              column: :<%= bl %>_id,
              name: "<%= be %>_entitlement_<%= be %>_plan_id_fkey",
              type: :uuid,
              prefix: "public"
            )
          )

          add(:<%= be %>_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
          add(:<%= be %>_org_id, :uuid, null: false)
          add(:<%= be %>_inserted_at, :utc_datetime, null: false)
          add(:<%= be %>_updated_at, :utc_datetime, null: false)
        end

        # ---- Subscription-movement ledger (`mov`; ADR-017) — append-only, no PII,
        #      soft id refs (no FK: the immutable ledger outlives its subscription row) ----
        create table(:<%= bv %>_subscription_event, primary_key: false) do
          add(:<%= bv %>_subscription_id, :uuid, null: false)
          add(:<%= bv %>_customer_id, :uuid)
          add(:<%= bv %>_plan_id, :uuid)
          add(:<%= bv %>_from_plan_id, :uuid)
          add(:<%= bv %>_kind, :text, null: false)
          add(:<%= bv %>_mrr_delta_cents, :integer, null: false, default: 0)
          add(:<%= bv %>_mrr_before_cents, :integer, null: false, default: 0)
          add(:<%= bv %>_mrr_after_cents, :integer, null: false, default: 0)
          add(:<%= bv %>_from_status, :text)
          add(:<%= bv %>_to_status, :text)
          add(:<%= bv %>_reason, :text, default: "status_change")
          add(:<%= bv %>_occurred_at, :utc_datetime, null: false)
          add(:<%= bv %>_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
          add(:<%= bv %>_org_id, :uuid, null: false)
          add(:<%= bv %>_inserted_at, :utc_datetime, null: false)
          add(:<%= bv %>_updated_at, :utc_datetime, null: false)
        end

        # ---- Authored vertical table (the "20%") ----
        create table(:<%= resource_table %>, primary_key: false) do
          # Scalar pii_ vault field → column pii_<%= abbrev %>_secret (vt_* token):
          add(:pii_<%= abbrev %>_secret, :text)
          add(:<%= abbrev %>_name, :text)
          add(:<%= abbrev %>_segment, :text)
          add(:<%= abbrev %>_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
          add(:<%= abbrev %>_org_id, :uuid, null: false)
          add(:<%= abbrev %>_inserted_at, :utc_datetime, null: false)
          add(:<%= abbrev %>_updated_at, :utc_datetime, null: false)
        end

        # ---- Token-blind aggregate projection (no pii_ columns) ----
        create table(:<%= agg_table %>, primary_key: false) do
          add(:<%= agg_abbrev %>_segment, :text, null: false)
          add(:<%= agg_abbrev %>_tenant_count, :integer, default: 0)
          add(:<%= agg_abbrev %>_record_count, :integer, default: 0)
          add(:<%= agg_abbrev %>_refreshed_at, :utc_datetime)
          add(:<%= agg_abbrev %>_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
          add(:<%= agg_abbrev %>_org_id, :uuid)
          add(:<%= agg_abbrev %>_inserted_at, :utc_datetime, null: false)
          add(:<%= agg_abbrev %>_updated_at, :utc_datetime, null: false)
        end

        # ---- catalog every resource in THIS transaction ----
        catalog_sync(@resources)
      end

      def down do
        catalog_sync_down(@resources)

        drop(table(:<%= agg_table %>))
        drop(table(:<%= resource_table %>))

        drop(table(:<%= bv %>_subscription_event))

        drop(constraint(:<%= be %>_entitlement, "<%= be %>_entitlement_<%= be %>_plan_id_fkey"))
        drop(constraint(:<%= be %>_entitlement, "<%= be %>_entitlement_<%= be %>_subscription_id_fkey"))
        drop(table(:<%= be %>_entitlement))

        drop(constraint(:<%= bu %>_usage, "<%= bu %>_usage_<%= bu %>_subscription_id_fkey"))
        drop(table(:<%= bu %>_usage))

        drop(constraint(:<%= by %>_payment, "<%= by %>_payment_<%= by %>_customer_id_fkey"))
        drop(constraint(:<%= by %>_payment, "<%= by %>_payment_<%= by %>_invoice_id_fkey"))
        drop(table(:<%= by %>_payment))

        drop(constraint(:<%= bi %>_invoice, "<%= bi %>_invoice_<%= bi %>_subscription_id_fkey"))
        drop(constraint(:<%= bi %>_invoice, "<%= bi %>_invoice_<%= bi %>_customer_id_fkey"))
        drop(table(:<%= bi %>_invoice))

        drop(constraint(:<%= bs %>_subscription, "<%= bs %>_subscription_<%= bs %>_plan_id_fkey"))
        drop(constraint(:<%= bs %>_subscription, "<%= bs %>_subscription_<%= bs %>_customer_id_fkey"))
        drop(table(:<%= bs %>_subscription))

        drop(constraint(:<%= bp %>_price, "<%= bp %>_price_<%= bp %>_plan_id_fkey"))
        drop(table(:<%= bp %>_price))

        drop(table(:<%= bl %>_plan))
        drop(table(:<%= bc %>_customer))
      end
    end
    '''
  end

  # ------------------------------------------------------------------ priv scripts
  defp ci_bootstrap do
    """
    # <%= module %> ci.sh bootstrap (run under MIX_ENV=test): recreate + migrate the
    # <%= otp_app %>_test DB so the standalone verifier tasks (which query the LIVE DB) have a
    # fully-migrated schema. Idempotent.

    alias <%= module %>.Repo

    kms_key_dir =
      Path.join(System.tmp_dir!(), "<%= otp_app %>_keystore_ci_\#{System.system_time(:nanosecond)}")

    File.rm_rf!(kms_key_dir)
    Application.put_env(:samen_core, :kms_key_dir, kms_key_dir)

    _ = Ecto.Adapters.Postgres.storage_down(Repo.config())
    :ok = Ecto.Adapters.Postgres.storage_up(Repo.config())

    {:ok, _} = Repo.start_link()
    Ecto.Migrator.run(Repo, :up, all: true)

    IO.puts("<%= otp_app %> ci bootstrap: DB migrated")
    """
  end

  defp anti_tautology_probe do
    """
    # Anti-tautology probe — the pii_<%= abbrev %>_secret VAULT PATH (T6.4 generated red path).
    #
    # Guarantee under probe: the record vault round-trip (test/record_vault_test.exs) asserts
    # (a) the raw pii_<%= abbrev %>_secret column holds an opaque `vt_` token, NOT the plaintext,
    # and (b) a normal Ash read returns %Samen.Masked{}. This probe SABOTAGES the on-disk
    # column with the plaintext and confirms the assertions FLIP to failing, then REVERTS and
    # confirms green — proving the assertions are bound to REAL on-disk vault behaviour.
    #
    # Run:  MIX_ENV=test mix run priv/anti_tautology_probe.exs
    # Exit: 0 only if the flip was confirmed AND the revert restored green. System.halt(1)
    #       otherwise — a probe that cannot flip is a tautology and must fail.

    alias <%= module %>.Repo

    kms_key_dir =
      Path.join(System.tmp_dir!(), "<%= otp_app %>_probe_kms_\#{System.system_time(:nanosecond)}")

    File.rm_rf!(kms_key_dir)
    Application.put_env(:samen_core, :kms_key_dir, kms_key_dir)

    _ = Ecto.Adapters.Postgres.storage_down(Repo.config())
    :ok = Ecto.Adapters.Postgres.storage_up(Repo.config())
    {:ok, _} = Repo.start_link()
    Ecto.Migrator.run(Repo, :up, all: true)

    org = "00000000-0000-0000-0000-0000000000c9"
    plaintext = "PROBE-<%= abbrev %>-SECRET-985"

    record =
      <%= module %>.Vertical.Record
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: org, name: "ProbeRecord", segment: "alpha", secret: plaintext},
        authorize?: false
      )
      |> Ash.create!()

    id_dumped = Ecto.UUID.dump!(to_string(record.id))

    raw_column = fn ->
      %{rows: [[raw]]} =
        Ecto.Adapters.SQL.query!(
          Repo,
          "SELECT pii_<%= abbrev %>_secret FROM <%= resource_table %> WHERE <%= abbrev %>_id = $1",
          [id_dumped]
        )

      raw
    end

    assertions_hold? = fn ->
      raw = raw_column.()
      is_binary(raw) and raw != plaintext and String.starts_with?(raw, "vt_")
    end

    IO.puts("== anti-tautology probe: pii_<%= abbrev %>_secret vault path ==")

    original_token = raw_column.()
    baseline = assertions_hold?.()
    IO.puts("baseline (real vault): raw=\#{inspect(original_token)}")
    IO.puts("baseline assertions hold? \#{baseline}")

    unless baseline do
      IO.puts("FAIL: baseline did not hold — the vault path is broken, not a valid probe.")
      System.halt(1)
    end

    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE <%= resource_table %> SET pii_<%= abbrev %>_secret = $1 WHERE <%= abbrev %>_id = $2",
      [plaintext, id_dumped]
    )

    sabotaged = assertions_hold?.()
    IO.puts("\\nsabotage (plaintext written to column): raw=\#{inspect(raw_column.())}")
    IO.puts("sabotaged assertions hold? \#{sabotaged}  (MUST be false — the flip)")

    if sabotaged do
      IO.puts("FAIL: assertions STILL held with plaintext on disk — the test is a TAUTOLOGY.")
      System.halt(1)
    end

    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE <%= resource_table %> SET pii_<%= abbrev %>_secret = $1 WHERE <%= abbrev %>_id = $2",
      [original_token, id_dumped]
    )

    reverted = assertions_hold?.()
    IO.puts("\\nrevert (real vault token restored): raw=\#{inspect(raw_column.())}")
    IO.puts("reverted assertions hold? \#{reverted}  (MUST be true — green again)")

    unless reverted do
      IO.puts("FAIL: revert did not restore the guarantee.")
      System.halt(1)
    end

    IO.puts("\\nRESULT: PROBE CONFIRMED — the red-path assertions FLIPPED under sabotage and")
    IO.puts("recovered on revert. The <%= abbrev %>_secret vault round-trip test is NON-vacuous.")
    File.rm_rf!(kms_key_dir)
    """
  end

  # ------------------------------------------------------------------ test
  defp test_helper do
    """
    # Fresh KMS keystore + migrated DB before the suite (mirrors ci_bootstrap).
    kms_key_dir =
      Path.join(System.tmp_dir!(), "<%= otp_app %>_keystore_test_\#{System.system_time(:nanosecond)}")

    File.rm_rf!(kms_key_dir)
    Application.put_env(:samen_core, :kms_key_dir, kms_key_dir)

    alias <%= module %>.Repo

    _ = Ecto.Adapters.Postgres.storage_down(Repo.config())
    :ok = Ecto.Adapters.Postgres.storage_up(Repo.config())

    {:ok, _} = Repo.start_link()
    Ecto.Migrator.run(Repo, :up, all: true)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)

    ExUnit.start()
    """
  end

  defp data_case do
    """
    defmodule <%= module %>.DataCase do
      @moduledoc "ExUnit case template for database-backed <%= module %> tests."
      use ExUnit.CaseTemplate

      using do
        quote do
          alias <%= module %>.Repo
          import <%= module %>.DataCase
        end
      end

      setup do
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(<%= module %>.Repo)
        Ecto.Adapters.SQL.Sandbox.mode(<%= module %>.Repo, {:shared, self()})
        :ok
      end
    end
    """
  end

  defp record_vault_test do
    ~S'''
    defmodule <%= module %>.RecordVaultTest do
      @moduledoc """
      The GENERATED red path (T6.4): the authored resource's scalar vault field round-trip.

      Asserts, against the LIVE DB, that:

        * the raw `pii_<%= abbrev %>_secret` column holds an opaque `vt_` vault token, NOT the
          plaintext (the leak the guarantee forbids), and
        * a normal Ash read returns a `%Samen.Masked{}` (default-masked), not the plaintext.

      The paired priv/anti_tautology_probe.exs proves these assertions are non-vacuous by
      sabotaging the on-disk column and confirming the flip.
      """
      use <%= module %>.DataCase, async: false

      require Ash.Query
      alias <%= module %>.Vertical.Record

      @org "00000000-0000-0000-0000-0000000000a1"
      @plaintext "SECRET-<%= abbrev %>-42"

      test "scalar pii_ field is vaulted on disk and masked on read" do
        record =
          Record
          |> Ash.Changeset.for_create(
            :create,
            %{org_id: @org, name: "R1", segment: "alpha", secret: @plaintext},
            authorize?: false
          )
          |> Ash.create!()

        id_dumped = Ecto.UUID.dump!(to_string(record.id))

        %{rows: [[raw]]} =
          Ecto.Adapters.SQL.query!(
            Repo,
            "SELECT pii_<%= abbrev %>_secret FROM <%= resource_table %> WHERE <%= abbrev %>_id = $1",
            [id_dumped]
          )

        # On disk: an opaque vault token, never the plaintext.
        assert is_binary(raw)
        refute raw == @plaintext
        assert String.starts_with?(raw, "vt_")

        # On read: default-masked (never the plaintext). The vault field must be
        # explicitly selected (it is not loaded by default), then presents %Masked{}.
        read_back =
          Record
          |> Ash.Query.filter(id == ^record.id)
          |> Ash.Query.ensure_selected([:secret])
          |> Ash.read_one!(authorize?: false)

        assert match?(%Samen.Masked{}, read_back.secret),
               "expected %Samen.Masked{}, got: \#{inspect(read_back.secret)}"

        refute to_string(read_back.secret) == @plaintext
      end
    end
    '''
  end

  # ------------------------------------------------------------------ ci.sh
  defp ci_sh do
    ~S'''
    #!/usr/bin/env bash
    # <%= module %> CI gate — the FULL samen_core verifier gate, run against the mounted
    # Billing scope + the authored vertical resource (<%= module %>.Vertical.Record) + the
    # token-blind aggregate plane. Scaffolded by `mix samen.gen.app` (T6.4) —
    # correct-by-construction: green on first run.
    #
    # Exit: 0 = all green, non-zero = first failure.

    set -euo pipefail

    export MIX_ENV="${MIX_ENV:-test}"

    APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    cd "$APP_DIR"

    echo "==> <%= otp_app %> CI gate: starting (MIX_ENV=$MIX_ENV)"

    echo "--- step 1/17: mix compile --warnings-as-errors"
    mix compile --warnings-as-errors
    echo "    PASSED"

    echo "--- step 1a/17: DB bootstrap (migrate)"
    mix run --no-start priv/ci_bootstrap.exs
    echo "    PASSED"

    echo "--- step 1b/17: schema.dict.json drift check"
    COMMITTED_DICT="$APP_DIR/schema.dict.json"
    FRESH_DICT="$(mktemp /tmp/<%= otp_app %>_schema_dict_XXXXXX.json)"
    trap 'rm -f "$FRESH_DICT"' EXIT

    mix samen.catalog.dump --output "$FRESH_DICT"

    if ! diff -q "$COMMITTED_DICT" "$FRESH_DICT" > /dev/null 2>&1; then
      echo "    FAILED: schema.dict.json is stale — run 'mix samen.catalog.dump --output schema.dict.json' and commit."
      diff "$COMMITTED_DICT" "$FRESH_DICT" || true
      exit 1
    fi
    echo "    PASSED (schema.dict.json matches regenerated output)"

    echo "--- step 2/17: mix samen.verify.catalog_parity"
    mix samen.verify.catalog_parity
    echo "    PASSED"

    echo "--- step 3/17: mix samen.verify.prefixes"
    mix samen.verify.prefixes
    echo "    PASSED"

    echo "--- step 4/17: mix samen.verify.pii_reads"
    mix samen.verify.pii_reads
    echo "    PASSED"

    echo "--- step 5/17: mix samen.verify.pii_classify"
    mix samen.verify.pii_classify --baseline "$COMMITTED_DICT"
    echo "    PASSED"

    echo "--- step 6/17: mix samen.verify.no_plaintext_pii"
    mix samen.verify.no_plaintext_pii
    echo "    PASSED"

    echo "--- step 7/17: mix samen.verify.migrations"
    mix samen.verify.migrations
    echo "    PASSED"

    echo "--- step 8/17: mix samen.verify.sink_schema"
    mix samen.verify.sink_schema
    echo "    PASSED"

    echo "--- step 9/17: mix samen.verify.metric_labels"
    mix samen.verify.metric_labels
    echo "    PASSED"

    echo "--- step 10/17: mix samen.verify.vault_declared_parity"
    mix samen.verify.vault_declared_parity
    echo "    PASSED"

    echo "--- step 11/17: mix samen.verify.tnt_catalog"
    mix samen.verify.tnt_catalog
    echo "    PASSED"

    echo "--- step 12/17: mix samen.verify.tnt_boundary"
    mix samen.verify.tnt_boundary
    echo "    PASSED"

    echo "--- step 13/17: mix samen.verify.same_org_fk"
    mix samen.verify.same_org_fk
    echo "    PASSED"

    echo "--- step 14/17: mix samen.verify.no_pii_columns"
    mix samen.verify.no_pii_columns
    echo "    PASSED"

    echo "--- step 15/17: mix samen.verify.aggregate_privacy"
    mix samen.verify.aggregate_privacy
    echo "    PASSED"

    echo "--- step 16/17: mix test (default suite)"
    mix test --warnings-as-errors
    echo "    PASSED"

    echo "--- step 17/17: anti-tautology probe (pii_<%= abbrev %>_secret vault path)"
    mix run priv/anti_tautology_probe.exs
    echo "    PASSED"

    echo ""
    echo "==> <%= otp_app %> CI gate: ALL PASSED"
    '''
  end

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

  defp readme do
    """
    # <%= module %>

    A Samen vertical app scaffolded by `mix samen.gen.app` (T6.4). It mounts the samen_core
    Billing scope AS-IS, authors one vertical resource (`<%= module %>.Vertical.Record`, abbrev
    `<%= abbrev %>`) with a scalar `pii_<%= abbrev %>_secret` vault field, and defines a
    token-blind aggregate projection.

    ## Verifier gate

        MIX_ENV=test bash ci.sh

    Runs the FULL samen_core verifier gate (catalog parity, prefixes, pii_reads, pii_classify,
    no_plaintext_pii, migrations, sink_schema, metric_labels, vault_declared_parity,
    tnt_catalog, tnt_boundary, same_org_fk, no_pii_columns, aggregate_privacy) + the default
    test suite + the anti-tautology probe on the vault path.

    This app is **correct-by-construction**: it passes its own gate on first run.

    ## Abbrevs

    This app's storage abbrevs are permanently reserved in
    `<%= samen_core_path %>/priv/abbrev_registry.json` (the global registry): Billing scope
    (`<%= bc %>/<%= bs %>/<%= bl %>/<%= bp %>/<%= bi %>/<%= by %>/<%= bu %>/<%= be %>`), the
    authored resource (`<%= abbrev %>`), and the aggregate plane (`<%= agg_abbrev %>`).
    """
  end

  # ==================================================================== WS-D D2: --web
  # The RUNNING-product templates (ADR-022). Parametrized ports of the SHIPPED references:
  # pawchart's `pawchart_web/` (endpoint/router/layouts/page_controller/error_html + the
  # Primitives mount) and driftwood's operator namespace (`operator.ex` +
  # `mount_operator_scopes` + the `dpv` movement ledger). Framework code is INHERITED
  # (`Samen.Web.Router` macros, `Samen.Web.Layouts`, every LiveView) — never re-emitted.

  # ------------------------------------------------------------------ mix.exs (web)
  defp mix_exs_web do
    """
    defmodule <%= module %>.MixProject do
      use Mix.Project

      # <%= module %> — a Samen vertical app scaffolded by `mix samen.gen.app` (T6.4 + WS-D D2).
      # Shaped like demo/driftwood/pawchart: mounts the samen_core Billing scope AS-IS,
      # authors one vertical resource (<%= module %>.Vertical.Record) with a pii_ scalar
      # vault field, defines one token-blind aggregate projection, and runs the FULL
      # samen_core verifier gate in its own ci.sh. With the web layer (ADR-022, default ON)
      # it is a RUNNING product: the router mounts the inherited Billing / Notifications /
      # Operator LiveViews from samen_web. Correct-by-construction: green on first
      # `bash ci.sh`, booting on first `mix phx.server`.
      def project do
        [
          app: :<%= otp_app %>,
          version: "0.1.0",
          elixir: "~> 1.18",
          elixirc_paths: elixirc_paths(Mix.env()),
          consolidate_protocols: Mix.env() != :test,
          start_permanent: Mix.env() == :prod,
          deps: deps(),
          aliases: aliases()
        ]
      end

      def application do
        [
          extra_applications: [:logger],
          mod: {<%= module %>.Application, []}
        ]
      end

      defp elixirc_paths(:test), do: ["lib", "test/support"]
      defp elixirc_paths(_), do: ["lib"]

      defp deps do
        [
          {:samen_core, path: "<%= samen_core_path %>"},
          # ADR-009 — the framework UI library. The router mounts the inherited
          # Billing/Notifications/Operator LiveViews from samen_web, so the entire
          # inherited product UI is framework-level, not per-vertical.
          {:samen_web, path: "<%= samen_web_path %>"},
          {:phoenix, "~> 1.7"},
          {:phoenix_live_view, "~> 1.0"},
          {:phoenix_html, "~> 4.1"},
          # Bandit: the HTTP adapter behind <%= module %>Web.Endpoint.
          {:bandit, "~> 1.0"},
          {:phoenix_pubsub, "~> 2.1"},
          {:jason, "~> 1.4"},
          {:stream_data, "~> 1.3"},
          # simple_sat: the Ash policy authorizer's pure-Elixir SAT solver, needed by the
          # mounted Billing scope's OrgScope policies + the authored resource's policies.
          {:simple_sat, "~> 0.1"},
          # WS-D D5 observability (ADR-022): opentelemetry_ecto is listed DIRECTLY (not
          # relied on transitively) so the `no_plaintext_pii` LogTelemetry tier — which
          # reads `Mix.Project.config[:deps]`, not transitive apps — SEES the OTel-Ecto
          # leak surface and asserts `db_statement: :disabled` on it. Dropping that config
          # then flips the gate (the D6 flagship sabotage). The API+SDK ride transitively
          # from samen_core; only the Ecto integration must be a direct dep to arm the tier.
          {:opentelemetry_ecto, "~> 1.2"},
          # WS-F5 F5.1 metrics egress: the Prometheus reporter for the bounded
          # Samen.Metrics.definitions/0. OFF by default (metrics_egress? flag, set from
          # SAMEN_METRICS_ENABLED in config/runtime.exs); the dep is listed so a prod
          # host that flips the flag has a real reporter. Samen.Observability starts it;
          # the framework `samen_metrics_route/1` serves `GET /metrics` (else 404).
          {:telemetry_metrics_prometheus_core, "~> 1.1"}
        ]
      end

      defp aliases, do: []
    end
    """
  end

  # ------------------------------------------------------------------ config (web)
  defp config_exs_web do
    """
    import Config

    # <%= module %> — a Samen vertical scaffolded by `mix samen.gen.app`. Mounts the
    # samen_core Billing scope AS-IS, authors the vertical resource, defines a
    # token-blind aggregate projection, and (WS-D D2 / ADR-022) mounts the Primitives
    # scope + the ADR-010 operator namespace behind the samen_web framework UI.
    config :<%= otp_app %>,
      ecto_repos: [<%= module %>.Repo],
      ash_domains: [
        <%= module %>.Billing,
        <%= module %>.Vertical,
        <%= module %>.Aggregate,
        <%= module %>.Primitives,
        <%= module %>.Operator
      ]

    # The samen_core verifiers discover domains from :samen_core :ash_domains. Register
    # this app's domains so the gate scans the mounted Billing scope + the vertical
    # resource + the token-blind aggregate + the Primitives mount + the operator plane.
    config :samen_core, :ash_domains, [
      <%= module %>.Billing,
      <%= module %>.Vertical,
      <%= module %>.Aggregate,
      <%= module %>.Primitives,
      <%= module %>.Operator
    ]

    config :ash, disable_async?: true

    config :<%= otp_app %>, <%= module %>.Repo,
      migration_primary_key: [name: :id, type: :binary_id]

    # Reveal-grant + non_pii + verify + vault + tnt_record repos: wire this app's repo.
    config :samen_core, :reveal_grant, Samen.Reveal.Grants
    config :samen_core, :reveal_grant_repo, <%= module %>.Repo
    config :samen_core, :non_pii_repo, <%= module %>.Repo
    config :samen_core, :verify_repo, <%= module %>.Repo
    config :samen_core, :vault_repo, <%= module %>.Repo
    config :samen_core, :tnt_record_repo, <%= module %>.Repo

    # T4.5 aggregate-privacy floors. samen_core defaults are k=5/l=2; a fresh app's
    # dogfood datasets are small, so — exactly as demo/driftwood/pawchart — use a
    # small-but-non-trivial floor (k=2/l=2): a count-of-one cohort still suppresses.
    # Production hosts keep k=5.
    config :samen_core, :k_anonymity_min_cohort, 2
    config :samen_core, :l_diversity_min_distinct, 2

    # The query-budget ledger repo (SCAFFOLD — accounting only, WARN-not-enforce).
    config :samen_core, :query_budget_ledger_repo, <%= module %>.Repo

    # ADR-010: the well-known operator org id — `Samen.Web.Operator.org_id/1` resolution
    # step 2 reads it from this app env. The operator workspace reads the operator org's
    # OWN book of business on the TENANT plane (clear); seeds anchor rows on this id.
    config :<%= otp_app %>, :operator_org_id, "<%= operator_org_id %>"

    # WS-A A4/A5 — the kernel notification ENGINE wired to this app's Primitives mount
    # (the ADR-014 SendWorker config convention: the kernel is mount-agnostic; the host
    # names its concrete modules + repo). Realtime rides the samen_web PubSub broadcaster
    # over `<%= module %>.PubSub` — id-only envelopes; each inbox subscriber re-reads per
    # its OWN scope.
    config :samen_core, Samen.Notifications.Engine,
      notification_module: <%= module %>.Primitives.Notification,
      preference_module: <%= module %>.Primitives.NotificationPreference,
      repo: <%= module %>.Repo,
      broadcaster: Samen.Web.Notifications.PubSubBroadcaster

    config :samen_web, Samen.Web.Notifications.PubSubBroadcaster, pubsub: <%= module %>.PubSub

    config :phoenix, :json_library, Jason

    # WS-D D5 observability (ADR-022): OTel-Ecto records the SQL statement into trace
    # spans by DEFAULT — on a Samen substrate that surface must be proven token-only, so
    # `db_statement: :disabled` is categorical (the `no_plaintext_pii` LogTelemetry tier
    # asserts it, config-level + live-handler). `Samen.Observability.child_specs/1` (wired
    # in application.ex) OWNS this default and raises at build time if this key contradicts
    # it. Removing this line flips the gate (the D6 flagship observability sabotage).
    config :<%= otp_app %>, :opentelemetry_ecto, db_statement: :disabled

    # <%= module %>Web.Endpoint — LOCAL DEV/DOGFOOD constants (ADR-022: the endpoint is a
    # thin EMITTED file and the builder OWNS the port/secret_key_base/salts; a real
    # deployment replaces them via config/runtime.exs — the `--deploy` layer).
    config :<%= otp_app %>, <%= module %>Web.Endpoint,
      adapter: Bandit.PhoenixAdapter,
      url: [host: "localhost"],
      http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT") || "<%= http_port %>")],
      secret_key_base: "<%= secret_key_base %>",
      live_view: [signing_salt: "<%= otp_app %>_lv_salt_dogfood"],
      render_errors: [formats: [html: <%= module %>Web.ErrorHTML], layout: false],
      pubsub_server: <%= module %>.PubSub,
      server: false

    # Oban: the canonical queue taxonomy (reused verbatim from the substrate convention).
    config :samen_core, Oban,
      repo: <%= module %>.Repo,
      queues: [
        default: 10,
        rollups: 2,
        webhooks_out: 5,
        erasure: 1,
        maintenance: 1,
        reveal: 5
      ],
      plugins: [
        {Oban.Plugins.Pruner, max_age: 7 * 24 * 60 * 60}
      ]

    import_config "\#{config_env()}.exs"
    """
  end

  defp dev_exs_web do
    """
    import Config

    config :<%= otp_app %>, <%= module %>.Repo,
      username: System.get_env("USER") || "postgres",
      password: "",
      hostname: "localhost",
      database: "<%= otp_app %>_dev",
      pool_size: 10

    config :logger, level: :info

    # In dev the Endpoint actually serves HTTP (`mix phx.server` → a running product).
    config :<%= otp_app %>, <%= module %>Web.Endpoint, server: true

    # Local dev KMS key store (file-backed) — the vault needs a keystore to boot.
    config :samen_core, :kms_key_dir, Path.expand("../priv/dev_keystore", __DIR__)
    """
  end

  # ------------------------------------------------------------------ application (web)
  defp application_ex_web do
    """
    defmodule <%= module %>.Application do
      @moduledoc "<%= module %> OTP application (scaffolded by mix samen.gen.app)."
      use Application

      @impl true
      def start(_type, _args) do
        # Observability plane (WS-D D1.1/D5): OTel-Ecto with the un-forgettable
        # db_statement: :disabled + metrics contention handlers, wired via the
        # framework helper instead of hand-copied setup calls. Follows the repo:
        # in :test start_repo? is false, so no Ecto telemetry exists to observe.
        repo_children =
          if Application.get_env(:<%= otp_app %>, :start_repo?, true) do
            Samen.Observability.child_specs(:<%= otp_app %>) ++
              [<%= module %>.Repo, {Oban, Application.fetch_env!(:samen_core, Oban)}]
          else
            []
          end

        # The web plane (PubSub + Endpoint) starts whenever the repo runs (mirrors
        # pawchart/driftwood; the endpoint only SERVES when `server: true` — dev/prod).
        web_children =
          if Application.get_env(:<%= otp_app %>, :start_repo?, true) do
            [{Phoenix.PubSub, name: <%= module %>.PubSub}, <%= module %>Web.Endpoint]
          else
            []
          end

        opts = [strategy: :one_for_one, name: <%= module %>.Supervisor]
        Supervisor.start_link(repo_children ++ web_children, opts)
      end
    end
    """
  end

  # ------------------------------------------------------------------ primitives mount
  defp primitives_ex do
    """
    defmodule <%= module %>.Primitives do
      @moduledoc \"\"\"
      <%= module %>'s Primitives domain — the samen_core Primitives scope blueprint
      (ADR-004; `Samen.Scopes.Primitives`) mounted AS-IS, exactly as demo
      (`Demo.PrimitivesScope`), driftwood (`Driftwood.Primitives`) and pawchart
      (`PawChart.Primitives`) mount it.

      This mount exists so the app INHERITS the framework notifications inbox
      (`samen_notifications_routes` in the router — zero LiveView code) and the
      FeatureFlag rows the operator flag admin manages (the `flags_namespace` label).

      Fresh `<%= p_nt %>/<%= p_np %>/<%= p_fl %>/<%= p_sh %>/<%= p_wh %>/<%= p_ff %>` abbrevs,
      reserved in the GLOBAL registry (samen_core/priv/abbrev_registry.json) by the
      generator:

        * `<%= p_nt %>` Notification (🔒 rendered_body → vault; `pii_<%= p_nt %>_rendered_body`)
        * `<%= p_np %>` NotificationPreference (no PII — bounded id + enums + bools)
        * `<%= p_fl %>`/`<%= p_sh %>`/`<%= p_wh %>`/`<%= p_ff %>` — File/SearchIndex/Webhook/
          FeatureFlag (blueprint completeness; the flag rows back the operator flag admin)
      \"\"\"
      use Ash.Domain, validate_config_inclusion?: false

      use Samen.Scopes.Primitives,
        otp_app: :<%= otp_app %>,
        repo: <%= module %>.Repo,
        namespace: <%= module %>.Primitives,
        abbrevs: %{
          notification: "<%= p_nt %>",
          notification_preference: "<%= p_np %>",
          file: "<%= p_fl %>",
          search_index: "<%= p_sh %>",
          webhook: "<%= p_wh %>",
          feature_flag: "<%= p_ff %>"
        }
    end
    """
  end

  # ------------------------------------------------------------------ operator namespace
  defp operator_ex do
    """
    defmodule <%= module %>.Operator do
      @moduledoc \"\"\"
      <%= module %>'s OPERATOR namespace (ADR-010 §8.1) — a SECOND mount of the Identity +
      Billing + Support blueprints, alongside the vertical's own tenant mounts. Its rows
      describe the SaaS company's OWN book of business as a vendor: its tenant-org ACCOUNTS
      (`Identity.Org`), those accounts' tenant-ADMINS (`Identity.User` — PII the SaaS OWNS,
      CLEAR to the operator on its own tenant plane), each tenant's subscription-to-the-SaaS
      (`Billing`), and the tickets tenants file WITH the SaaS (`Support`). Mirrors
      `Driftwood.Operator` — the shipped reference.

      The operator workspace is mounted in the router by ONE `samen_operator_routes` line;
      the well-known operator org id lives in config (`:operator_org_id`).

      Fresh `<%= o_org %>*`-family abbrevs (Identity `<%= prefix %>→o`, Billing `→p`,
      Support `→q` — the driftwood per-plane convention), reserved append-only in the
      GLOBAL registry by the generator. No samen_core code changed — only data-file rows
      (ADR-006).
      \"\"\"
      use Ash.Domain, validate_config_inclusion?: false

      use Samen.Scopes.Identity,
        otp_app: :<%= otp_app %>,
        repo: <%= module %>.Repo,
        namespace: <%= module %>.Operator,
        abbrevs: %{
          org: "<%= o_org %>",
          user: "<%= o_user %>",
          membership: "<%= o_mem %>",
          role: "<%= o_role %>",
          api_key: "<%= o_key %>",
          invitation: "<%= o_invite %>"
        }

      use Samen.Scopes.Billing,
        otp_app: :<%= otp_app %>,
        repo: <%= module %>.Repo,
        namespace: <%= module %>.Operator,
        abbrevs: %{
          customer: "<%= o_cus %>",
          subscription: "<%= o_sub %>",
          plan: "<%= o_plan %>",
          price: "<%= o_price %>",
          invoice: "<%= o_invoice %>",
          payment: "<%= o_pay %>",
          usage: "<%= o_usage %>",
          entitlement: "<%= o_ent %>",
          subscription_event: "<%= o_sev %>"
        }

      use Samen.Scopes.Support,
        otp_app: :<%= otp_app %>,
        repo: <%= module %>.Repo,
        namespace: <%= module %>.Operator,
        abbrevs: %{
          ticket: "<%= o_tick %>",
          conversation: "<%= o_conv %>",
          message: "<%= o_msg %>",
          agent: "<%= o_agent %>",
          sla: "<%= o_sla %>",
          macro: "<%= o_macro %>",
          csat: "<%= o_csat %>"
        }
    end
    """
  end

  # ------------------------------------------------------------------ web tree
  defp endpoint_ex do
    """
    defmodule <%= module %>Web.Endpoint do
      @moduledoc \"\"\"
      The <%= module %> Phoenix Endpoint — serves the tenant + operator LiveView planes
      over localhost. Mirrors pawchart/driftwood (ADR-009).

      THIN and EMITTED, not macro-hidden (ADR-022): the builder owns the session key,
      signing salt, secret_key_base and port. The values wired here + in config are LOCAL
      DEV/DOGFOOD constants — a real deployment replaces them (config/runtime.exs).
      \"\"\"
      use Phoenix.Endpoint, otp_app: :<%= otp_app %>

      @session_options [
        store: :cookie,
        key: "_<%= otp_app %>_key",
        signing_salt: "<%= otp_app %>_sess_salt",
        same_site: "Lax"
      ]

      socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

      # ADR-009: serve the Samen UI kit's stylesheet from the samen_web DEPENDENCY's priv
      # at `/assets/samen_ui.css`. Same file as every vertical — zero duplication.
      plug(Plug.Static,
        at: "/assets",
        from: {:samen_web, "priv/static/assets"},
        only: ~w(samen_ui.css)
      )

      plug(Plug.RequestId)
      plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

      plug(Plug.Parsers,
        parsers: [:urlencoded, :multipart, :json],
        pass: ["*/*"],
        json_decoder: Phoenix.json_library()
      )

      plug(Plug.MethodOverride)
      plug(Plug.Head)
      plug(Plug.Session, @session_options)
      plug(<%= module %>Web.Router)
    end
    """
  end

  defp router_ex do
    """
    defmodule <%= module %>Web.Router do
      @moduledoc \"\"\"
      The <%= module %> host router (ADR-009 reuse proof, scaffolded by `mix samen.gen.app`).

      The ENTIRE product UI is MOUNTED from samen_web via `Samen.Web.Router` macros —
      zero <%= module %> LiveView modules authored:

        * `samen_module_routes(:billing, ...)` — the authored scope's inherited pages
          (overview / invoices / plans),
        * `samen_notifications_routes(...)` — the framework notifications inbox
          (+ /notifications/settings) over the Primitives mount,
        * `samen_operator_routes(...)` — the ADR-010 operator workspace (accounts ·
          platform billing · revenue · flags · analytics · desk) over the operator
          namespace; the `flags_namespace` label activates the flag admin over this
          app's FeatureFlag rows,
        * `samen_session_routes()` — the ADR-013 current-org session write (the
          workspace switcher + the operator "Open account →" target).
      \"\"\"
      use Phoenix.Router
      import Phoenix.LiveView.Router
      import Samen.Web.Router

      pipeline :browser do
        plug(:accepts, ["html"])
        plug(:fetch_session)
        plug(:put_root_layout, html: {<%= module %>Web.Layouts, :root})
        plug(:protect_from_forgery)
      end

      scope "/", <%= module %>Web do
        pipe_through(:browser)

        get("/", PageController, :index)
        get("/healthz", PageController, :healthz)
        get("/readyz", PageController, :readyz)
      end

      # The inherited product UI, MOUNTED from samen_web. BARE `scope "/"` (no
      # `<%= module %>Web` alias): the mounted LiveViews are the framework's own
      # `Samen.Web.*` modules — aliasing under `<%= module %>Web` would wrongly resolve them.
      scope "/" do
        pipe_through(:browser)

        # ADR-013 §4.3 — the framework SESSION-write endpoint (`GET /session/org/:org_id`).
        samen_session_routes()

        # 1. Billing — the mounted samen_core Billing scope's inherited pages.
        samen_module_routes(:billing, <%= module %>.Billing, repo: <%= module %>.Repo)

        # 2. Notifications (WS-A A4/A5) — the framework inbox (+ /notifications/settings),
        #    mounted over the Primitives mount in ONE line. Realtime rides
        #    `<%= module %>.PubSub` (id-only envelopes).
        samen_notifications_routes(:notifications, <%= module %>.Primitives,
          repo: <%= module %>.Repo,
          labels: %{pubsub: <%= module %>.PubSub}
        )

        # 3. Metrics egress (WS-F5 F5.1) — the framework `GET /metrics` Prometheus
        #    scrape endpoint over `Samen.Metrics.definitions/0`. OFF by default: the
        #    route self-gates to 404 until `metrics_egress?` is set (see
        #    config/runtime.exs → SAMEN_METRICS_ENABLED). Name matches the reporter
        #    Samen.Observability starts (`:<%= otp_app %>_prometheus`).
        samen_metrics_route(name: :<%= otp_app %>_prometheus)
      end

      # ADR-010 — the OPERATOR / SaaS-company workspace, mounted in ONE line over the
      # operator namespace (accounts ARE tenant orgs). The operator seat reads the
      # operator org's OWN book of business on the TENANT plane (clear); drilling into
      # a tenant is the existing masked impersonation path.
      scope "/" do
        pipe_through(:browser)

        samen_operator_routes(<%= module %>.Operator,
          repo: <%= module %>.Repo,
          labels: %{
            operator_workspace: "<%= module %> Ops",
            # WS-B B6 — the FlagAdminLive namespace seam: the Primitives mount whose
            # FeatureFlag rows the platform flag admin manages.
            flags_namespace: <%= module %>.Primitives
          }
        )
      end
    end
    """
  end

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

  defp page_controller_ex do
    """
    defmodule <%= module %>Web.PageController do
      @moduledoc \"\"\"
      The <%= module %> landing + health endpoints (scaffolded by `mix samen.gen.app`).

      `/` renders a plain HTML index linking the inherited framework surfaces;
      `/healthz` returns `ok` (the LIVENESS probe — the BEAM is up).
      `/readyz` is the READINESS probe — it returns 200 only when Postgres, the KMS
      wrapped-DEK store, and Oban all answer (`Samen.Web.Readiness`), else 503. Fly's
      `[[http_service.checks]]` gates traffic on `/readyz`, so a machine whose deps are
      down is drained instead of being sent requests it can only 500.
      \"\"\"
      use Phoenix.Controller, formats: [:html]

      import Plug.Conn

      def index(conn, _params) do
        html(conn, \"\"\"
        <!DOCTYPE html>
        <html><head><title><%= module %> — a Samen vertical</title>
        <style>body{font-family:system-ui;max-width:640px;margin:40px auto;padding:0 20px}
        h1{margin-bottom:4px}p{color:#666;margin-top:0}ul{margin-top:20px}
        li{margin:8px 0}a{color:#0e7c5a;text-decoration:none}a:hover{text-decoration:underline}
        .note{font-size:13px;color:#888;margin-top:24px;border-top:1px solid #eee;padding-top:16px}</style>
        </head>
        <body>
          <h1><%= module %></h1>
          <p>A Samen vertical scaffolded by <code>mix samen.gen.app</code> — a running product,
          correct-by-construction.</p>
          <ul>
            <li><strong>Inherited (samen_web mounts):</strong></li>
            <li><a href="/billing">Billing → Overview</a></li>
            <li><a href="/billing/invoices">Billing → Invoices</a></li>
            <li><a href="/notifications">Notifications → Inbox</a></li>
            <li><a href="/operator/accounts">Operator → Accounts</a></li>
            <li><a href="/healthz">Health check</a></li>
          </ul>
          <div class="note">
            Mount reuse: 1 <code>samen_module_routes</code> + 1 <code>samen_notifications_routes</code>
            + 1 <code>samen_operator_routes</code> line mount every page above —
            0 <%= module %> LiveView modules authored.
          </div>
        </body></html>
        \"\"\")
      end

      def healthz(conn, _params) do
        send_resp(conn, 200, "ok")
      end

      def readyz(conn, _params) do
        case Samen.Web.Readiness.check(repo: <%= module %>.Repo) do
          {:ok, _checks} ->
            send_resp(conn, 200, "ready")

          {:error, checks} ->
            body =
              Enum.map_join(checks, "\\n", fn
                {component, :ok} -> "\#{component}: ok"
                {component, {:error, _reason}} -> "\#{component}: FAIL"
              end)

            send_resp(conn, 503, "not ready\\n" <> body)
        end
      end
    end
    """
  end

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

  # ------------------------------------------------------------ primitives migration
  defp m_mount_primitives_scope do
    ~S'''
    defmodule <%= module %>.Repo.Migrations.MountPrimitivesScope do
      @moduledoc """
      Mounts the Primitives scope tables (`<%= module %>.Primitives`, abbrevs
      `<%= p_nt %>/<%= p_np %>/<%= p_fl %>/<%= p_sh %>/<%= p_wh %>/<%= p_ff %>`) and catalogs
      them in the SAME migration transaction (ADR-004 catalog-in-tx). Mirrors pawchart's
      `mount_primitives_scope` (with the B5 flag-engine fields included — target_rules +
      variants land directly on the flag table).

      Load-bearing tables for the inherited web surfaces:

        * `<%= p_nt %>_notification` — 🔒 PII: rendered_body (vault token;
          `pii_<%= p_nt %>_rendered_body`) — the notifications inbox
        * `<%= p_ff %>_feature_flag` — the flag rows the operator flag admin manages
      """
      use Samen.Migration

      @resources [
        <%= module %>.Primitives.Notification,
        <%= module %>.Primitives.NotificationPreference,
        <%= module %>.Primitives.File,
        <%= module %>.Primitives.SearchIndex,
        <%= module %>.Primitives.Webhook,
        <%= module %>.Primitives.FeatureFlag
      ]

      def up do
        # --- <%= p_nt %>_notification : 🔒 PII: rendered_body ---
        create table(:<%= p_nt %>_notification, primary_key: false) do
          add(:<%= p_nt %>_recipient_id, :uuid, null: false)
          add(:<%= p_nt %>_channel, :text, default: "in_app")
          add(:<%= p_nt %>_event_type, :text, null: false)
          add(:<%= p_nt %>_status, :text, default: "pending")
          add(:<%= p_nt %>_sent_at, :utc_datetime)
          add(:<%= p_nt %>_read_at, :utc_datetime)
          add(:<%= p_nt %>_metadata, :map, default: fragment("'{}'::jsonb"))
          add(:pii_<%= p_nt %>_rendered_body, :text)
          add(:<%= p_nt %>_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
          add(:<%= p_nt %>_org_id, :uuid, null: false)
          add(:<%= p_nt %>_inserted_at, :utc_datetime, null: false)
          add(:<%= p_nt %>_updated_at, :utc_datetime, null: false)
        end

        create(
          index(:<%= p_nt %>_notification, [:<%= p_nt %>_recipient_id, :<%= p_nt %>_org_id],
            name: "<%= p_nt %>_notification_recipient_org_idx"
          )
        )

        create(
          index(:<%= p_nt %>_notification, [:<%= p_nt %>_status, :<%= p_nt %>_org_id],
            name: "<%= p_nt %>_notification_status_org_idx"
          )
        )

        # --- <%= p_np %>_notification_preference : per-recipient dispatch prefs (no PII) ---
        create table(:<%= p_np %>_notification_preference, primary_key: false) do
          add(:<%= p_np %>_recipient_id, :uuid, null: false)
          add(:<%= p_np %>_event_type, :text, null: false)
          add(:<%= p_np %>_in_app_enabled, :boolean, default: true)
          add(:<%= p_np %>_email_enabled, :boolean, default: false)
          add(:<%= p_np %>_quiet_hours, :map, default: fragment("'{}'::jsonb"))
          add(:<%= p_np %>_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
          add(:<%= p_np %>_org_id, :uuid, null: false)
          add(:<%= p_np %>_inserted_at, :utc_datetime, null: false)
          add(:<%= p_np %>_updated_at, :utc_datetime, null: false)
        end

        create(
          index(:<%= p_np %>_notification_preference, [:<%= p_np %>_recipient_id, :<%= p_np %>_event_type, :<%= p_np %>_org_id],
            name: "<%= p_np %>_notification_preference_recipient_event_org_idx",
            unique: true
          )
        )

        # --- <%= p_fl %>_file ---
        create table(:<%= p_fl %>_file, primary_key: false) do
          add(:<%= p_fl %>_filename, :text, null: false)
          add(:<%= p_fl %>_content_type, :text)
          add(:<%= p_fl %>_size_bytes, :integer)
          add(:<%= p_fl %>_storage_key, :text, null: false)
          add(:<%= p_fl %>_status, :text, default: "active")
          add(:<%= p_fl %>_uploaded_by_id, :uuid)
          add(:<%= p_fl %>_metadata, :map, default: fragment("'{}'::jsonb"))
          add(:<%= p_fl %>_search_vector, :text)
          add(:<%= p_fl %>_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
          add(:<%= p_fl %>_org_id, :uuid, null: false)
          add(:<%= p_fl %>_inserted_at, :utc_datetime, null: false)
          add(:<%= p_fl %>_updated_at, :utc_datetime, null: false)
        end

        # --- <%= p_sh %>_search_index ---
        create table(:<%= p_sh %>_search_index, primary_key: false) do
          add(:<%= p_sh %>_resource_name, :text, null: false)
          add(:<%= p_sh %>_field_name, :text, null: false)
          add(:<%= p_sh %>_vector_column, :text, null: false)
          add(:<%= p_sh %>_description, :text)
          add(:<%= p_sh %>_enabled, :boolean, default: true)
          add(:<%= p_sh %>_ts_config, :text, default: "english")
          add(:<%= p_sh %>_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
          add(:<%= p_sh %>_org_id, :uuid, null: false)
          add(:<%= p_sh %>_inserted_at, :utc_datetime, null: false)
          add(:<%= p_sh %>_updated_at, :utc_datetime, null: false)
        end

        # --- <%= p_wh %>_webhook : 🔒 PII: signing_secret ---
        create table(:<%= p_wh %>_webhook, primary_key: false) do
          add(:<%= p_wh %>_url, :text, null: false)
          add(:<%= p_wh %>_label, :text)
          add(:<%= p_wh %>_event_types, {:array, :text}, default: [])
          add(:<%= p_wh %>_status, :text, default: "active")
          add(:<%= p_wh %>_failure_count, :integer, default: 0)
          add(:<%= p_wh %>_last_delivered_at, :utc_datetime)
          add(:<%= p_wh %>_metadata, :map, default: fragment("'{}'::jsonb"))
          add(:pii_<%= p_wh %>_signing_secret, :text)
          add(:<%= p_wh %>_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
          add(:<%= p_wh %>_org_id, :uuid, null: false)
          add(:<%= p_wh %>_inserted_at, :utc_datetime, null: false)
          add(:<%= p_wh %>_updated_at, :utc_datetime, null: false)
        end

        # --- <%= p_ff %>_feature_flag (incl. the B5 engine fields: target_rules/variants) ---
        create table(:<%= p_ff %>_feature_flag, primary_key: false) do
          add(:<%= p_ff %>_name, :text, null: false)
          add(:<%= p_ff %>_description, :text)
          add(:<%= p_ff %>_enabled, :boolean, default: false)
          add(:<%= p_ff %>_rollout_pct, :integer, default: 100)
          add(:<%= p_ff %>_stage, :text, default: "beta")
          add(:<%= p_ff %>_metadata, :map, default: fragment("'{}'::jsonb"))
          add(:<%= p_ff %>_target_rules, :map, default: fragment("'[]'::jsonb"))
          add(:<%= p_ff %>_variants, :map, default: fragment("'{}'::jsonb"))
          add(:<%= p_ff %>_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
          add(:<%= p_ff %>_org_id, :uuid, null: false)
          add(:<%= p_ff %>_inserted_at, :utc_datetime, null: false)
          add(:<%= p_ff %>_updated_at, :utc_datetime, null: false)
        end

        catalog_sync(@resources)
      end

      def down do
        catalog_sync_down(@resources)

        drop(table(:<%= p_ff %>_feature_flag))
        drop(table(:<%= p_wh %>_webhook))
        drop(table(:<%= p_sh %>_search_index))
        drop(table(:<%= p_fl %>_file))

        drop(
          index(:<%= p_np %>_notification_preference, [:<%= p_np %>_recipient_id, :<%= p_np %>_event_type, :<%= p_np %>_org_id],
            name: "<%= p_np %>_notification_preference_recipient_event_org_idx"
          )
        )

        drop(table(:<%= p_np %>_notification_preference))

        drop(
          index(:<%= p_nt %>_notification, [:<%= p_nt %>_status, :<%= p_nt %>_org_id],
            name: "<%= p_nt %>_notification_status_org_idx"
          )
        )

        drop(
          index(:<%= p_nt %>_notification, [:<%= p_nt %>_recipient_id, :<%= p_nt %>_org_id],
            name: "<%= p_nt %>_notification_recipient_org_idx"
          )
        )

        drop(table(:<%= p_nt %>_notification))
      end
    end
    '''
  end

  # ------------------------------------------------------------ operator migration
  defp m_mount_operator_scopes do
    ~S'''
    defmodule <%= module %>.Repo.Migrations.MountOperatorScopes do
      @moduledoc """
      Mounts the OPERATOR namespace (ADR-010 §8.2) into the host's one Postgres: a SECOND
      mount of Identity + Billing + Support whose rows describe the SaaS company's OWN
      book of business — its tenant-org ACCOUNTS, their tenant-ADMINS (PII the SaaS owns,
      CLEAR), each tenant's subscription-to-the-SaaS (incl. the ADR-017 movement ledger),
      and the tickets tenants file WITH the SaaS. Mirrors driftwood's
      `mount_operator_scopes`. Catalogued in the SAME transaction (ADR-004 catalog-in-tx).

      PII columns hold vault `vt_*` tokens (plaintext never lands here):
        * `<%= o_user %>_user.<%= o_user %>_full_name` / `.<%= o_user %>_emails`
        * `<%= o_cus %>_customer.pii_<%= o_cus %>_billing_name` / `.pii_<%= o_cus %>_billing_email`
        * `<%= o_agent %>_agent.<%= o_agent %>_full_name` / `.pii_<%= o_agent %>_email`,
          `<%= o_msg %>_message.pii_<%= o_msg %>_body`
      """
      use Samen.Migration

      @resources [
        # Identity (operator: accounts + admins)
        <%= module %>.Operator.Org,
        <%= module %>.Operator.User,
        <%= module %>.Operator.Membership,
        <%= module %>.Operator.Role,
        <%= module %>.Operator.ApiKey,
        <%= module %>.Operator.Invitation,
        # Billing (operator: tenant subscriptions-to-the-SaaS + the movement ledger)
        <%= module %>.Operator.Customer,
        <%= module %>.Operator.Subscription,
        <%= module %>.Operator.Plan,
        <%= module %>.Operator.Price,
        <%= module %>.Operator.Invoice,
        <%= module %>.Operator.Payment,
        <%= module %>.Operator.Usage,
        <%= module %>.Operator.Entitlement,
        <%= module %>.Operator.SubscriptionEvent,
        # Support (operator: tenant-filed desk tickets)
        <%= module %>.Operator.Sla,
        <%= module %>.Operator.Ticket,
        <%= module %>.Operator.Conversation,
        <%= module %>.Operator.Agent,
        <%= module %>.Operator.Message,
        <%= module %>.Operator.Macro,
        <%= module %>.Operator.Csat
      ]

      def up do
        # =====================================================================
        # IDENTITY — accounts (Org) + admins (User) + membership + role/key/invite
        # =====================================================================

        # --- <%= o_org %>_org : the tenant anchor. Here: an ACCOUNT (a tenant org
        #     mirrored). The slug carries the tenant_org_id back-reference (Bridge-B). ---
        create table(:<%= o_org %>_org, primary_key: false) do
          add(:<%= o_org %>_name, :text, null: false)
          add(:<%= o_org %>_slug, :text)
          add(:<%= o_org %>_plan, :text, default: "free")
          add(:<%= o_org %>_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
          add(:<%= o_org %>_org_id, :uuid)
          add(:<%= o_org %>_inserted_at, :utc_datetime, null: false)
          add(:<%= o_org %>_updated_at, :utc_datetime, null: false)
        end

        # --- <%= o_user %>_user : the tenant-ADMIN 🔒 (full_name/emails vault-routed) ---
        create table(:<%= o_user %>_user, primary_key: false) do
          add(:<%= o_user %>_handle, :text)
          add(:<%= o_user %>_status, :text, default: "active")
          add(:<%= o_user %>_full_name, :text)
          add(:<%= o_user %>_emails, :text)
          add(:<%= o_user %>_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
          add(:<%= o_user %>_org_id, :uuid, null: false)
          add(:<%= o_user %>_inserted_at, :utc_datetime, null: false)
          add(:<%= o_user %>_updated_at, :utc_datetime, null: false)
        end

        # --- <%= o_mem %>_membership : (user, org, role) ---
        create table(:<%= o_mem %>_membership, primary_key: false) do
          add(:<%= o_mem %>_role, :text, default: "member")
          add(:<%= o_mem %>_status, :text, default: "active")

          add(
            :<%= o_mem %>_user_id,
            references(:<%= o_user %>_user,
              column: :<%= o_user %>_id,
              name: "<%= o_mem %>_membership_<%= o_mem %>_user_id_fkey",
              type: :uuid,
              prefix: "public"
            )
          )

          add(:<%= o_mem %>_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
          add(:<%= o_mem %>_org_id, :uuid, null: false)
          add(:<%= o_mem %>_inserted_at, :utc_datetime, null: false)
          add(:<%= o_mem %>_updated_at, :utc_datetime, null: false)
        end

        # --- <%= o_role %>_role : Tier-0 config rows (per-org role catalog) ---
        create table(:<%= o_role %>_role, primary_key: false) do
          add(:<%= o_role %>_name, :text, null: false)
          add(:<%= o_role %>_label, :text)
          add(:<%= o_role %>_rank, :integer, null: false)
          add(:<%= o_role %>_enabled, :boolean, default: true)
          add(:<%= o_role %>_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
          add(:<%= o_role %>_org_id, :uuid, null: false)
          add(:<%= o_role %>_inserted_at, :utc_datetime, null: false)
          add(:<%= o_role %>_updated_at, :utc_datetime, null: false)
        end

        # --- <%= o_key %>_api_key : scoped credential (two planes) ---
        create table(:<%= o_key %>_api_key, primary_key: false) do
          add(:<%= o_key %>_token_digest, :text, null: false)
          add(:<%= o_key %>_plane, :text, null: false, default: "tenant")
          add(:<%= o_key %>_scopes, :map, default: fragment("'{}'::jsonb"))
          add(:<%= o_key %>_minter_role, :text)
          add(:<%= o_key %>_revoked_at, :utc_datetime)
          # F3.4 — bounded API-key expiry (deny-on-read) + last-use observability.
          add(:<%= o_key %>_expires_at, :utc_datetime)
          add(:<%= o_key %>_last_used_at, :utc_datetime)

          add(
            :<%= o_key %>_membership_id,
            references(:<%= o_mem %>_membership,
              column: :<%= o_mem %>_id,
              name: "<%= o_key %>_api_key_<%= o_key %>_membership_id_fkey",
              type: :uuid,
              prefix: "public"
            )
          )

          add(:<%= o_key %>_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
          add(:<%= o_key %>_org_id, :uuid, null: false)
          add(:<%= o_key %>_inserted_at, :utc_datetime, null: false)
          add(:<%= o_key %>_updated_at, :utc_datetime, null: false)
        end

        # --- <%= o_invite %>_invitation : a pending invite 🔒 (email vault-routed) ---
        create table(:<%= o_invite %>_invitation, primary_key: false) do
          add(:<%= o_invite %>_role, :text, default: "member")
          add(:<%= o_invite %>_status, :text, default: "pending")
          add(:<%= o_invite %>_accept_token, :text)
          add(:<%= o_invite %>_email, :text)
          add(:<%= o_invite %>_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
          add(:<%= o_invite %>_org_id, :uuid, null: false)
          add(:<%= o_invite %>_inserted_at, :utc_datetime, null: false)
          add(:<%= o_invite %>_updated_at, :utc_datetime, null: false)
        end

        # =====================================================================
        # BILLING — each tenant's subscription TO the SaaS
        # =====================================================================

        create table(:<%= o_cus %>_customer, primary_key: false) do
          add(:<%= o_cus %>_stripe_customer_id, :text)
          add(:<%= o_cus %>_status, :text, default: "active")
          add(:<%= o_cus %>_currency, :text, default: "USD")
          add(:<%= o_cus %>_custom, :map, default: fragment("'{}'::jsonb"))
          add(:pii_<%= o_cus %>_billing_name, :text)
          add(:pii_<%= o_cus %>_billing_email, :text)
          add(:<%= o_cus %>_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
          add(:<%= o_cus %>_org_id, :uuid, null: false)
          add(:<%= o_cus %>_inserted_at, :utc_datetime, null: false)
          add(:<%= o_cus %>_updated_at, :utc_datetime, null: false)
        end

        create table(:<%= o_plan %>_plan, primary_key: false) do
          add(:<%= o_plan %>_name, :text, null: false)
          add(:<%= o_plan %>_label, :text)
          add(:<%= o_plan %>_description, :text)
          add(:<%= o_plan %>_stripe_plan_id, :text)
          add(:<%= o_plan %>_interval, :text, default: "monthly")
          add(:<%= o_plan %>_enabled, :boolean, default: true)
          add(:<%= o_plan %>_features, :map, default: fragment("'{}'::jsonb"))
          add(:<%= o_plan %>_custom, :map, default: fragment("'{}'::jsonb"))
          add(:<%= o_plan %>_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
          add(:<%= o_plan %>_org_id, :uuid, null: false)
          add(:<%= o_plan %>_inserted_at, :utc_datetime, null: false)
          add(:<%= o_plan %>_updated_at, :utc_datetime, null: false)
        end

        create table(:<%= o_price %>_price, primary_key: false) do
          add(:<%= o_price %>_stripe_price_id, :text)
          add(:<%= o_price %>_unit_amount_cents, :integer, null: false)
          add(:<%= o_price %>_currency, :text, null: false, default: "USD")
          add(:<%= o_price %>_interval, :text, default: "monthly")
          add(:<%= o_price %>_active, :boolean, default: true)
          add(:<%= o_price %>_custom, :map, default: fragment("'{}'::jsonb"))

          add(
            :<%= o_price %>_plan_id,
            references(:<%= o_plan %>_plan,
              column: :<%= o_plan %>_id,
              name: "<%= o_price %>_price_<%= o_price %>_plan_id_fkey",
              type: :uuid,
              prefix: "public"
            )
          )

          add(:<%= o_price %>_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
          add(:<%= o_price %>_org_id, :uuid, null: false)
          add(:<%= o_price %>_inserted_at, :utc_datetime, null: false)
          add(:<%= o_price %>_updated_at, :utc_datetime, null: false)
        end

        create table(:<%= o_sub %>_subscription, primary_key: false) do
          add(:<%= o_sub %>_stripe_subscription_id, :text)
          add(:<%= o_sub %>_status, :text, default: "active")
          add(:<%= o_sub %>_current_period_start, :utc_datetime)
          add(:<%= o_sub %>_current_period_end, :utc_datetime)
          add(:<%= o_sub %>_trial_end, :utc_datetime)
          add(:<%= o_sub %>_cancel_at, :utc_datetime)
          add(:<%= o_sub %>_cancelled_at, :utc_datetime)
          add(:<%= o_sub %>_custom, :map, default: fragment("'{}'::jsonb"))

          add(
            :<%= o_sub %>_customer_id,
            references(:<%= o_cus %>_customer,
              column: :<%= o_cus %>_id,
              name: "<%= o_sub %>_subscription_<%= o_sub %>_customer_id_fkey",
              type: :uuid,
              prefix: "public"
            )
          )

          add(
            :<%= o_sub %>_plan_id,
            references(:<%= o_plan %>_plan,
              column: :<%= o_plan %>_id,
              name: "<%= o_sub %>_subscription_<%= o_sub %>_plan_id_fkey",
              type: :uuid,
              prefix: "public"
            )
          )

          add(:<%= o_sub %>_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
          add(:<%= o_sub %>_org_id, :uuid, null: false)
          add(:<%= o_sub %>_inserted_at, :utc_datetime, null: false)
          add(:<%= o_sub %>_updated_at, :utc_datetime, null: false)
        end

        create table(:<%= o_invoice %>_invoice, primary_key: false) do
          add(:<%= o_invoice %>_stripe_invoice_id, :text)
          add(:<%= o_invoice %>_status, :text, default: "draft")
          add(:<%= o_invoice %>_amount_due_cents, :integer, default: 0)
          add(:<%= o_invoice %>_amount_paid_cents, :integer, default: 0)
          add(:<%= o_invoice %>_currency, :text, default: "USD")
          add(:<%= o_invoice %>_period_start, :utc_datetime)
          add(:<%= o_invoice %>_period_end, :utc_datetime)
          add(:<%= o_invoice %>_due_date, :utc_datetime)
          add(:<%= o_invoice %>_paid_at, :utc_datetime)
          add(:<%= o_invoice %>_line_items, {:array, :map}, default: fragment("ARRAY[]::jsonb[]"))
          add(:<%= o_invoice %>_custom, :map, default: fragment("'{}'::jsonb"))

          add(
            :<%= o_invoice %>_customer_id,
            references(:<%= o_cus %>_customer,
              column: :<%= o_cus %>_id,
              name: "<%= o_invoice %>_invoice_<%= o_invoice %>_customer_id_fkey",
              type: :uuid,
              prefix: "public"
            )
          )

          add(
            :<%= o_invoice %>_subscription_id,
            references(:<%= o_sub %>_subscription,
              column: :<%= o_sub %>_id,
              name: "<%= o_invoice %>_invoice_<%= o_invoice %>_subscription_id_fkey",
              type: :uuid,
              prefix: "public"
            )
          )

          add(:<%= o_invoice %>_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
          add(:<%= o_invoice %>_org_id, :uuid, null: false)
          add(:<%= o_invoice %>_inserted_at, :utc_datetime, null: false)
          add(:<%= o_invoice %>_updated_at, :utc_datetime, null: false)
        end

        create table(:<%= o_pay %>_payment, primary_key: false) do
          add(:<%= o_pay %>_stripe_payment_intent_id, :text)
          add(:<%= o_pay %>_status, :text, default: "pending")
          add(:<%= o_pay %>_amount_cents, :integer, null: false)
          add(:<%= o_pay %>_currency, :text, default: "USD")
          add(:<%= o_pay %>_payment_method_type, :text, default: "card")
          add(:<%= o_pay %>_last4, :text)
          add(:<%= o_pay %>_paid_at, :utc_datetime)
          add(:<%= o_pay %>_failure_code, :text)
          add(:<%= o_pay %>_custom, :map, default: fragment("'{}'::jsonb"))

          add(
            :<%= o_pay %>_invoice_id,
            references(:<%= o_invoice %>_invoice,
              column: :<%= o_invoice %>_id,
              name: "<%= o_pay %>_payment_<%= o_pay %>_invoice_id_fkey",
              type: :uuid,
              prefix: "public"
            )
          )

          add(
            :<%= o_pay %>_customer_id,
            references(:<%= o_cus %>_customer,
              column: :<%= o_cus %>_id,
              name: "<%= o_pay %>_payment_<%= o_pay %>_customer_id_fkey",
              type: :uuid,
              prefix: "public"
            )
          )

          add(:<%= o_pay %>_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
          add(:<%= o_pay %>_org_id, :uuid, null: false)
          add(:<%= o_pay %>_inserted_at, :utc_datetime, null: false)
          add(:<%= o_pay %>_updated_at, :utc_datetime, null: false)
        end

        create table(:<%= o_usage %>_usage, primary_key: false) do
          add(:<%= o_usage %>_metric, :text, null: false)
          add(:<%= o_usage %>_quantity, :integer, default: 0)
          add(:<%= o_usage %>_period_start, :utc_datetime)
          add(:<%= o_usage %>_period_end, :utc_datetime)
          add(:<%= o_usage %>_reported_at, :utc_datetime)

          add(
            :<%= o_usage %>_subscription_id,
            references(:<%= o_sub %>_subscription,
              column: :<%= o_sub %>_id,
              name: "<%= o_usage %>_usage_<%= o_usage %>_subscription_id_fkey",
              type: :uuid,
              prefix: "public"
            )
          )

          add(:<%= o_usage %>_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
          add(:<%= o_usage %>_org_id, :uuid, null: false)
          add(:<%= o_usage %>_inserted_at, :utc_datetime, null: false)
          add(:<%= o_usage %>_updated_at, :utc_datetime, null: false)
        end

        create table(:<%= o_ent %>_entitlement, primary_key: false) do
          add(:<%= o_ent %>_feature, :text, null: false)
          add(:<%= o_ent %>_granted, :boolean, default: true)
          add(:<%= o_ent %>_expires_at, :utc_datetime)
          add(:<%= o_ent %>_custom, :map, default: fragment("'{}'::jsonb"))

          add(
            :<%= o_ent %>_subscription_id,
            references(:<%= o_sub %>_subscription,
              column: :<%= o_sub %>_id,
              name: "<%= o_ent %>_entitlement_<%= o_ent %>_subscription_id_fkey",
              type: :uuid,
              prefix: "public"
            )
          )

          add(
            :<%= o_ent %>_plan_id,
            references(:<%= o_plan %>_plan,
              column: :<%= o_plan %>_id,
              name: "<%= o_ent %>_entitlement_<%= o_ent %>_plan_id_fkey",
              type: :uuid,
              prefix: "public"
            )
          )

          add(:<%= o_ent %>_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
          add(:<%= o_ent %>_org_id, :uuid, null: false)
          add(:<%= o_ent %>_inserted_at, :utc_datetime, null: false)
          add(:<%= o_ent %>_updated_at, :utc_datetime, null: false)
        end

        # --- Subscription-movement ledger (`mov`; ADR-017) — append-only, no PII,
        #     soft id refs (no FK: the immutable ledger outlives its subscription row) ---
        create table(:<%= o_sev %>_subscription_event, primary_key: false) do
          add(:<%= o_sev %>_subscription_id, :uuid, null: false)
          add(:<%= o_sev %>_customer_id, :uuid)
          add(:<%= o_sev %>_plan_id, :uuid)
          add(:<%= o_sev %>_from_plan_id, :uuid)
          add(:<%= o_sev %>_kind, :text, null: false)
          add(:<%= o_sev %>_mrr_delta_cents, :integer, null: false, default: 0)
          add(:<%= o_sev %>_mrr_before_cents, :integer, null: false, default: 0)
          add(:<%= o_sev %>_mrr_after_cents, :integer, null: false, default: 0)
          add(:<%= o_sev %>_from_status, :text)
          add(:<%= o_sev %>_to_status, :text)
          add(:<%= o_sev %>_reason, :text, default: "status_change")
          add(:<%= o_sev %>_occurred_at, :utc_datetime, null: false)
          add(:<%= o_sev %>_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
          add(:<%= o_sev %>_org_id, :uuid, null: false)
          add(:<%= o_sev %>_inserted_at, :utc_datetime, null: false)
          add(:<%= o_sev %>_updated_at, :utc_datetime, null: false)
        end

        # =====================================================================
        # SUPPORT — the SaaS help desk (tenants file tickets WITH the SaaS)
        # =====================================================================

        create table(:<%= o_sla %>_sla, primary_key: false) do
          add(:<%= o_sla %>_name, :text, null: false)
          add(:<%= o_sla %>_label, :text)
          add(:<%= o_sla %>_first_response_minutes, :integer, default: 60)
          add(:<%= o_sla %>_resolve_minutes, :integer, default: 480)
          add(:<%= o_sla %>_priority, :text, default: "normal")
          add(:<%= o_sla %>_enabled, :boolean, default: true)
          add(:<%= o_sla %>_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
          add(:<%= o_sla %>_org_id, :uuid, null: false)
          add(:<%= o_sla %>_inserted_at, :utc_datetime, null: false)
          add(:<%= o_sla %>_updated_at, :utc_datetime, null: false)
        end

        # The ticket's custom bag carries the requester back-references
        # (`requester_org_id` → account Org, `requester_user_id` → tenant-admin User).
        create table(:<%= o_tick %>_ticket, primary_key: false) do
          add(:<%= o_tick %>_subject, :text, null: false)
          add(:<%= o_tick %>_status, :text, default: "open")
          add(:<%= o_tick %>_priority, :text, default: "normal")
          add(:<%= o_tick %>_sla_breach_at, :utc_datetime)
          add(:<%= o_tick %>_breached, :boolean, default: false, null: false)
          add(:<%= o_tick %>_resolved_at, :utc_datetime)
          add(:<%= o_tick %>_closed_at, :utc_datetime)
          add(:<%= o_tick %>_tags, {:array, :text}, default: [])
          add(:<%= o_tick %>_custom, :map, default: fragment("'{}'::jsonb"))
          add(:<%= o_tick %>_external_id, :text)

          add(
            :<%= o_tick %>_sla_id,
            references(:<%= o_sla %>_sla,
              column: :<%= o_sla %>_id,
              name: "<%= o_tick %>_ticket_<%= o_tick %>_sla_id_fkey",
              type: :uuid,
              prefix: "public"
            )
          )

          add(:<%= o_tick %>_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
          add(:<%= o_tick %>_org_id, :uuid, null: false)
          add(:<%= o_tick %>_inserted_at, :utc_datetime, null: false)
          add(:<%= o_tick %>_updated_at, :utc_datetime, null: false)
        end

        create(
          index(:<%= o_tick %>_ticket, [:<%= o_tick %>_sla_breach_at, :<%= o_tick %>_breached],
            name: "<%= o_tick %>_ticket_sla_breach_idx",
            where: "<%= o_tick %>_sla_breach_at IS NOT NULL AND <%= o_tick %>_breached = false"
          )
        )

        create table(:<%= o_conv %>_conversation, primary_key: false) do
          add(:<%= o_conv %>_channel, :text, default: "email")
          add(:<%= o_conv %>_status, :text, default: "open")
          add(:<%= o_conv %>_subject, :text)

          add(
            :<%= o_conv %>_ticket_id,
            references(:<%= o_tick %>_ticket,
              column: :<%= o_tick %>_id,
              name: "<%= o_conv %>_conversation_<%= o_conv %>_ticket_id_fkey",
              type: :uuid,
              prefix: "public"
            ),
            null: false
          )

          add(:<%= o_conv %>_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
          add(:<%= o_conv %>_org_id, :uuid, null: false)
          add(:<%= o_conv %>_inserted_at, :utc_datetime, null: false)
          add(:<%= o_conv %>_updated_at, :utc_datetime, null: false)
        end

        # The SaaS support AGENT 🔒 (the SaaS's own employee — CLEAR on its own plane).
        create table(:<%= o_agent %>_agent, primary_key: false) do
          add(:<%= o_agent %>_handle, :text)
          add(:<%= o_agent %>_status, :text, default: "active")
          add(:<%= o_agent %>_role, :text, default: "agent")
          add(:<%= o_agent %>_external_id, :text)
          add(:<%= o_agent %>_timezone, :text)
          add(:<%= o_agent %>_custom, :map, default: fragment("'{}'::jsonb"))
          add(:<%= o_agent %>_full_name, :text)
          add(:pii_<%= o_agent %>_email, :text)
          add(:<%= o_agent %>_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
          add(:<%= o_agent %>_org_id, :uuid, null: false)
          add(:<%= o_agent %>_inserted_at, :utc_datetime, null: false)
          add(:<%= o_agent %>_updated_at, :utc_datetime, null: false)
        end

        create table(:<%= o_msg %>_message, primary_key: false) do
          add(:<%= o_msg %>_sender_type, :text, default: "customer")
          add(:<%= o_msg %>_sender_id, :uuid)
          add(:<%= o_msg %>_message_type, :text, default: "reply")
          add(:<%= o_msg %>_attachments, {:array, :text}, default: [])
          add(:<%= o_msg %>_created_via, :text, default: "web")
          add(:pii_<%= o_msg %>_body, :text)

          add(
            :<%= o_msg %>_conversation_id,
            references(:<%= o_conv %>_conversation,
              column: :<%= o_conv %>_id,
              name: "<%= o_msg %>_message_<%= o_msg %>_conversation_id_fkey",
              type: :uuid,
              prefix: "public"
            ),
            null: false
          )

          add(
            :<%= o_msg %>_agent_id,
            references(:<%= o_agent %>_agent,
              column: :<%= o_agent %>_id,
              name: "<%= o_msg %>_message_<%= o_msg %>_agent_id_fkey",
              type: :uuid,
              prefix: "public"
            )
          )

          add(:<%= o_msg %>_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
          add(:<%= o_msg %>_org_id, :uuid, null: false)
          add(:<%= o_msg %>_inserted_at, :utc_datetime, null: false)
          add(:<%= o_msg %>_updated_at, :utc_datetime, null: false)
        end

        create table(:<%= o_macro %>_macro, primary_key: false) do
          add(:<%= o_macro %>_name, :text, null: false)
          add(:<%= o_macro %>_description, :text)
          add(:<%= o_macro %>_body_template, :text)
          add(:<%= o_macro %>_tags, {:array, :text}, default: [])
          add(:<%= o_macro %>_enabled, :boolean, default: true)
          add(:<%= o_macro %>_category, :text)
          add(:<%= o_macro %>_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
          add(:<%= o_macro %>_org_id, :uuid, null: false)
          add(:<%= o_macro %>_inserted_at, :utc_datetime, null: false)
          add(:<%= o_macro %>_updated_at, :utc_datetime, null: false)
        end

        create table(:<%= o_csat %>_csat, primary_key: false) do
          add(:<%= o_csat %>_score, :integer, null: false)
          add(:<%= o_csat %>_comments, :text)
          add(:<%= o_csat %>_channel, :text, default: "email")
          add(:<%= o_csat %>_responded_at, :utc_datetime)

          add(
            :<%= o_csat %>_ticket_id,
            references(:<%= o_tick %>_ticket,
              column: :<%= o_tick %>_id,
              name: "<%= o_csat %>_csat_<%= o_csat %>_ticket_id_fkey",
              type: :uuid,
              prefix: "public"
            ),
            null: false
          )

          add(
            :<%= o_csat %>_agent_id,
            references(:<%= o_agent %>_agent,
              column: :<%= o_agent %>_id,
              name: "<%= o_csat %>_csat_<%= o_csat %>_agent_id_fkey",
              type: :uuid,
              prefix: "public"
            )
          )

          add(:<%= o_csat %>_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
          add(:<%= o_csat %>_org_id, :uuid, null: false)
          add(:<%= o_csat %>_inserted_at, :utc_datetime, null: false)
          add(:<%= o_csat %>_updated_at, :utc_datetime, null: false)
        end

        catalog_sync(@resources)
      end

      def down do
        catalog_sync_down(@resources)

        # --- Support (reverse FK order) ---
        drop(constraint(:<%= o_csat %>_csat, "<%= o_csat %>_csat_<%= o_csat %>_agent_id_fkey"))
        drop(constraint(:<%= o_csat %>_csat, "<%= o_csat %>_csat_<%= o_csat %>_ticket_id_fkey"))
        drop(table(:<%= o_csat %>_csat))
        drop(table(:<%= o_macro %>_macro))
        drop(constraint(:<%= o_msg %>_message, "<%= o_msg %>_message_<%= o_msg %>_agent_id_fkey"))
        drop(constraint(:<%= o_msg %>_message, "<%= o_msg %>_message_<%= o_msg %>_conversation_id_fkey"))
        drop(table(:<%= o_msg %>_message))
        drop(table(:<%= o_agent %>_agent))
        drop(constraint(:<%= o_conv %>_conversation, "<%= o_conv %>_conversation_<%= o_conv %>_ticket_id_fkey"))
        drop(table(:<%= o_conv %>_conversation))
        drop(index(:<%= o_tick %>_ticket, [:<%= o_tick %>_sla_breach_at, :<%= o_tick %>_breached], name: "<%= o_tick %>_ticket_sla_breach_idx"))
        drop(constraint(:<%= o_tick %>_ticket, "<%= o_tick %>_ticket_<%= o_tick %>_sla_id_fkey"))
        drop(table(:<%= o_tick %>_ticket))
        drop(table(:<%= o_sla %>_sla))

        # --- Billing (reverse FK order; ledger has no FKs) ---
        drop(table(:<%= o_sev %>_subscription_event))
        drop(constraint(:<%= o_ent %>_entitlement, "<%= o_ent %>_entitlement_<%= o_ent %>_plan_id_fkey"))
        drop(constraint(:<%= o_ent %>_entitlement, "<%= o_ent %>_entitlement_<%= o_ent %>_subscription_id_fkey"))
        drop(table(:<%= o_ent %>_entitlement))
        drop(constraint(:<%= o_usage %>_usage, "<%= o_usage %>_usage_<%= o_usage %>_subscription_id_fkey"))
        drop(table(:<%= o_usage %>_usage))
        drop(constraint(:<%= o_pay %>_payment, "<%= o_pay %>_payment_<%= o_pay %>_customer_id_fkey"))
        drop(constraint(:<%= o_pay %>_payment, "<%= o_pay %>_payment_<%= o_pay %>_invoice_id_fkey"))
        drop(table(:<%= o_pay %>_payment))
        drop(constraint(:<%= o_invoice %>_invoice, "<%= o_invoice %>_invoice_<%= o_invoice %>_subscription_id_fkey"))
        drop(constraint(:<%= o_invoice %>_invoice, "<%= o_invoice %>_invoice_<%= o_invoice %>_customer_id_fkey"))
        drop(table(:<%= o_invoice %>_invoice))
        drop(constraint(:<%= o_sub %>_subscription, "<%= o_sub %>_subscription_<%= o_sub %>_plan_id_fkey"))
        drop(constraint(:<%= o_sub %>_subscription, "<%= o_sub %>_subscription_<%= o_sub %>_customer_id_fkey"))
        drop(table(:<%= o_sub %>_subscription))
        drop(constraint(:<%= o_price %>_price, "<%= o_price %>_price_<%= o_price %>_plan_id_fkey"))
        drop(table(:<%= o_price %>_price))
        drop(table(:<%= o_plan %>_plan))
        drop(table(:<%= o_cus %>_customer))

        # --- Identity (reverse FK order) ---
        drop(constraint(:<%= o_key %>_api_key, "<%= o_key %>_api_key_<%= o_key %>_membership_id_fkey"))
        drop(table(:<%= o_key %>_api_key))
        drop(table(:<%= o_invite %>_invitation))
        drop(table(:<%= o_role %>_role))
        drop(constraint(:<%= o_mem %>_membership, "<%= o_mem %>_membership_<%= o_mem %>_user_id_fkey"))
        drop(table(:<%= o_mem %>_membership))
        drop(table(:<%= o_user %>_user))
        drop(table(:<%= o_org %>_org))
      end
    end
    '''
  end

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

  defp readme_web do
    """
    # <%= module %>

    A Samen vertical app scaffolded by `mix samen.gen.app` (T6.4 + WS-D D2 / ADR-022). It
    mounts the samen_core Billing scope AS-IS, authors one vertical resource
    (`<%= module %>.Vertical.Record`, abbrev `<%= abbrev %>`) with a scalar
    `pii_<%= abbrev %>_secret` vault field, defines a token-blind aggregate projection,
    and ships a RUNNING web product: the router mounts the inherited Billing pages, the
    notifications inbox and the ADR-010 operator workspace from samen_web — zero authored
    LiveView modules.

    ## Run it

        mix deps.get
        MIX_ENV=dev mix ecto.create && MIX_ENV=dev mix ecto.migrate
        mix phx.server

    Then open http://localhost:<%= http_port %> — the landing page links every inherited
    surface; `/healthz` is the liveness probe.

    ## Verifier gate

        MIX_ENV=test bash ci.sh

    Runs the FULL samen_core verifier gate (catalog parity, prefixes, pii_reads, pii_classify,
    no_plaintext_pii, migrations, sink_schema, metric_labels, vault_declared_parity,
    tnt_catalog, tnt_boundary, same_org_fk, no_pii_columns, aggregate_privacy) + the default
    test suite + the anti-tautology probe on the vault path.

    This app is **correct-by-construction**: it passes its own gate on first run.

    ## Abbrevs

    This app's storage abbrevs are permanently reserved in
    `<%= samen_core_path %>/priv/abbrev_registry.json` (the global registry): Billing scope
    (`<%= bc %>/<%= bs %>/<%= bl %>/<%= bp %>/<%= bi %>/<%= by %>/<%= bu %>/<%= be %>`), the
    authored resource (`<%= abbrev %>`), the aggregate plane (`<%= agg_abbrev %>`), the
    Primitives mount (`<%= p_nt %>/<%= p_np %>/<%= p_fl %>/<%= p_sh %>/<%= p_wh %>/<%= p_ff %>`)
    and the operator namespace (`<%= o_org %>…/<%= o_cus %>…/<%= o_tick %>…` — the
    per-plane first-letter convention).
    """
  end

  # ==================================================================== WS-D D3: --api
  # The public JSON:API templates (ADR-022). Parametrized ports of the SHIPPED references:
  # demo's `demo_web/api/` (AshJsonApi router / Plug endpoint / KeyAuthPlug) and the
  # demo Contact / driftwood Driver `json_api` DENY-BY-DEFAULT allowlist + bounded
  # `:api_read` idiom. The page-limit clamp is the CANONICAL `Samen.Web.Api.PageLimitClamp`
  # (samen_web is a dep of every --api app) — inherited, NEVER re-emitted (design §3).

  # ------------------------------------------------------------------ mix.exs (api)
  defp mix_exs_api do
    """
    defmodule <%= module %>.MixProject do
      use Mix.Project

      # <%= module %> — a Samen vertical app scaffolded by `mix samen.gen.app` (T6.4 + WS-D D2/D3).
      # Shaped like demo/driftwood/pawchart: mounts the samen_core Billing scope AS-IS,
      # authors one vertical resource (<%= module %>.Vertical.Record) with a pii_ scalar
      # vault field, defines one token-blind aggregate projection, and runs the FULL
      # samen_core verifier gate in its own ci.sh. With the web layer (ADR-022, default ON)
      # it is a RUNNING product: the router mounts the inherited Billing / Notifications /
      # Operator LiveViews from samen_web, and the public `/api/v1` JSON:API serves the
      # authored resource behind a deny-by-default allowlist. Correct-by-construction:
      # green on first `bash ci.sh`, booting on first `mix phx.server`.
      def project do
        [
          app: :<%= otp_app %>,
          version: "0.1.0",
          elixir: "~> 1.18",
          elixirc_paths: elixirc_paths(Mix.env()),
          consolidate_protocols: Mix.env() != :test,
          start_permanent: Mix.env() == :prod,
          deps: deps(),
          aliases: aliases()
        ]
      end

      def application do
        [
          extra_applications: [:logger],
          mod: {<%= module %>.Application, []}
        ]
      end

      defp elixirc_paths(:test), do: ["lib", "test/support"]
      defp elixirc_paths(_), do: ["lib"]

      defp deps do
        [
          {:samen_core, path: "<%= samen_core_path %>"},
          # ADR-009 — the framework UI library. The router mounts the inherited
          # Billing/Notifications/Operator LiveViews from samen_web, so the entire
          # inherited product UI is framework-level, not per-vertical.
          {:samen_web, path: "<%= samen_web_path %>"},
          {:phoenix, "~> 1.7"},
          {:phoenix_live_view, "~> 1.0"},
          {:phoenix_html, "~> 4.1"},
          # Bandit: the HTTP adapter behind <%= module %>Web.Endpoint.
          {:bandit, "~> 1.0"},
          {:phoenix_pubsub, "~> 2.1"},
          # The public JSON:API surface (OD-6 — AshJsonApi ONLY): the generated
          # `/api/v1` router + serializer over the SAME Ash resources the UI uses.
          {:ash_json_api, "~> 1.7"},
          {:jason, "~> 1.4"},
          {:stream_data, "~> 1.3"},
          # simple_sat: the Ash policy authorizer's pure-Elixir SAT solver, needed by the
          # mounted Billing scope's OrgScope policies + the authored resource's policies.
          {:simple_sat, "~> 0.1"},
          # WS-D D5 observability (ADR-022): opentelemetry_ecto is listed DIRECTLY (not
          # relied on transitively) so the `no_plaintext_pii` LogTelemetry tier — which
          # reads `Mix.Project.config[:deps]`, not transitive apps — SEES the OTel-Ecto
          # leak surface and asserts `db_statement: :disabled` on it. Dropping that config
          # then flips the gate (the D6 flagship sabotage). The API+SDK ride transitively
          # from samen_core; only the Ecto integration must be a direct dep to arm the tier.
          {:opentelemetry_ecto, "~> 1.2"}
        ]
      end

      defp aliases, do: []
    end
    """
  end

  # ------------------------------------------------------------------ vertical (api)
  defp vertical_ex_api do
    """
    defmodule <%= module %>.Vertical do
      @moduledoc \"\"\"
      <%= module %>'s vertical-authored domain — the "20%" this app writes itself.

      Ships ONE authored resource, `<%= module %>.Vertical.Record`, a Tier-3 code
      composition (`use Samen.Resource`, abbrev `<%= abbrev %>`) that inherits the ENTIRE
      substrate — abbrev storage, vault routing, masking, OrgScope, catalog parity, audit,
      crypto-shred — with no vertical infrastructure code. It carries a SCALAR pii_ vault
      field (`pii_<%= abbrev %>_secret`) to exercise the vault/mask/reveal path end to end.

      WS-D D3 — `AshJsonApi.Domain` makes this domain routable (it generates the
      `json_api_match_route/2` dispatcher the AshJsonApi controller calls): the public
      `/api/v1` surface serves Record behind its deny-by-default `json_api` allowlist.
      \"\"\"
      use Ash.Domain, validate_config_inclusion?: false, extensions: [AshJsonApi.Domain]

      resources do
        resource(<%= module %>.Vertical.Record)
      end
    end

    defmodule <%= module %>.Vertical.Record do
      @moduledoc \"\"\"
      The authored vertical record (abbrev `<%= abbrev %>`), with:

        * `pii_<%= abbrev %>_secret` — a SCALAR pii_ vault field
          (`pii_attribute :secret, :string, vault: :pii_secret`). Masked `••••` by default;
          plaintext only via `:reveal_<%= abbrev %>` under a distinct-party grant;
          crypto-shreddable with the record. The column name is what the storage
          transformer produces from the abbrev + the pii_ scalar rule.
        * `name` / `segment` — plain non-PII columns (`segment` is the aggregate cohort key).
        * OrgScope on every action.
        * a public JSON:API surface (WS-D D3) behind a DENY-BY-DEFAULT allowlist bound to
          the BOUNDED `:api_read`.
      \"\"\"
      use Samen.Resource,
        otp_app: :<%= otp_app %>,
        domain: <%= module %>.Vertical,
        data_layer: AshPostgres.DataLayer,
        authorizers: [Ash.Policy.Authorizer],
        extensions: [AshJsonApi.Resource],
        abbrev: "<%= abbrev %>"

      postgres do
        table("<%= resource_table %>")
        repo(<%= module %>.Repo)
      end

      # WS-D D3 — the public API surface over the authored resource (the demo Contact /
      # driftwood Driver idiom).
      #
      # ALLOWLIST (opt-in, default not-exposed). `show_fields` is the load-bearing
      # control: a field NOT named here is ABSENT from every payload, even via `?fields=`
      # (AshJsonApi filters the final field set through `show_field?`, which requires
      # `field in show_fields`). The names are CATALOG names (`:name`, `:segment`) —
      # never storage names (`<%= abbrev %>_name`, `pii_<%= abbrev %>_secret`).
      #
      # Deliberately NOT allowlisted:
      #   * `secret` — the vault field. A PII field enters the public payload only by a
      #     CONSCIOUS builder opt-in (add it to `show_fields`; it then serializes per
      #     plane via `Samen.Api.PiiResolution` — tenant clear, operator masked/absent).
      #     The gen'd red-path test proves it is absent by omission.
      #   * `org_id` — the tenant boundary (internal routing, absent by omission).
      json_api do
        type("record")
        show_fields([:id, :name, :segment])

        # F3.7 — make the FILTER surface match the SERIALIZATION surface: AshJsonApi
        # derives `?filter[…]` from ALL public attributes by default — including one kept
        # OFF `show_fields` (a hit/miss side channel over a de-allowlisted field).
        # Turning `derive_filter?` off closes it; cross-org is already defended by
        # OrgScope's FilterCheck. (SORT needs no flag: AshJsonApi validates `?sort=`
        # against `show_field?/2` already.)
        derive_filter?(false)

        routes do
          base("/records")
          # Bind the public routes to the BOUNDED `:api_read` (keyset pagination,
          # default_limit 50 / max_page_size 200) — the API is bounded by default
          # (WS-A design §1.1, ADR-016 §3).
          get(:api_read)
          index(:api_read)
        end
      end

      attributes do
        attribute(:name, :string, public?: true)
        attribute(:segment, :string, public?: true)
      end

      pii do
        vault(:pii_secret)
        pii_attribute(:secret, :string, vault: :pii_secret)
        reveal(:reveal_<%= abbrev %>)
      end

      # The inherited two-key-class PII-resolution rule on all reads.
      preparations do
        prepare(Samen.Api.PiiResolution)
      end

      actions do
        defaults([:read, :destroy, create: :*, update: :*])

        # BOUNDED-by-default API read (WS-A design §1.1, ADR-016 §3): a SEPARATE read
        # action the JSON:API `index`/`get` routes bind to, with keyset pagination —
        # default_limit 50 / max_page_size 200 / paginate_by_default? true. A no-page
        # index read returns a BOUNDED page (never the full set); a `page[limit]` above
        # max_page_size is CLAMPED (`Samen.Web.Api.PageLimitClamp` in the endpoint),
        # never honored. Kept DISTINCT from the plain `:read` so internal callers keep
        # returning a plain list — the API bound does not leak into internal reads.
        read :api_read do
          pagination(
            keyset?: true,
            default_limit: 50,
            max_page_size: 200,
            required?: false,
            paginate_by_default?: true
          )
        end

        action :reveal_<%= abbrev %>, :map do
          argument(:actor_id, :string, allow_nil?: false)
          argument(:subject_id, :string, allow_nil?: false)

          run(fn input, _ctx ->
            ctx = %Samen.Reveal.Context{
              actor: input.arguments.actor_id,
              subject_id: input.arguments.subject_id,
              resource: __MODULE__,
              action: :reveal_<%= abbrev %>,
              label: :secret
            }

            if Samen.Reveal.grant_checker().granted?(ctx) do
              {:ok, %{status: "granted", subject_id: input.arguments.subject_id}}
            else
              {:error, :denied}
            end
          end)
        end
      end

      policies do
        policy action_type([:read, :create, :update, :destroy]) do
          authorize_if(Samen.Policy.OrgScope)
        end

        policy action(:reveal_<%= abbrev %>) do
          authorize_if(always())
        end
      end
    end
    """
  end

  # ------------------------------------------------------------------ host router (api)
  defp router_ex_api do
    """
    defmodule <%= module %>Web.Router do
      @moduledoc \"\"\"
      The <%= module %> host router (ADR-009 reuse proof, scaffolded by `mix samen.gen.app`).

      The ENTIRE product UI is MOUNTED from samen_web via `Samen.Web.Router` macros —
      zero <%= module %> LiveView modules authored:

        * `samen_module_routes(:billing, ...)` — the authored scope's inherited pages
          (overview / invoices / plans),
        * `samen_notifications_routes(...)` — the framework notifications inbox
          (+ /notifications/settings) over the Primitives mount,
        * `samen_operator_routes(...)` — the ADR-010 operator workspace (accounts ·
          platform billing · revenue · flags · analytics · desk) over the operator
          namespace; the `flags_namespace` label activates the flag admin over this
          app's FeatureFlag rows,
        * `samen_session_routes()` — the ADR-013 current-org session write (the
          workspace switcher + the operator "Open account →" target).

      The public JSON:API (WS-D D3) is FORWARDED to `<%= module %>Web.Api.Endpoint`
      under the versioned `/api/v1` namespace.
      \"\"\"
      use Phoenix.Router
      import Phoenix.LiveView.Router
      import Samen.Web.Router

      pipeline :browser do
        plug(:accepts, ["html"])
        plug(:fetch_session)
        plug(:put_root_layout, html: {<%= module %>Web.Layouts, :root})
        plug(:protect_from_forgery)
      end

      # WS-D D3 — the versioned public API surface. `forward` sends `/api/v1/*` to the
      # AshJsonApi endpoint (key-auth → page-limit clamp → the generated JSON:API router
      # over `<%= module %>.Vertical`). The declared route `/records` is reached at
      # `/api/v1/records` externally — the stable public contract (doc §external-surface
      # "explicitly versioned, URL-namespaced, e.g. /api/v1").
      forward("/api/v1", <%= module %>Web.Api.Endpoint)

      scope "/", <%= module %>Web do
        pipe_through(:browser)

        get("/", PageController, :index)
        get("/healthz", PageController, :healthz)
        get("/readyz", PageController, :readyz)
      end

      # The inherited product UI, MOUNTED from samen_web. BARE `scope "/"` (no
      # `<%= module %>Web` alias): the mounted LiveViews are the framework's own
      # `Samen.Web.*` modules — aliasing under `<%= module %>Web` would wrongly resolve them.
      scope "/" do
        pipe_through(:browser)

        # ADR-013 §4.3 — the framework SESSION-write endpoint (`GET /session/org/:org_id`).
        samen_session_routes()

        # 1. Billing — the mounted samen_core Billing scope's inherited pages.
        samen_module_routes(:billing, <%= module %>.Billing, repo: <%= module %>.Repo)

        # 2. Notifications (WS-A A4/A5) — the framework inbox (+ /notifications/settings),
        #    mounted over the Primitives mount in ONE line. Realtime rides
        #    `<%= module %>.PubSub` (id-only envelopes).
        samen_notifications_routes(:notifications, <%= module %>.Primitives,
          repo: <%= module %>.Repo,
          labels: %{pubsub: <%= module %>.PubSub}
        )

        # 3. Metrics egress (WS-F5 F5.1) — the framework `GET /metrics` Prometheus
        #    scrape endpoint over `Samen.Metrics.definitions/0`. OFF by default: the
        #    route self-gates to 404 until `metrics_egress?` is set (see
        #    config/runtime.exs → SAMEN_METRICS_ENABLED). Name matches the reporter
        #    Samen.Observability starts (`:<%= otp_app %>_prometheus`).
        samen_metrics_route(name: :<%= otp_app %>_prometheus)
      end

      # ADR-010 — the OPERATOR / SaaS-company workspace, mounted in ONE line over the
      # operator namespace (accounts ARE tenant orgs). The operator seat reads the
      # operator org's OWN book of business on the TENANT plane (clear); drilling into
      # a tenant is the existing masked impersonation path.
      scope "/" do
        pipe_through(:browser)

        samen_operator_routes(<%= module %>.Operator,
          repo: <%= module %>.Repo,
          labels: %{
            operator_workspace: "<%= module %> Ops",
            # WS-B B6 — the FlagAdminLive namespace seam: the Primitives mount whose
            # FeatureFlag rows the platform flag admin manages.
            flags_namespace: <%= module %>.Primitives
          }
        )
      end
    end
    """
  end

  # ------------------------------------------------------------------ api tree
  defp api_router_ex do
    """
    defmodule <%= module %>Web.Api.Router do
      @moduledoc \"\"\"
      The public JSON:API router (WS-D D3; OD-6 — AshJsonApi ONLY).

      This is the generated AshJsonApi router over the SAME Ash resources the LiveView UI
      and the operator plane use — one write path, one policy stack, one catalog (doc
      §external-surface). It is URL-versioned: the top-level router forwards `/api/v1` to
      this pipeline (see `<%= module %>Web.Api.Endpoint`), so every route here lives under
      `/api/v1` (`/api/v1/records`, `/api/v1/records/:id`).

      ## Governed both ways

      Inbound requests carry a plane-bearing actor set by `<%= module %>Web.Api.KeyAuthPlug`
      (the api_key → actor resolver), so the SAME Ash policies (OrgScope + RBAC) run for an
      API request as for a UI request, and the SAME `Samen.Api.PiiResolution` egress rule
      applies. The router itself is a thin AshJsonApi plug; the authorization is the
      resources' own policy stack.

      ## Allowlist serialization

      Field exposure is opt-in per resource (`json_api do show_fields … end`). A field
      absent from a resource's allowlist is absent from every payload — including the
      vault field (`secret`) and a newly added storage column (default not-exposed). See
      the resource `json_api` block (<%= module %>.Vertical.Record).
      \"\"\"
      use AshJsonApi.Router,
        domains: [<%= module %>.Vertical],
        prefix: "/api/v1"
    end
    """
  end

  defp api_endpoint_ex do
    """
    defmodule <%= module %>Web.Api.Endpoint do
      @moduledoc \"\"\"
      The mounted public API entry point (WS-D D3). This is the plug pipeline the host
      Phoenix router forwards `/api/v1` to:

          forward "/api/v1", <%= module %>Web.Api.Endpoint

      Pipeline order:

        1. `<%= module %>Web.Api.KeyAuthPlug` — resolve the `Authorization: Bearer <key>`
           into a plane-bearing actor (the two key classes), or set no actor (fail closed).
        2. `Samen.Web.Api.PageLimitClamp` — clamp `page[limit]` to max_page_size BEFORE
           AshJsonApi (the upstream Ash to_page raw-limit-split workaround). The CANONICAL
           framework plug — samen_web is a dep, so it is inherited, never re-emitted.
        3. `<%= module %>Web.Api.Router` — the generated AshJsonApi router over the SAME
           Ash resources. It runs the resources' own policy stack (OrgScope + RBAC) and
           the `Samen.Api.PiiResolution` read preparation (the two-plane PII rule).

      The operator-plane masking (vaulted field absent without a grant) is enforced at the
      RECORD level by `Samen.Api.PiiResolution` (it sets forbidden fields to
      `%Ash.ForbiddenField{}`, which the serializer omits) — not by a response rewrite.
      The field is gone before the JSON is ever built ("absent by omission" is structural).
      \"\"\"
      use Plug.Builder

      plug(<%= module %>Web.Api.KeyAuthPlug)
      plug(Samen.Web.Api.PageLimitClamp)
      plug(<%= module %>Web.Api.Router)
    end
    """
  end

  defp api_key_auth_plug_ex do
    """
    defmodule <%= module %>Web.Api.KeyAuthPlug do
      @moduledoc \"\"\"
      Resolve the inbound `Authorization: Bearer <api_key>` into a `%Samen.Scope{}`-style
      actor and set it on the conn (WS-D D3; doc §external-surface "two key classes").

      ## The two key classes (doc §external-surface)

      An api_key row (`<%= module %>.Operator.ApiKey` — the operator Identity mount's
      credential, ADR-010) is bound to exactly one of two planes; the SAME Ash policy
      stack + the SAME `Samen.Api.PiiResolution` egress rule gate both:

        * `:tenant`   — org-bound. Acts as the tenant over its OWN org's data. Reads its
          own org's allowlisted PII in CLEAR per its RBAC, with NO operator reveal grant
          (the reveal seam is operator-scoped). The actor carries the key's `org_id`, so
          OrgScope isolates it to that org — a cross-org request returns zero rows.
        * `:operator` — the control-plane / cross-tenant class. Masked by default: a
          subject's vaulted plaintext is ABSENT unless a live operator reveal grant covers
          it (`Samen.Api.PiiResolution` → `%Ash.ForbiddenField{}`, omitted).

      ## The actor shape

      The built actor is the canonical actor map (`id`/`org_id`/`role`) the policies read,
      PLUS `:plane` (drives the masking rule) and `:api_key` (the `Samen.Scope.ApiKey` key
      map so `Samen.Scope.ApiKey.authorized?/4` can enforce the key's declared scopes AND
      the actor ceiling — a key can never out-reach the membership that minted it). The
      actor's `:role` is the key's `minter_role`.

      ## Digest, not plaintext

      The key row stores only a SHA-256 digest of the key (`token_digest`); the raw key is
      shown once at mint and never persisted in clear. This plug digests the presented
      bearer token the same way and looks the row up by digest.

      Fail closed: a missing/malformed/unknown/revoked key sets NO actor. Downstream, an
      actor-less request hits the org-scope policy's nil-org branch and sees zero rows.
      \"\"\"
      import Plug.Conn
      require Ash.Query

      @doc "The canonical key digest — SHA-256 hex of the raw key material."
      @spec digest(String.t()) :: String.t()
      def digest(raw) when is_binary(raw) do
        :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
      end

      @behaviour Plug

      @impl true
      def init(opts), do: opts

      @impl true
      def call(conn, _opts) do
        with {:ok, raw} <- bearer_token(conn),
             {:ok, key_row} <- lookup_key(raw),
             {:ok, actor} <- build_actor(key_row) do
          conn
          |> Ash.PlugHelpers.set_actor(actor)
          # Stash the actor on a private assign too so downstream layers can read the
          # plane without re-resolving the key.
          |> put_private(:samen_api_actor, actor)
        else
          # Fail closed: no valid key → no actor. The org-scope policy denies (nil org).
          _ -> conn
        end
      end

      # --- key resolution ------------------------------------------------------

      defp bearer_token(conn) do
        case get_req_header(conn, "authorization") do
          ["Bearer " <> raw | _] when byte_size(raw) > 0 -> {:ok, raw}
          _ -> :error
        end
      end

      defp lookup_key(raw) do
        digest = digest(raw)

        # Look up the api_key row by digest, unauthorized (this IS the auth step — the
        # key row lookup cannot itself require an actor). A revoked key (revoked_at set)
        # is rejected.
        <%= module %>.Operator.ApiKey
        |> Ash.Query.filter(token_digest == ^digest)
        |> Ash.Query.filter(is_nil(revoked_at))
        |> Ash.read_one(authorize?: false)
        |> case do
          {:ok, nil} -> :error
          {:ok, key_row} -> {:ok, key_row}
          {:error, _} -> :error
        end
      end

      defp build_actor(key_row) do
        # The membership that minted this key carries (user_id, org_id, role). Load it to
        # resolve the actor's org boundary — selecting the attributes we read so they are
        # not %Ash.NotLoaded{}. The key's own `plane`/`scopes`/`minter_role` come off the
        # key row.
        membership_query =
          <%= module %>.Operator.Membership
          |> Ash.Query.select([:id, :org_id, :user_id, :role])

        case Ash.load(key_row, [membership: membership_query], authorize?: false) do
          {:ok, %{membership: %{} = mbr} = key_row} ->
            org_id = fetch(mbr, [:org_id, :<%= o_mem %>_org_id])
            user_id = fetch(mbr, [:user_id, :<%= o_mem %>_user_id])

            key = %{
              org_id: org_id,
              plane: key_row.plane,
              scopes: key_row.scopes || %{},
              minter_role: key_row.minter_role
            }

            actor = %{
              id: user_id,
              org_id: org_id,
              role: key_row.minter_role,
              plane: key_row.plane,
              api_key: key
            }

            {:ok, actor}

          _ ->
            :error
        end
      end

      defp fetch(source, keys) do
        Enum.find_value(keys, fn k ->
          if is_map(source) and Map.has_key?(source, k), do: Map.get(source, k)
        end)
      end
    end
    """
  end

  # ------------------------------------------------------------------ api test support
  defp api_case_ex do
    ~S'''
    defmodule <%= module %>.ApiCase do
      @moduledoc """
      Test helpers for the public JSON:API (WS-D D3). Seeds org-scoped records + api_keys
      (the two classes, minted through the operator Identity mount) and drives the
      `<%= module %>Web.Api.Endpoint` pipeline (key-auth → page-limit clamp → AshJsonApi
      router) via `Plug.Test`.

      Requests are driven with the FULL `/api/v1/…` request path (the AshJsonApi router
      carries `prefix: "/api/v1"` and matches on the request path), so the versioned
      external contract a tenant integrates against is exercised end-to-end.
      """
      use ExUnit.CaseTemplate

      using do
        quote do
          import Plug.Conn
          import Plug.Test
          import <%= module %>.ApiCase
        end
      end

      setup do
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(<%= module %>.Repo)
        Ecto.Adapters.SQL.Sandbox.mode(<%= module %>.Repo, {:shared, self()})
        :ok
      end

      # --- seeding -------------------------------------------------------------

      def mk_org, do: Ecto.UUID.generate()

      @doc """
      Seed an authored Record in `org_id`. `secret` defaults to a recognizable plaintext
      so the masked/absent assertions are unambiguous.
      """
      def mk_record(org_id, attrs \\ %{}) do
        base = %{
          org_id: org_id,
          name: Map.get(attrs, :name, "Record"),
          segment: Map.get(attrs, :segment, "alpha"),
          secret: Map.get(attrs, :secret, "SECRET-CLEAR-#{System.unique_integer([:positive])}")
        }

        {:ok, record} =
          <%= module %>.Vertical.Record
          |> Ash.Changeset.for_create(:create, base)
          |> Ash.create(authorize?: false)

        record
      end

      def mk_user(org_id, handle) do
        {:ok, user} =
          <%= module %>.Operator.User
          |> Ash.Changeset.for_create(:create, %{
            handle: handle,
            org_id: org_id,
            full_name: %{first: handle, last: "L"},
            emails: ["#{handle}@example.com"]
          })
          |> Ash.create(authorize?: false)

        user
      end

      def mk_membership(org_id, user_id, role \\ :admin) do
        {:ok, mbr} =
          <%= module %>.Operator.Membership
          |> Ash.Changeset.for_create(:create, %{role: role, org_id: org_id, user_id: user_id})
          |> Ash.create(authorize?: false)

        mbr
      end

      @doc """
      Mint an api_key and return `{raw_key, key_row}`. `plane` is `:tenant | :operator`.
      Creates a backing user + membership in `org_id` so the auth resolver can load the
      minter's org boundary.
      """
      def mk_api_key(org_id, opts \\ []) do
        plane = Keyword.get(opts, :plane, :tenant)
        minter_role = Keyword.get(opts, :minter_role, :admin)
        scopes = Keyword.get(opts, :scopes, %{"vertical" => ["read"]})

        user = mk_user(org_id, "keymaster-#{System.unique_integer([:positive])}")
        mbr = mk_membership(org_id, user.id, minter_role)

        raw = "sk_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
        digest = <%= module %>Web.Api.KeyAuthPlug.digest(raw)

        {:ok, key} =
          <%= module %>.Operator.ApiKey
          |> Ash.Changeset.for_create(:create, %{
            plane: plane,
            scopes: scopes,
            minter_role: minter_role,
            org_id: org_id,
            membership_id: mbr.id
          })
          # token_digest is public?: false (a credential digest, not tenant input), so it
          # is not accepted by `create: :*`. Force-change it as the mint step would.
          |> Ash.Changeset.force_change_attribute(:token_digest, digest)
          |> Ash.create(authorize?: false)

        {raw, key}
      end

      # --- driving -------------------------------------------------------------

      @doc """
      GET the versioned public API at `/api/v1<path>` (JSON:API), optionally with a bearer
      `key`. Drives the `<%= module %>Web.Api.Endpoint` pipeline.
      """
      def api_get(path, key \\ nil) do
        conn =
          Plug.Test.conn(:get, "/api/v1" <> path)
          |> Plug.Conn.put_req_header("accept", "application/vnd.api+json")

        conn =
          if key,
            do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> key),
            else: conn

        # Simulate the host router's `forward("/api/v1", …)`: it STRIPS the `/api/v1`
        # prefix into `script_name` before the AshJsonApi endpoint sees the request, so
        # the AshJsonApi router (prefix "/api/v1") matches the declared route
        # (`/records`). `Plug.Test.conn` has already split the query string off
        # `path_info`, so dropping the first two segments is query-safe. This exercises
        # the SAME endpoint pipeline (key-auth → clamp → AshJsonApi) a real forwarded
        # request hits; `request_path` still carries the full `/api/v1/…` contract.
        conn = %{conn | script_name: ["api", "v1"], path_info: Enum.drop(conn.path_info, 2)}

        <%= module %>Web.Api.Endpoint.call(conn, <%= module %>Web.Api.Endpoint.init([]))
      end

      @doc "Decode a JSON:API response body to a map."
      def json(conn), do: Jason.decode!(conn.resp_body)
    end
    '''
  end

  # ------------------------------------------------------------------ api red-path test
  defp record_api_test do
    ~S'''
    defmodule <%= module %>.RecordApiTest do
      @moduledoc """
      The GENERATED API red paths (WS-D D3 — AC-G4-2 / AC-G4-3):

        * BOUNDED by default — an index read with NO page params returns ≤ default_limit
          (50), never the full set (the `:api_read` keyset pagination);
        * CLAMPED at the cap — a hostile `page[limit]` above max_page_size (200) returns
          EXACTLY the cap (the `Samen.Web.Api.PageLimitClamp` e2e pattern);
        * DENY-BY-DEFAULT allowlist — a field absent from `show_fields` (the vault field
          `secret` lives ON the resource but NOT on the allowlist; `org_id` likewise) is
          ABSENT from every payload, even via `?fields=`; positive controls prove the
          allowlisted fields DO appear (absence is a real omission, not an empty payload).

      Anti-tautology posture: the pagination tests seed MORE rows than the probed limit,
      so "bounded"/"clamped" hold over a genuinely larger dataset.
      """
      use <%= module %>.ApiCase, async: false

      # A storage-name pattern the public payload must never leak: the abbrev-prefixed
      # column names and the vault prefixes/tokens the doc says the public schema hides.
      @storage_name_patterns [
        ~r/\b<%= abbrev %>_/,
        ~r/\bpii_/,
        ~r/\bvt_/
      ]

      describe "bounded-by-default pagination (the RP-G1-6 pattern)" do
        # Must exceed max_page_size (200) so the clamp test exercises the cap boundary —
        # with fewer rows than the cap, a raised/removed cap is unobservable.
        @seed 210

        setup do
          org = mk_org()
          for i <- 1..@seed, do: mk_record(org, %{name: "R#{i}"})
          {raw, _key} = mk_api_key(org, plane: :tenant)
          {:ok, org: org, key: raw, seed: @seed}
        end

        test "an index read with NO page params is BOUNDED by default_limit (never the full set)",
             %{key: key, seed: seed} do
          conn = api_get("/records", key)
          assert conn.status == 200

          data = json(conn)["data"]

          # Non-vacuity: we seeded MORE than the default page, so a bounded read must
          # return FEWER than the seeded count.
          assert seed > 50

          assert length(data) <= 50,
                 "an unbounded index read returned #{length(data)} rows — the " <>
                   "default_limit did not bound the read. It must return at most 50."

          assert length(data) == 50,
                 "default_limit 50 should fill the first page from #{seed} rows"
        end

        test "page[limit] ABOVE max_page_size returns EXACTLY the cap (PageLimitClamp e2e)",
             %{key: key, seed: seed} do
          conn = api_get("/records?page[limit]=10000", key)

          # Non-vacuity: the dataset exceeds the cap, so a clamped page is exactly the
          # cap — a raised/removed cap (or a dropped clamp plug) would observably return
          # more.
          assert seed > 200
          assert conn.status == 200

          data = json(conn)["data"]

          assert length(data) == 200,
                 "page[limit]=10000 returned #{length(data)} rows — expected exactly the " <>
                   "max_page_size cap (200) over a #{seed}-row dataset."
        end

        test "an explicit small page[limit] is honored (positive control — pagination is live)",
             %{key: key} do
          conn = api_get("/records?page[limit]=5", key)
          assert conn.status == 200
          assert length(json(conn)["data"]) == 5
        end
      end

      describe "deny-by-default allowlist (AC-G4-3)" do
        setup do
          org = mk_org()
          secret = "SECRET-<%= abbrev %>-#{System.unique_integer([:positive])}"
          record = mk_record(org, %{name: "Visible One", segment: "alpha", secret: secret})
          {raw, _key} = mk_api_key(org, plane: :tenant)
          {:ok, org: org, key: raw, record: record, secret: secret}
        end

        test "a payload exposes ONLY the allowlisted catalog fields — the un-allowlisted vault field is ABSENT",
             %{key: key, org: org, secret: secret} do
          conn = api_get("/records", key)
          assert conn.status == 200
          %{"data" => [record | _]} = json(conn)

          attrs = record["attributes"]

          # Positive control: the allowlisted non-PII fields ARE present (not vacuous).
          assert Map.has_key?(attrs, "name")
          assert Map.has_key?(attrs, "segment")
          assert attrs["name"] == "Visible One"

          # `type` is the catalog name, never the storage table (`<%= resource_table %>`).
          assert record["type"] == "record"

          # THE RED PATH: `secret` is a field ON the resource but NOT in `show_fields` —
          # absent by omission, and its plaintext value appears nowhere in the body.
          refute Map.has_key?(attrs, "secret"),
                 "un-allowlisted vault field `secret` appeared in the API payload"

          refute conn.resp_body =~ secret, "the vault plaintext leaked into the payload"

          # `org_id` is a PUBLIC Ash attribute (CoreAttributes injects it). Without
          # `show_fields` it WOULD appear. It is deliberately NOT allowlisted → absent.
          refute Map.has_key?(attrs, "org_id"),
                 "un-allowlisted public attribute `org_id` appeared in the API payload"

          refute conn.resp_body =~ org, "the org_id value leaked into the payload"

          # The whole payload carries no storage/vault name anywhere.
          for pattern <- @storage_name_patterns do
            refute Regex.match?(pattern, conn.resp_body),
                   "storage name #{inspect(pattern)} leaked into the API payload"
          end
        end

        test "the ?fields= query param cannot force an un-allowlisted field to appear",
             %{key: key, secret: secret} do
          # A caller asks for `secret` explicitly. `show_fields` is the SCHEMA-level
          # allowlist, so `?fields=` can NEVER widen past it. AshJsonApi fails closed:
          # either it REJECTS the request naming an un-shown field (4xx), or it returns
          # 200 with the field absent. Both outcomes prove the plaintext never escapes.
          conn = api_get("/records?fields[record]=secret,name", key)

          if conn.status == 200 do
            %{"data" => [record | _]} = json(conn)

            refute Map.has_key?(record["attributes"], "secret"),
                   "?fields= forced the un-allowlisted vault field to appear"
          else
            assert conn.status in 400..499
          end

          refute conn.resp_body =~ secret, "the vault plaintext leaked via ?fields="
        end
      end
    end
    '''
  end

  # ------------------------------------------------------------------ ci.sh (api)
  defp ci_sh_api do
    ~S'''
    #!/usr/bin/env bash
    # <%= module %> CI gate — the FULL samen_core verifier gate, run against the mounted
    # Billing scope + the authored vertical resource (<%= module %>.Vertical.Record) + the
    # token-blind aggregate plane + the public /api/v1 JSON:API contract (WS-D D3).
    # Scaffolded by `mix samen.gen.app` (T6.4) — correct-by-construction: green on first run.
    #
    # Exit: 0 = all green, non-zero = first failure.

    set -euo pipefail

    export MIX_ENV="${MIX_ENV:-test}"

    APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    cd "$APP_DIR"

    echo "==> <%= otp_app %> CI gate: starting (MIX_ENV=$MIX_ENV)"

    echo "--- step 1/18: mix compile --warnings-as-errors"
    mix compile --warnings-as-errors
    echo "    PASSED"

    echo "--- step 1a/18: DB bootstrap (migrate)"
    mix run --no-start priv/ci_bootstrap.exs
    echo "    PASSED"

    echo "--- step 1b/18: schema.dict.json drift check"
    COMMITTED_DICT="$APP_DIR/schema.dict.json"
    FRESH_DICT="$(mktemp /tmp/<%= otp_app %>_schema_dict_XXXXXX.json)"
    trap 'rm -f "$FRESH_DICT"' EXIT

    mix samen.catalog.dump --output "$FRESH_DICT"

    if ! diff -q "$COMMITTED_DICT" "$FRESH_DICT" > /dev/null 2>&1; then
      echo "    FAILED: schema.dict.json is stale — run 'mix samen.catalog.dump --output schema.dict.json' and commit."
      diff "$COMMITTED_DICT" "$FRESH_DICT" || true
      exit 1
    fi
    echo "    PASSED (schema.dict.json matches regenerated output)"

    echo "--- step 2/18: mix samen.verify.catalog_parity"
    mix samen.verify.catalog_parity
    echo "    PASSED"

    echo "--- step 3/18: mix samen.verify.prefixes"
    mix samen.verify.prefixes
    echo "    PASSED"

    echo "--- step 4/18: mix samen.verify.pii_reads"
    mix samen.verify.pii_reads
    echo "    PASSED"

    echo "--- step 5/18: mix samen.verify.pii_classify"
    mix samen.verify.pii_classify --baseline "$COMMITTED_DICT"
    echo "    PASSED"

    echo "--- step 6/18: mix samen.verify.no_plaintext_pii"
    mix samen.verify.no_plaintext_pii
    echo "    PASSED"

    echo "--- step 7/18: mix samen.verify.migrations"
    mix samen.verify.migrations
    echo "    PASSED"

    echo "--- step 8/18: mix samen.verify.sink_schema"
    mix samen.verify.sink_schema
    echo "    PASSED"

    echo "--- step 9/18: mix samen.verify.metric_labels"
    mix samen.verify.metric_labels
    echo "    PASSED"

    echo "--- step 10/18: mix samen.verify.vault_declared_parity"
    mix samen.verify.vault_declared_parity
    echo "    PASSED"

    echo "--- step 11/18: mix samen.verify.tnt_catalog"
    mix samen.verify.tnt_catalog
    echo "    PASSED"

    echo "--- step 12/18: mix samen.verify.tnt_boundary"
    mix samen.verify.tnt_boundary
    echo "    PASSED"

    echo "--- step 13/18: mix samen.verify.same_org_fk"
    mix samen.verify.same_org_fk
    echo "    PASSED"

    echo "--- step 14/18: mix samen.verify.no_pii_columns"
    mix samen.verify.no_pii_columns
    echo "    PASSED"

    echo "--- step 15/18: mix samen.verify.aggregate_privacy"
    mix samen.verify.aggregate_privacy
    echo "    PASSED"

    # C6 api_contract structural-break check (WS-D D3): the committed api_contract.v1.json
    # pins the /api/v1 routes + the deny-by-default `show_fields` allowlist. Deleting an
    # exposed field / dropping a route is an UN-VERSIONED break — the gate flips.
    echo "--- step 16/18: mix samen.verify.api_contract --version v1"
    mix samen.verify.api_contract --version v1 --snapshot "$APP_DIR/api_contract.v1.json"
    echo "    PASSED"

    echo "--- step 17/18: mix test (default suite)"
    mix test --warnings-as-errors
    echo "    PASSED"

    echo "--- step 18/18: anti-tautology probe (pii_<%= abbrev %>_secret vault path)"
    mix run priv/anti_tautology_probe.exs
    echo "    PASSED"

    echo ""
    echo "==> <%= otp_app %> CI gate: ALL PASSED"
    '''
  end

  # ------------------------------------------------------------------ seeds (D4)
  defp seeds_ex do
    ~S'''
    defmodule <%= module %>.Seeds do
      @moduledoc """
      <%= module %> dev-data seeds (WS-D D4 / AC-G4-4), vault-aware BY CONSTRUCTION.

      Seeds write through `Samen.Factory.create!/3` — the SAME `Ash.Changeset.for_create`
      path a real tenant write takes — so every seeded 🔒 field routes through the
      `Samen.Vault.Change` chokepoint: the domain row holds a `vt_*` token, `pii_vault`
      holds the ciphertext, and a raw-SQL scan of the seeded rows finds NO plaintext. No
      subject-key or reveal boilerplate. This is the shipped `Samen.Web.SampleData` idiom
      as a runnable seed (matches pawchart's `PawChart.Seeds`).

      Run via `mix <%= otp_app %>.seed` (which starts the app first).
      """

      alias <%= module %>.Vertical.Record

      # A stable dev tenant org so the seeded rows are addressable on the LiveView URLs
      # (`?org=<uuid>`) and the JSON:API (a tenant key minted for this org reads them).
      @org_id "<%= operator_org_id %>"

      @doc """
      Seed the dev DB with a handful of `<%= module %>.Vertical.Record` rows for the
      `#{@org_id}` tenant. The 🔒 `secret` field on each is vault-routed. Returns the org id.
      """
      @spec run() :: String.t()
      def run do
        for {name, segment, secret} <- records() do
          Samen.Factory.create!(
            Record,
            %{org_id: @org_id, name: name, segment: segment, secret: secret},
            authorize?: false
          )
        end

        @org_id
      end

      @doc "The seed dataset — `{name, segment, 🔒 secret}` tuples."
      def records do
        [
          {"Northwind Record", "alpha", "seed-secret-northwind-01"},
          {"Contoso Record", "alpha", "seed-secret-contoso-02"},
          {"Fabrikam Record", "beta", "seed-secret-fabrikam-03"}
        ]
      end

      @doc "The dev tenant org id the seeds anchor on."
      def org_id, do: @org_id
    end
    '''
  end

  defp seed_task_ex do
    ~S'''
    defmodule Mix.Tasks.<%= module %>.Seed do
      @shortdoc "Seed the dev DB for <%= module %> (vault-aware, via Samen.Factory)"
      @moduledoc """
      Seed the <%= module %> DEV database with sample `Vertical.Record` rows so the
      inherited pages + the `/api/v1` JSON:API render REAL data. Every seeded 🔒 field is
      vault-routed (WS-D D4). Mirrors `mix pawchart.seed`.

          MIX_ENV=dev mix <%= otp_app %>.seed

      Prints the seeded org id; use `?org=<uuid>` on the LiveView URLs.
      """
      use Mix.Task

      @requirements ["app.start"]

      @impl Mix.Task
      def run(_args) do
        org_id = <%= module %>.Seeds.run()
        Mix.shell().info("Seeded <%= module %> dev tenant org: #{org_id}")
        Mix.shell().info("Open: /billing?org=#{org_id}")
        Mix.shell().info("API:  GET /api/v1/records (Bearer <tenant api_key for #{org_id}>)")
        org_id
      end
    end
    '''
  end

  defp seeds_vault_test do
    ~S'''
    defmodule <%= module %>.SeedsVaultTest do
      @moduledoc """
      WS-D D4 red path (AC-G4-4): the seed idiom is vault-aware BY CONSTRUCTION.

      `<%= module %>.Seeds.run/0` writes through `Samen.Factory` (the `SampleData` vault
      path). This test runs the seeds, then scans the RAW domain rows and proves:

        * every seeded 🔒 `secret` column holds a `vt_*` token, NOT the plaintext;
        * NONE of the seeded plaintext secrets appear anywhere in the domain table.

      Non-vacuity: the assertion names the EXACT plaintext strings the seeds wrote, so a
      seed that skipped the vault (a raw column write) would leave the plaintext at rest
      and flip this test to fail. Positive control: the token prefix `vt_` IS present.
      """
      use <%= module %>.DataCase, async: false

      alias <%= module %>.Repo

      test "seeded 🔒 secrets are vault-routed — plaintext nowhere at rest" do
        org_id = <%= module %>.Seeds.run()
        assert org_id == <%= module %>.Seeds.org_id()

        seeded_plaintexts =
          <%= module %>.Seeds.records() |> Enum.map(fn {_n, _s, secret} -> secret end)

        # Raw scan of the physical vault column on the domain table for THIS org.
        org_dumped = Ecto.UUID.dump!(org_id)

        %{rows: rows} =
          Ecto.Adapters.SQL.query!(
            Repo,
            "SELECT pii_<%= abbrev %>_secret FROM <%= resource_table %> " <>
              "WHERE <%= abbrev %>_org_id = $1",
            [org_dumped]
          )

        raw_secrets = Enum.map(rows, fn [raw] -> raw end)

        assert length(raw_secrets) == length(seeded_plaintexts),
               "expected #{length(seeded_plaintexts)} seeded rows, got #{length(raw_secrets)}"

        # Every stored value is a vault token, and NO seeded plaintext leaked.
        for raw <- raw_secrets do
          assert is_binary(raw) and String.starts_with?(raw, "vt_"),
                 "seeded secret column holds #{inspect(raw)}, expected a vt_* token — " <>
                   "the seed bypassed the vault (AC-G4-4 violation)"

          for plaintext <- seeded_plaintexts do
            refute raw == plaintext,
                   "seeded plaintext #{inspect(plaintext)} is at rest in the domain row " <>
                     "(the seed did NOT route through the vault)"
          end
        end
      end
    end
    '''
  end

  # ------------------------------------------------------------------ README (api)
  defp readme_api do
    """
    # <%= module %>

    A Samen vertical app scaffolded by `mix samen.gen.app` (T6.4 + WS-D D2/D3 / ADR-022). It
    mounts the samen_core Billing scope AS-IS, authors one vertical resource
    (`<%= module %>.Vertical.Record`, abbrev `<%= abbrev %>`) with a scalar
    `pii_<%= abbrev %>_secret` vault field, defines a token-blind aggregate projection,
    and ships a RUNNING web product: the router mounts the inherited Billing pages, the
    notifications inbox and the ADR-010 operator workspace from samen_web — zero authored
    LiveView modules — plus the public `/api/v1` JSON:API over the authored resource.

    ## Run it

        mix deps.get
        MIX_ENV=dev mix ecto.create && MIX_ENV=dev mix ecto.migrate
        mix phx.server

    Then open http://localhost:<%= http_port %> — the landing page links every inherited
    surface; `/healthz` is the liveness probe.

    ## The public API (`/api/v1`)

    `GET /api/v1/records` (JSON:API) — key-authed (`Authorization: Bearer <api_key>`, the
    two key classes over the operator Identity mount), BOUNDED by default (keyset
    pagination, default_limit 50 / max_page_size 200 — an over-max `page[limit]` is
    CLAMPED by the inherited `Samen.Web.Api.PageLimitClamp`), and DENY-BY-DEFAULT
    serialized: a field absent from the resource's `json_api show_fields` allowlist is
    absent from every payload (the vault field `secret` and `org_id` are deliberately not
    allowlisted). The committed `api_contract.v1.json` pins the contract; the gate's
    `samen.verify.api_contract` step fails on un-versioned structural breaks.

    ## Verifier gate

        MIX_ENV=test bash ci.sh

    Runs the FULL samen_core verifier gate (catalog parity, prefixes, pii_reads, pii_classify,
    no_plaintext_pii, migrations, sink_schema, metric_labels, vault_declared_parity,
    tnt_catalog, tnt_boundary, same_org_fk, no_pii_columns, aggregate_privacy, api_contract)
    + the default test suite (incl. the gen'd API bounded/clamp/allowlist red paths) + the
    anti-tautology probe on the vault path.

    This app is **correct-by-construction**: it passes its own gate on first run.

    ## Abbrevs

    This app's storage abbrevs are permanently reserved in
    `<%= samen_core_path %>/priv/abbrev_registry.json` (the global registry): Billing scope
    (`<%= bc %>/<%= bs %>/<%= bl %>/<%= bp %>/<%= bi %>/<%= by %>/<%= bu %>/<%= be %>`), the
    authored resource (`<%= abbrev %>`), the aggregate plane (`<%= agg_abbrev %>`), the
    Primitives mount (`<%= p_nt %>/<%= p_np %>/<%= p_fl %>/<%= p_sh %>/<%= p_wh %>/<%= p_ff %>`)
    and the operator namespace (`<%= o_org %>…/<%= o_cus %>…/<%= o_tick %>…` — the
    per-plane first-letter convention).
    """
  end

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
  defp gitignore_deploy do
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
    # WS-D D10 (ADR-024): the mix release build output. Prod secrets are ENV-ONLY
    # (DATABASE_URL / SECRET_KEY_BASE / SAMEN_KMS_* — see config/runtime.exs); never
    # commit them to a *.secret.exs.
    /_build/prod/
    """
  end

  # ------------------------------------------------------------------ fly.toml
  # A valid-TOML Fly.io manifest. app/primary_region are placeholders the operator sets
  # (the runbook says so); `[http_service]` binds the endpoint port; the `[[http_service.checks]]`
  # hits `/readyz` (the emitted page_controller READINESS route — 200 only when Postgres, the
  # KMS wrapped-DEK store, and Oban all answer; a static-200 `/healthz` would let Fly send
  # traffic to a machine whose deps are down); `[deploy] release_command`
  # runs migrations via the release's eval. NOT a claim of a live app — see the runbook's
  # OPERATOR-TODO block (real Fly account is human work).
  defp fly_toml do
    """
    # <%= otp_app %> — Fly.io manifest (WS-D D10 / ADR-024). FAIL-HONEST scaffold:
    # structurally correct, but NOT a live deploy. Before `fly deploy` the operator must
    # complete docs/runbooks/deploy.md (real Fly account, `fly apps create`, the Neon
    # DATABASE_URL + SECRET_KEY_BASE + SAMEN_KMS_* secrets). `config/runtime.exs` RAISES on
    # a missing secret, so a half-configured app refuses to boot rather than come up
    # insecure. Set `app` and `primary_region` to your real values.
    app = "<%= otp_app %>"
    primary_region = "iad"

    [build]
      dockerfile = "Dockerfile"

    [deploy]
      # Runs the app's migrations before the new release takes traffic. `<%= module %>.Release`
      # is the release-safe migrator (config/runtime.exs is loaded; no Mix at runtime).
      release_command = "/app/bin/<%= otp_app %> eval <%= module %>.Release.migrate"

    [env]
      PHX_HOST = "<%= otp_app %>.fly.dev"
      PORT = "<%= http_port %>"

    [http_service]
      internal_port = <%= http_port %>
      force_https = true
      auto_stop_machines = "stop"
      auto_start_machines = true
      min_machines_running = 1

      [[http_service.checks]]
        interval = "15s"
        timeout = "2s"
        grace_period = "10s"
        method = "get"
        # READINESS, not liveness: 200 only when Postgres + KMS store + Oban all answer.
        path = "/readyz"

    [[vm]]
      size = "shared-cpu-1x"
      memory = "1gb"
    """
  end

  # ------------------------------------------------------------------ Dockerfile
  # A two-stage `mix release` build (elixir builder → slim debian runtime). Structurally
  # correct per Elixir/Phoenix release conventions; NOT `docker build`-proven in CI
  # (ADR-024 proof bound: compiles/parses + runtime raises + runbook names TODOs; no live
  # deploy assertion). The generated app is a SIBLING of samen_core/samen_web via `path:`
  # deps, so the build context note in the runbook explains the monorepo-root build.
  defp dockerfile do
    """
    # <%= module %> — production image (WS-D D10 / ADR-024). Two-stage mix release build.
    #
    # NOTE: this app depends on samen_core (+ samen_web) via `{:_, path: "..."}`, so the
    # Docker BUILD CONTEXT must be the monorepo root that contains samen_core/, samen_web/,
    # and <%= otp_app %>/ — not the app dir alone. See docs/runbooks/deploy.md §"Build context".
    # FAIL-HONEST: this Dockerfile is structurally correct but is NOT built in CI and does
    # not imply a live image; the operator builds + pushes it (an OPERATOR-TODO in the runbook).

    # Versions match the repo's gated toolchain (spikes/s00_smoke/VERSIONS.md) —
    # keep in sync when the toolchain moves (D9/D10 gate P2).
    ARG ELIXIR_VERSION=1.20.2
    ARG OTP_VERSION=29.0
    ARG DEBIAN_VERSION=bookworm-20250203-slim

    ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
    ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

    FROM ${BUILDER_IMAGE} AS builder

    RUN apt-get update -y \\
      && apt-get install -y build-essential git \\
      && apt-get clean && rm -f /var/lib/apt/lists/*_*

    WORKDIR /build

    ENV MIX_ENV="prod"

    RUN mix local.hex --force && mix local.rebar --force

    # The path deps must be present in the build context (monorepo root).
    COPY samen_core samen_core
    COPY samen_web samen_web
    COPY <%= otp_app %> <%= otp_app %>

    WORKDIR /build/<%= otp_app %>

    RUN mix deps.get --only prod
    RUN mix deps.compile
    RUN mix compile

    # config/runtime.exs is evaluated at BOOT (not build) — it is copied into the release.
    RUN mix release

    # ---- runtime image ----
    FROM ${RUNNER_IMAGE}

    RUN apt-get update -y \\
      && apt-get install -y libstdc++6 openssl libncurses5 locales ca-certificates \\
      && apt-get clean && rm -f /var/lib/apt/lists/*_*

    RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
    ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

    WORKDIR /app
    RUN chown nobody /app

    ENV MIX_ENV="prod"

    COPY --from=builder --chown=nobody:root /build/<%= otp_app %>/_build/prod/rel/<%= otp_app %> ./

    USER nobody

    CMD ["/app/bin/<%= otp_app %>", "start"]
    """
  end

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
  defp runtime_exs do
    """
    import Config

    # <%= module %> — production runtime configuration (WS-D D10 / ADR-024). Evaluated at
    # BOOT, so this is where prod SECRETS are read. FAIL-CLOSED: `fetch_secret!/2` RAISES a
    # named, actionable error on any missing required secret rather than booting a vaulted
    # SaaS insecurely. There is NO localhost/empty-password fallback here (that is dev only).
    #
    # NOT a live-deploy claim: the operator must provide the real values (Neon DATABASE_URL,
    # a generated SECRET_KEY_BASE, and the SAMEN_KMS_* keys). See docs/runbooks/deploy.md.

    # Fail-closed secret reader: raises a clear, named error naming the missing env var and
    # how to set it. This is the ADR-024 boot-honest guarantee — the app never comes up
    # half-secure.
    fetch_secret! = fn var, hint ->
      case System.get_env(var) do
        nil ->
          raise \"\"\"
          <%= module %> is missing the required secret environment variable \#{var}.

          The app refuses to boot without it (fail-closed — a vaulted SaaS must never come
          up half-secure). \#{hint}

          See docs/runbooks/deploy.md for the full secrets checklist.
          \"\"\"

        "" ->
          raise \"\"\"
          <%= module %> required secret environment variable \#{var} is set but EMPTY.

          An empty secret is treated as missing (fail-closed). \#{hint}
          \"\"\"

        value ->
          value
      end
    end

    if config_env() == :prod do
      # --- database (Neon per-product; branch-per-env — see the runbook) -----------------
      database_url =
        fetch_secret!.(
          "DATABASE_URL",
          "Set it to your Neon connection string, e.g. " <>
            "postgres://USER:PASS@HOST/<%= otp_app %>?sslmode=require"
        )

      maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

      config :<%= otp_app %>, <%= module %>.Repo,
        url: database_url,
        pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
        socket_options: maybe_ipv6,
        # Neon requires TLS; verify_none keeps the scaffold honest without shipping a CA
        # bundle assumption (the runbook flags hardening verify_full as an operator step).
        ssl: [verify: :verify_none]

      # --- endpoint (PHX_HOST + SECRET_KEY_BASE) -----------------------------------------
      secret_key_base =
        fetch_secret!.(
          "SECRET_KEY_BASE",
          "Generate one with `mix phx.gen.secret` (a >=64-byte random string)."
        )

      host =
        fetch_secret!.(
          "PHX_HOST",
          "Set it to the public hostname, e.g. <%= otp_app %>.fly.dev"
        )

      port = String.to_integer(System.get_env("PORT") || "<%= http_port %>")

      config :<%= otp_app %>, <%= module %>Web.Endpoint,
        url: [host: host, port: 443, scheme: "https"],
        http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: port],
        secret_key_base: secret_key_base,
        server: true

      # --- KMS env (SAMEN_KMS_*) — the vault's crypto keystore, the single most-forgotten
      # prod requirement for a vaulted app (ADR-024). Fail-closed on absence: the vault
      # cannot wrap/unwrap DEKs without it, so booting without it would be a silent
      # half-secure app. The AWS KMS + DynamoDB adapter (Samen.Kms.AwsKmsDynamo) is the
      # prod store; enabling it requires these keys.
      kms_key_id =
        fetch_secret!.(
          "SAMEN_KMS_KEY_ID",
          "The AWS KMS key id/ARN that wraps per-subject DEKs (Samen.Kms.AwsKmsDynamo). " <>
            "The vault cannot encrypt/decrypt PII without it."
        )

      kms_region =
        fetch_secret!.(
          "SAMEN_KMS_REGION",
          "The AWS region of the KMS key + the wrapped-DEK DynamoDB table (PITR OFF)."
        )

      config :samen_core, :kms_adapter, Samen.Kms.AwsKmsDynamo
      config :samen_core, :aws_kms_dynamo_enabled, true

      config :samen_core, Samen.Kms.AwsKmsDynamo,
        key_id: kms_key_id,
        region: kms_region

      # --- metrics egress (WS-F5 F5.1) — OFF unless SAMEN_METRICS_ENABLED is truthy ---
      # When on, Samen.Observability starts a Prometheus reporter (:<%= otp_app %>_prometheus)
      # over Samen.Metrics.definitions/0 and the framework `GET /metrics` route serves it.
      # Bounded-cardinality labels only (mix samen.verify.metric_labels) — no org/actor id
      # ever becomes a series label. Scrape it over Fly's PRIVATE network, not the public
      # internet (it is on the app port; front it with an internal-only scrape config).
      if System.get_env("SAMEN_METRICS_ENABLED") in ~w(true 1) do
        config :<%= otp_app %>, Samen.Observability,
          metrics_egress?: true,
          prometheus_reporter: TelemetryMetricsPrometheus.Core,
          prometheus_name: :<%= otp_app %>_prometheus
      end
    end
    """
  end

  # ------------------------------------------------------------------ lib/<app>/release.ex
  # The release-safe migrator `fly.toml`'s `release_command` invokes (`<app> eval
  # <module>.Release.migrate`). No Mix at runtime — it loads the app and runs the same
  # `Ecto.Migrator.run(Repo, :up, all: true)` the ci_bootstrap uses, so a prod deploy
  # applies the substrate + resource migrations before taking traffic.
  defp release_ex do
    """
    defmodule <%= module %>.Release do
      @moduledoc \"\"\"
      Release tasks for <%= module %> (WS-D D10 / ADR-024). Invoked by the release binary
      (`bin/<%= otp_app %> eval <%= module %>.Release.migrate`) — NO Mix at runtime.

      `fly.toml`'s `release_command` calls `migrate/0` before a new release takes traffic.
      \"\"\"
      @app :<%= otp_app %>

      def migrate do
        load_app()

        {:ok, _, _} =
          Ecto.Migrator.with_repo(<%= module %>.Repo, fn repo ->
            Ecto.Migrator.run(repo, :up, all: true)
          end)
      end

      defp load_app do
        Application.load(@app)
      end
    end
    """
  end

  # ------------------------------------------------------------------ docs/runbooks/deploy.md
  # The HONEST operator runbook (AC-G16-3). Neon branch-per-env provisioning, the secrets
  # checklist (incl. KMS + SECRET_KEY_BASE generation), and an explicit OPERATOR-TODO block
  # naming the four human prerequisites: real Fly account, real Neon project, real KMS keys,
  # real OTLP exporter. The structural doc test asserts this block exists with all four named
  # items (AC-G16-3). No aspirational "just run `fly deploy`".
  defp deploy_runbook do
    """
    # Deploying <%= module %> (Fly.io + Neon)

    Scaffolded by `mix samen.gen.app --deploy` (WS-D D10 / ADR-024). These artifacts are
    **fail-honest**: structurally correct, but a fresh generation has NO Fly account, NO Neon
    project, and NO KMS keys, so they do **not** claim a live deploy. `config/runtime.exs`
    **fails closed** — the app RAISES on any missing required secret rather than booting a
    vaulted SaaS half-secure. Everything below the "Operator TODO" line stays human work.

    ## Emitted artifacts

    | File | What it is |
    |---|---|
    | `fly.toml` | Fly manifest — `[http_service]` on port `<%= http_port %>`, `/healthz` check, a `release_command` running migrations. |
    | `Dockerfile` | Two-stage `mix release` build. **Build context = the monorepo root** (see below). |
    | `rel/env.sh.eex` | Release env shim (node name / cookie). |
    | `config/runtime.exs` | **Fail-closed** prod config: reads `DATABASE_URL`, `SECRET_KEY_BASE`, `PHX_HOST`, `SAMEN_KMS_KEY_ID`, `SAMEN_KMS_REGION`; raises a named error on any missing one. |

    ## Build context

    <%= module %> depends on `samen_core` (and `samen_web`) via `{:_, path: "..."}`. The
    Docker build therefore needs the **monorepo root** (the dir containing `samen_core/`,
    `samen_web/`, and `<%= otp_app %>/`) as its build context, not the app dir alone:

        fly deploy --dockerfile <%= otp_app %>/Dockerfile --config <%= otp_app %>/fly.toml .

    run from the monorepo root (`.`).

    ## Neon per-product database (branch-per-env)

    Provision ONE Neon project per product, and use Neon **branches** for environments so
    each env has an isolated copy that shares the parent's schema:

    1. Create a Neon project for `<%= otp_app %>`.
    2. Create a branch per environment: `main` (prod), `staging`, and ephemeral PR branches.
       Each branch yields its own `DATABASE_URL`.
    3. The connection string is your `DATABASE_URL` secret (below). Neon requires TLS
       (`?sslmode=require`); `config/runtime.exs` sets `ssl: [verify: :verify_none]` — harden
       to `verify_full` with a CA bundle as an operator step.
    4. Migrations run automatically on deploy via `fly.toml`'s `release_command`.

    ## Secrets checklist

    Set every secret before the first deploy — `config/runtime.exs` RAISES (fail-closed) if
    any is missing, naming the variable:

    - [ ] `DATABASE_URL` — the Neon connection string (`postgres://…/<%= otp_app %>?sslmode=require`).
    - [ ] `SECRET_KEY_BASE` — generate with `mix phx.gen.secret` (a ≥64-byte random string).
    - [ ] `PHX_HOST` — the public hostname (e.g. `<%= otp_app %>.fly.dev`).
    - [ ] `SAMEN_KMS_KEY_ID` — the AWS KMS key id/ARN that wraps per-subject DEKs. **The vault
          cannot encrypt/decrypt PII without it** — the single most-forgotten prod requirement.
    - [ ] `SAMEN_KMS_REGION` — the AWS region of the KMS key + the wrapped-DEK DynamoDB table.

    Set them on Fly with:

        fly secrets set DATABASE_URL=… SECRET_KEY_BASE=… PHX_HOST=… \\
          SAMEN_KMS_KEY_ID=… SAMEN_KMS_REGION=…

    ## Metrics egress (optional — WS-F5 F5.1)

    Prometheus scraping is **OFF by default**. To turn it on, set one env var:

        fly secrets set SAMEN_METRICS_ENABLED=true

    Then `config/runtime.exs` starts a Prometheus reporter (`:<%= otp_app %>_prometheus`)
    over `Samen.Metrics.definitions/0` and the framework `GET /metrics` route serves the
    text exposition. With the flag UNSET the route returns `404` and nothing is exported —
    the default is a true no-op.

    - **Bounded cardinality only.** `mix samen.verify.metric_labels` fails the build if any
      metric carries a raw `org_id`/`actor_id`/`subject_id` label — no per-tenant series.
    - **`/metrics` is on the app port.** Scrape it over Fly's **private** network (an
      internal scrape config / a Grafana Agent sidecar), NOT the public internet — do not
      add it to a public `[[http_service]]`. Front it with allow-listing if it must be
      reachable off the private net.

    ## Verify fail-closed (before you trust the deploy)

    Boot the release with a required secret UNSET and confirm it REFUSES to start with a
    named error (never a silent half-secure boot):

        # missing SAMEN_KMS_KEY_ID → must raise naming SAMEN_KMS_KEY_ID
        DATABASE_URL=… SECRET_KEY_BASE=… PHX_HOST=… SAMEN_KMS_REGION=… \\
          /app/bin/<%= otp_app %> eval ":ok"

    ## Operator TODO — the human prerequisites (NOT provided by this scaffold)

    These are deliberately **not** automated (ADR-024 — no live deploy claim). The scaffold is
    a fail-honest on-ramp, not a turnkey deploy. You must provide:

    1. **A real Fly account + app** — sign up, `fly auth login`, `fly apps create <%= otp_app %>`,
       and set `app`/`primary_region` in `fly.toml`. No Fly account exists in a fresh generation.
    2. **A real Neon project + DATABASE_URL** — create the project + branches (above) and set
       `DATABASE_URL`. No database is provisioned by this scaffold.
    3. **Real KMS keys** — create the AWS KMS key + the wrapped-DEK DynamoDB table (PITR OFF,
       per ADR-001) and set `SAMEN_KMS_KEY_ID` / `SAMEN_KMS_REGION`. The in-memory/file-backed
       dev KMS adapters are NOT for production; the vault needs a real keystore.
    4. **A real OTLP exporter** — the observability plane records token-only spans with
       `db_statement: :disabled`, but the wide-event OTLP sink is operator-wired (it defaults
       to `:none`). Point it at your real collector to see traces in production.

    Until all four are done, `fly deploy` is not expected to yield a running app — and
    `config/runtime.exs` will fail closed rather than pretend otherwise.
    """
  end
end
