defmodule Samen.Gen.PostTemplates do
  @moduledoc """
  Heredoc templates for the POST-APP generators (`mix samen.gen.scope` /
  `mix samen.gen.resource`; WS-D D7a). Same `<%= key %>` substitution engine as
  `Samen.Gen.Templates` (rendered by `Samen.Gen.App.render/2`) — no EEx, no new
  template engine (design.md §1.1 "Emission model").

  The emitted resource is the malleability-ladder DEFAULT (scope-authoring §7): a
  **Tier-0 config resource** — org-scoped reads, **admin-gated writes** (RoleAtLeast
  `:admin`), a bounded-enum `status` column, plain label columns, and ONE scalar
  `pii do` vault field so the vault-routing red path is non-vacuous. The four
  mandated G26 test files are thin `Samen.RedPath` macro calls (AC-G26-1); the
  policy-matrix and admin-gate reds are bound to the REAL Ash authorizer, the
  vault-routing red to the REAL vault chokepoint, and the catalog-parity red to the
  REAL `catalog_parity` verifier — each with a positive control and a sabotage that
  flips it (anti-tautology; AC-G26-2/3).
  """

  # ===========================================================================
  # mix samen.gen.scope — the authored domain (namespace) module
  # ===========================================================================

  @doc "The emitted scope domain — an empty `Ash.Domain` gen.resource lands resources into."
  def scope_module do
    """
    defmodule <%= scope_module %> do
      @moduledoc \"\"\"
      <%= module %>'s `<%= scope %>` authored scope — a vertical namespace the app owns.

      Emitted by `mix samen.gen.scope` (WS-D D7a). Starts EMPTY;
      `mix samen.gen.resource --scope <%= scope %> --resource <Name> --abbrev <abc>`
      lands Tier-0 config resources into it (org-scoped, admin-gated writes, catalogued
      in the app's `tam_table`/`fld_field`, PII vault-routed) and wires each into the
      `resources do … end` block below. Registered in both `:ash_domains` lists so the
      verifier gate scans every resource mounted here.
      \"\"\"
      use Ash.Domain, validate_config_inclusion?: false

      resources do
      end
    end
    """
  end

  # ===========================================================================
  # mix samen.gen.resource — the Tier-0 resource module
  # ===========================================================================

  @doc "The emitted Tier-0 config resource (org-scoped, admin-gated writes, one vault field)."
  def resource_module do
    """
    defmodule <%= resource_module %> do
      @moduledoc \"\"\"
      <%= module %>'s authored `<%= resource %>` resource (abbrev `<%= abbrev %>`) —
      a Tier-0 config resource emitted by `mix samen.gen.resource` (WS-D D7a).

      Malleability ladder (scope-authoring §7): org-scoped reads
      (`Samen.Policy.OrgScope`), **admin-gated writes** (`Samen.Policy.RoleAtLeast`,
      role `:admin` — the bounded-enum + admin-gated Tier-0 shape), a bounded-enum
      `status`, plain non-PII label columns, and ONE scalar `pii do` vault field
      (`pii_<%= abbrev %>_secret`) so the whole vault/mask/reveal path is exercised.
      Inherits the ENTIRE substrate (abbrev storage, vault routing, masking, OrgScope,
      catalog parity, audit, crypto-shred) via `use Samen.Resource` — zero vertical
      infrastructure code.
      \"\"\"
      use Samen.Resource,
        otp_app: :<%= otp_app %>,
        domain: <%= scope_module %>,
        data_layer: AshPostgres.DataLayer,
        authorizers: [Ash.Policy.Authorizer],
        abbrev: "<%= abbrev %>"

      postgres do
        table("<%= table %>")
        repo(<%= module %>.Repo)
      end

      attributes do
        attribute(:name, :string, public?: true, allow_nil?: false)
        attribute(:label, :string, public?: true)

        # Bounded enum — a config-row status, NOT a freeform string (CDC-safe; no
        # non_pii! clearance needed).
        attribute :status, :atom do
          public?(true)
          constraints(one_of: [:active, :paused, :archived])
          default(:active)
        end
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

      # Tier-0: org-scoped reads; admin-gated writes (the doc's bounded-enum + admin-
      # gated shape — the `admin_gate_red_path` proves member-denied / admin-allowed).
      policies do
        policy action_type(:read) do
          authorize_if(Samen.Policy.OrgScope)
        end

        policy action_type([:create, :update, :destroy]) do
          # `forbid_unless` (NOT `authorize_if`) on the org check: it DENIES a cross-org
          # write but does NOT short-circuit to authorized when it passes, so evaluation
          # continues to the admin gate. Only `authorize_if(always())` (last) grants.
          forbid_unless(Samen.Policy.OrgScope)
          forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
          authorize_if(always())
        end

        policy action(:reveal_<%= abbrev %>) do
          authorize_if(always())
        end
      end
    end
    """
  end

  # ===========================================================================
  # The resource migration — abbrev-prefixed columns + catalog_sync
  # ===========================================================================

  @doc "The `Samen.Migration` for the resource table (abbrev-prefixed cols + catalog_sync)."
  def resource_migration do
    ~S'''
    defmodule <%= module %>.Repo.Migrations.Add<%= resource %> do
      @moduledoc """
      Creates <%= module %>'s authored `<%= resource %>` table (<%= table %>, abbrev
      `<%= abbrev %>`, scalar vault field pii_<%= abbrev %>_secret) and catalogs it in
      the SAME migration transaction (ADR-004 catalog-in-tx). Emitted by
      `mix samen.gen.resource` (WS-D D7a).
      """
      use Samen.Migration

      @resources [
        <%= resource_module %>
      ]

      def up do
        create table(:<%= table %>, primary_key: false) do
          # Scalar pii_ vault field → column pii_<%= abbrev %>_secret (vt_* token):
          add(:pii_<%= abbrev %>_secret, :text)
          add(:<%= abbrev %>_name, :text, null: false)
          add(:<%= abbrev %>_label, :text)
          add(:<%= abbrev %>_status, :text, default: "active")
          add(:<%= abbrev %>_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
          add(:<%= abbrev %>_org_id, :uuid, null: false)
          add(:<%= abbrev %>_inserted_at, :utc_datetime, null: false)
          add(:<%= abbrev %>_updated_at, :utc_datetime, null: false)
        end

        # ---- catalog the resource in THIS transaction ----
        catalog_sync(@resources)
      end

      def down do
        catalog_sync_down(@resources)
        drop(table(:<%= table %>))
      end
    end
    '''
  end

  # ===========================================================================
  # The FOUR mandated G26 test files (thin Samen.RedPath macro calls)
  # ===========================================================================

  @doc "File 1/4 — the org-scope policy matrix + masked-by-default PII."
  def policy_matrix_test do
    ~S'''
    defmodule <%= resource_module %>PolicyMatrixTest do
      @moduledoc """
      <%= resource_module %> org-scope policy matrix (file 1/4; WS-D D7a / AC-G26-1),
      driven by `Samen.RedPath` (the canonical `demo/test/identity_policy_matrix_test.exs`
      shape). Cross-org read denied as a PROPERTY, org-less fail-closed, positive read +
      write controls, PII `%Samen.Masked{}` by default — bound to the REAL Ash authorizer.

      Writes go as `:admin` (this is a Tier-0 admin-gated resource; a member cannot write
      — that red path is the RBAC file's `admin_gate_red_path`).
      """
      use <%= module %>.DataCase, async: false
      use Samen.RedPath, repo: <%= module %>.Repo

      alias <%= resource_module %>, as: Resource
      alias <%= module %>.Operator.Org

      policy_matrix(
        resource: Resource,
        org: Org,
        role: :admin,
        attrs: fn org_id ->
          n = System.unique_integer([:positive])

          %{
            org_id: org_id,
            name: "row-#{n}",
            label: "L#{n}",
            status: :active,
            secret: "SECRET-<%= abbrev %>-#{n}"
          }
        end,
        update: {:update, %{label: "changed"}},
        pii: [:secret],
        max_runs: 25
      )
    end
    '''
  end

  @doc "File 2/4 — the RBAC red path (admin-gated writes: member denied, admin allowed)."
  def rbac_red_path_test do
    ~S'''
    defmodule <%= resource_module %>RbacRedPathTest do
      @moduledoc """
      <%= resource_module %> RBAC red path (file 2/4; WS-D D7a / AC-G26-1). Two prongs,
      both through the REAL policy authorizer + the pure decision fns:

        * `rbac_role_model/0` — the pure `Samen.Scope.Role` rank matrix (escalation
          denied, positive controls, unknown/nil fail-closed);
        * `admin_gate_red_path/1` — this Tier-0 config resource's write gate: a `:member`
          actor's create is Forbidden (red path), an `:admin` actor's create succeeds
          (positive control). Sabotaging the resource's `RoleAtLeast` gate flips it.
      """
      use <%= module %>.DataCase, async: false
      use Samen.RedPath, repo: <%= module %>.Repo

      alias <%= resource_module %>, as: Resource
      alias <%= module %>.Operator.Org

      rbac_role_model()

      admin_gate_red_path(
        resource: Resource,
        org: Org,
        attrs: fn org_id ->
          n = System.unique_integer([:positive])
          %{org_id: org_id, name: "gate-#{n}", label: "L#{n}", status: :active,
            secret: "SECRET-<%= abbrev %>-#{n}"}
        end
      )
    end
    '''
  end

  @doc "File 3/4 — vault routing (vt_* at rest, plaintext nowhere, last-line guard)."
  def vault_routing_test do
    ~S'''
    defmodule <%= resource_module %>VaultRoutingTest do
      @moduledoc """
      <%= resource_module %> vault routing (file 3/4; WS-D D7a / AC-G26-1). The scalar
      🔒 `secret` field lands a `vt_*` token in the raw domain row, plaintext appears
      NOWHERE (row, token column, or vault ciphertext), and the `Samen.Type.VaultField`
      last-line guard refuses a raw plaintext write. Bound to the REAL vault chokepoint.
      """
      use <%= module %>.DataCase, async: false
      use Samen.RedPath, repo: <%= module %>.Repo

      alias <%= resource_module %>, as: Resource
      alias <%= module %>.Operator.Org

      vault_routing(
        resource: Resource,
        org: Org,
        fields: [:secret],
        plaintexts: ["VAULT-PLAINTEXT-<%= abbrev %>-hunt"],
        attrs: fn org_id ->
          %{org_id: org_id, name: "vault-row", status: :active,
            secret: "VAULT-PLAINTEXT-<%= abbrev %>-hunt"}
        end
      )
    end
    '''
  end

  @doc "File 4/4 — catalog-parity red path (delete a catalog row → verifier flips)."
  def catalog_parity_red_path_test do
    ~S'''
    defmodule <%= resource_module %>CatalogParityRedPathTest do
      @moduledoc """
      <%= resource_module %> catalog-parity red path (file 4/4; WS-D D7a / AC-G26-3).
      Green when every `<%= table %>` column is catalogued (positive control); deleting
      the `fld_field` row for `<%= table %>.<%= abbrev %>_name` FLIPS `catalog_parity`
      (the anti-tautology probe is real, not vacuous). The sandbox rolls the delete back.
      """
      use <%= module %>.DataCase, async: false
      use Samen.RedPath, repo: <%= module %>.Repo

      catalog_parity_red_path(
        table: "<%= table %>",
        column: "<%= abbrev %>_name"
      )
    end
    '''
  end

  # ===========================================================================
  # The per-resource anti-tautology probe (a real guarantee bound to a real sabotage)
  # ===========================================================================

  @doc """
  The per-resource anti-tautology probe: proves the emitted catalog-parity red path is
  non-vacuous by DELETING the catalogued column row and confirming `catalog_parity`
  flips — the same guarantee the file-4 test asserts, run as a standalone probe (design
  §1.2: "each new resource gets a probe binding a real guarantee to a real sabotage").
  """
  def anti_tautology_probe do
    ~S'''
    # <%= resource_module %> anti-tautology probe (WS-D D7a) — the catalog-parity guarantee.
    #
    # Guarantee under probe: `catalog_parity` FAILS when a catalogued column of
    # <%= table %> is missing its `fld_field` row (the file-4 red path). A green that
    # cannot fail proves nothing. This probe deletes the row for <%= table %>.<%= abbrev %>_name
    # and asserts the verifier flips, then rolls back — non-vacuity, standalone.
    #
    # Run:  cd <app> && MIX_ENV=test mix run priv/<%= test_stem %>_anti_tautology_probe.exs
    # Exit: 0 only if catalog_parity is GREEN with the row present AND FAILS with it removed.

    alias <%= module %>.Repo
    alias Mix.Tasks.Samen.Verify.CatalogParity

    # Start the repo against the already-migrated <%= otp_app %>_test DB (recreate + migrate,
    # so the probe is self-contained and does not depend on a prior ci.sh bootstrap).
    kms_key_dir =
      Path.join(System.tmp_dir!(), "<%= otp_app %>_<%= abbrev %>_probe_kms_\#{System.system_time(:nanosecond)}")

    File.rm_rf!(kms_key_dir)
    Application.put_env(:samen_core, :kms_key_dir, kms_key_dir)

    _ = Ecto.Adapters.Postgres.storage_down(Repo.config())
    :ok = Ecto.Adapters.Postgres.storage_up(Repo.config())
    {:ok, _} = Repo.start_link()
    Ecto.Migrator.run(Repo, :up, all: true)

    table = "<%= table %>"
    column = "<%= abbrev %>_name"

    # Positive control: green with the catalog intact.
    case CatalogParity.check(Repo) do
      [] ->
        :ok

      violations ->
        IO.puts("PROBE FAIL: catalog_parity was NOT green before sabotage: #{inspect(violations)}")
        System.halt(1)
    end

    # Sabotage inside a transaction we roll back — remove the catalogued column row.
    Repo.transaction(fn ->
      Repo.query!(
        "DELETE FROM fld_field WHERE fld_table_name = $1 AND fld_column_name = $2",
        [table, column]
      )

      violations = CatalogParity.check(Repo)

      flipped? =
        violations != [] and
          Enum.any?(violations, fn v ->
            v =~ table and (v =~ "uncatalogued" or v =~ column)
          end)

      unless flipped? do
        IO.puts("PROBE FAIL: catalog_parity did NOT flip when #{table}.#{column} was uncatalogued " <>
                  "(TAUTOLOGY): #{inspect(violations)}")
        Repo.rollback(:tautology)
      end

      IO.puts("PROBE OK: catalog_parity flipped on the uncatalogued #{table}.#{column} — non-vacuous.")
      Repo.rollback(:done)
    end)

    IO.puts("<%= resource_module %> anti-tautology probe: CONFIRMED.")
    File.rm_rf!(kms_key_dir)
    '''
  end
end
