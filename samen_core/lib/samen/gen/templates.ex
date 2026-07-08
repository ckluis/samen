defmodule Samen.Gen.Templates do
  @moduledoc """
  The templated file set for `mix samen.gen.app` (T6.4). Returns `{relative_path, contents}`
  pairs; both are run through `Samen.Gen.App.render/2` (a `<%= key %>` substitution — no EEx,
  so the generator carries no template-runtime dependency).

  Every template is a parametrized copy of the proven `pawchart` reference so the generated
  app is correct-by-construction: it passes the full samen_core verifier gate on first run.
  """

  @doc "The full ordered file set."
  def files do
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
          entitlement: "<%= be %>"
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
      Creates <%= module %>'s Billing scope (abbrevs <%= bc %>/<%= bs %>/<%= bl %>/<%= bp %>/<%= bi %>/<%= by %>/<%= bu %>/<%= be %>)
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
end
