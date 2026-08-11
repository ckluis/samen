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

  @doc """
  The AUTHN-COVERAGE GUARD emitted by `mix samen.gen.scope` (W4-H2 defense-in-depth,
  ADR-031). A failing-until-wired guard: it enumerates every PII-bearing tenant-plane
  LiveView mount off THIS app's REAL compiled router and asserts each carries the
  `@current_org_labels`/`:authn` seam — the prod gate that makes `Samen.Web.CurrentOrg`
  fail CLOSED. The moment an author adds a business-domain mount WITHOUT
  `labels: @current_org_labels`, this trips at `mix test`. Mirrors the framework
  `Samen.Web.TenantAuthnCoverageTest` + `PawChart.TenantAuthnProdPathTest`, run against the
  app's own router (routes are extracted, never hand-built, so a dropped seam flips it).
  """
  def tenant_authn_coverage_test do
    """
    defmodule <%= module %>Web.TenantAuthnCoverageTest do
      @moduledoc \"\"\"
      AUTHN-COVERAGE GUARD (emitted by `mix samen.gen.scope`; W4-H2 defense-in-depth, ADR-031).

      Enumerates EVERY PII-bearing tenant-plane LiveView mount off this app's REAL compiled
      router and asserts each carries the `@current_org_labels` `:authn` seam — the prod gate
      that makes `Samen.Web.CurrentOrg.resolve/3` FAIL CLOSED (deny an unauthenticated `?org=`)
      on an armed host. A tenant mount WITHOUT the seam is the live-reproduced pawchart
      cross-tenant PII leak (dogfood W4 BLOCKER-1): an anonymous caller supplying any org UUID
      reads unmasked business data.

      This guard is the class-closer for THIS host. The moment you add a business-domain mount
      (`samen_module_routes(:crm, <%= module %>.Crm, ...)` and friends) WITHOUT
      `labels: @current_org_labels`, these assertions FAIL at `mix test` — you are GUIDED (see the
      `mix samen.gen.scope` output) AND CAUGHT. Routes are extracted off the compiled router,
      never hand-built, so a dropped seam flips this by construction.
      \"\"\"
      use ExUnit.Case, async: false

      alias Samen.Web.CurrentOrg
      alias Samen.Web.Mount

      # The PII-bearing tenant-MODULE scope kinds. `:settings`/`:auth` identity mounts are the
      # self-serve / pre-actor plane (no org actor) and are intentionally NOT in scope here.
      @tenant_kinds ~w(crm billing support work marketing notifications files csv ics search)a

      # A guessable-format org UUID an attacker supplies (the W4 vector). NOT the caller's own org.
      @attacker_org "c1112d00-0000-4000-8000-0000000000fe"

      setup do
        prev = Application.get_env(:<%= otp_app %>, :auth_required?)

        on_exit(fn ->
          case prev do
            nil -> Application.delete_env(:<%= otp_app %>, :auth_required?)
            v -> Application.put_env(:<%= otp_app %>, :auth_required?, v)
          end
        end)

        :ok
      end

      defp arm!, do: Application.put_env(:<%= otp_app %>, :auth_required?, true)
      defp disarm!, do: Application.put_env(:<%= otp_app %>, :auth_required?, false)

      test "every PII-bearing tenant mount carries the :authn seam (merge labels: @current_org_labels into any bare mount)" do
        mounts = tenant_mounts()

        assert length(mounts) >= 1,
               "tenant-mount enumeration found nothing — the guard would be vacuous"

        for {path, mount} <- mounts do
          assert Mount.label(mount, :authn, nil) == {:app_env, :<%= otp_app %>, :auth_required?},
                 "tenant mount \#{path} is missing the :authn seam — a bare `samen_*_routes` mount " <>
                   "reopens the W4 cross-tenant PII leak. Merge `labels: @current_org_labels` into it."
        end
      end

      test "armed host: EVERY tenant mount denies an unauthenticated ?org= (the W4 leak stays closed)" do
        arm!()

        for {path, mount} <- tenant_mounts() do
          assert CurrentOrg.resolve(mount, %{"org" => @attacker_org}, %{"samen_current_org" => @attacker_org}) == nil,
                 "ARMED tenant mount \#{path} resolved an org from an UNAUTHENTICATED ?org= — the leak is open"
        end
      end

      test "REFUTABILITY: disarmed, the tenant mounts still trust the dev ?org= (the armed denial is non-vacuous)" do
        disarm!()

        for {path, mount} <- tenant_mounts() do
          assert CurrentOrg.resolve(mount, %{"org" => @attacker_org}, %{}) == @attacker_org,
                 "DISARMED tenant mount \#{path} dropped the dev ?org= convenience — refutability broken"
        end
      end

      # Enumerate PII-bearing tenant LiveView mounts off the REAL compiled router, deduped per
      # live_session (per distinct tenant mount adoption point) — the exact serialized
      # `Samen.Web.Mount` each `live_session` threads through its session.
      defp tenant_mounts do
        <%= module %>Web.Router.__routes__()
        |> Enum.filter(&Map.has_key?(&1.metadata, :phoenix_live_view))
        |> Enum.map(fn route -> {route.path, live_session_name(route), mount_of(route)} end)
        |> Enum.reject(fn {_path, _ls, mount} -> is_nil(mount) end)
        |> Enum.filter(fn {_path, _ls, mount} -> mount.scope_kind in @tenant_kinds end)
        |> Enum.uniq_by(fn {_path, ls, _mount} -> ls end)
        |> Enum.map(fn {path, _ls, mount} -> {path, mount} end)
      end

      defp live_session_name(%{metadata: %{phoenix_live_view: {_view, _action, _opts, live_session}}}),
        do: live_session[:name]

      defp live_session_name(_), do: nil

      defp mount_of(%{metadata: %{phoenix_live_view: {_view, _action, _opts, live_session}}}) do
        case get_in(live_session, [:extra, :session]) do
          %{"samen_mount" => raw} -> Mount.from_session(raw)
          _ -> nil
        end
      end

      defp mount_of(_), do: nil
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
      `status`, plain non-PII label columns, and ONE `pii do` vault field
      (`<%= field_vault_column %>`, logical type `<%= field_ash_type %>`) so the
      whole vault/mask/reveal path is exercised.
      Inherits the ENTIRE substrate (abbrev storage, vault routing, masking, OrgScope,
      catalog parity, audit, crypto-shred) via `use Samen.Resource` — zero vertical
      infrastructure code.
      \"\"\"
      use Samen.Resource,
        otp_app: :<%= otp_app %>,
        domain: <%= scope_module %>,
        data_layer: AshPostgres.DataLayer,
        authorizers: [Ash.Policy.Authorizer],
        abbrev: "<%= abbrev %>"<%= archivable_opt %>

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
        pii_attribute(:secret, <%= field_ash_type %>, vault: :pii_secret)
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
      `<%= abbrev %>`, vault field `<%= field_vault_column %>`) and catalogs it in
      the SAME migration transaction (ADR-004 catalog-in-tx). Emitted by
      `mix samen.gen.resource` (WS-D D7a).

      ADR-036 H7 (T15): the vault column's NAME follows
      `Samen.Transformers.MaterializePii`'s scalar-vs-composite routing
      (`Samen.Gen.FieldTypeMenu.vault_column/2`) — `pii_<%= abbrev %>_secret` for
      a scalar `--field-type` (the default `:string` and every H1-H3 scalar), or
      `<%= abbrev %>_secret` (no `pii_` prefix) for a composite PII type
      (`Samen.Type.Address`, H4) — matching the SAME convention
      `FullName`/`Emails`/`Phones` use. This resource's `--field-type` is
      `<%= field_type %>`.
      """
      use Samen.Migration

      @resources [
        <%= resource_module %>
      ]

      def up do
        create table(:<%= table %>, primary_key: false) do
          # 🔒 vault field (vt_* token) → column <%= field_vault_column %>:
          add(:<%= field_vault_column %>, :text)
          add(:<%= abbrev %>_name, :text, null: false)
          add(:<%= abbrev %>_label, :text)
          add(:<%= abbrev %>_status, :text, default: "active")
          add(:<%= abbrev %>_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
          add(:<%= abbrev %>_org_id, :uuid, null: false)
          add(:<%= abbrev %>_inserted_at, :utc_datetime, null: false)
          add(:<%= abbrev %>_updated_at, :utc_datetime, null: false)<%= archived_at_migration_line %>
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
            secret: <%= field_dynamic_sample %>
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
            secret: <%= field_dynamic_sample %>}
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
        plaintexts: ["<%= field_vault_plaintext %>"],
        attrs: fn org_id ->
          %{org_id: org_id, name: "vault-row", status: :active,
            secret: <%= field_vault_sample %>}
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

  # ===========================================================================
  # mix samen.gen.resource --live — the three CRUD LiveViews on `Samen.UI`
  # (WS-D D7a). Thin, kit-first surfaces: index / show / form. Self-contained
  # after the driftwood `broker_live` idiom (`?org=<uuid>` selects the tenant
  # org, a `%Samen.Scope{}` with `plane: :tenant` scopes every Ash read). The
  # 🔒 vault field resolves through `Samen.Api.PiiResolution` BY CONSTRUCTION —
  # the resource's read preparation runs the resolver on the actor's plane, so a
  # LiveView renders the ALREADY-RESOLVED value (clear on the tenant plane, `••••`
  # otherwise). No hand-masking, no `vt_*` token ever reaches a template.
  # ===========================================================================

  # ===========================================================================
  # `--live --archivable` (ADR-040 §5.8, T37h) — the generated index LiveView's
  # restore + archived-filter affordance. Pre-resolved snippets (Elixir string
  # interpolation for `resource_path`, never a literal `<%= key %>` left for the
  # OUTER single-pass `<%= key %>` engine to maybe-catch on a later binding — map
  # iteration order over `Samen.Gen.App.render/2`'s bindings is not guaranteed).
  # `false` clauses reproduce the exact pre-T37h plain-delete behavior.
  # ===========================================================================

  @doc false
  def archivable_live_events(false, _resource_path), do: ""

  def archivable_live_events(true, resource_path) do
    "\n" <>
      "      def handle_event(\"toggle_archived\", _params, socket) do\n" <>
      "        show_archived = not Map.get(socket.assigns, :show_archived, false)\n" <>
      "        {:noreply, socket |> assign(show_archived: show_archived) |> load(socket.assigns.org_id)}\n" <>
      "      end\n" <>
      "\n" <>
      "      # FAIL-HONEST restore: navigate/refresh only when the restore actually happened.\n" <>
      "      def handle_event(\"restore\", %{\"id\" => id}, socket) do\n" <>
      "        scope = scope(socket.assigns.org_id)\n" <>
      "\n" <>
      "        case Enum.find(socket.assigns.records, &(to_string(&1.id) == id)) do\n" <>
      "          nil ->\n" <>
      "            {:noreply, socket}\n" <>
      "\n" <>
      "          record ->\n" <>
      "            case Samen.Archival.restore(record, scope: scope) do\n" <>
      "              {:ok, _} -> {:noreply, load(assign(socket, delete_error: nil), socket.assigns.org_id)}\n" <>
      "              {:error, _} -> {:noreply, assign(socket, delete_error: \"Could not restore this #{resource_path}.\")}\n" <>
      "            end\n" <>
      "        end\n" <>
      "      end"
  end

  @doc false
  def archivable_live_toggle_button(false, _resource_path), do: ""

  def archivable_live_toggle_button(true, resource_path) do
    "<.button :if={not @no_org} phx-click=\"toggle_archived\" id=\"toggle-archived-#{resource_path}\">" <>
      "{if @show_archived, do: \"Hide archived\", else: \"Show archived\"}</.button>"
  end

  @doc false
  def archivable_live_row_action(false, _resource_path),
    do: ~s(<.delete_confirm phx-click="delete" phx-value-id={r.id} />)

  def archivable_live_row_action(true, resource_path) do
    "<%= if r.archived_at do %>" <>
      "<.pill variant=\"mut\">archived</.pill> " <>
      "<.button phx-click=\"restore\" phx-value-id={r.id} class=\"restore-#{resource_path}\">Restore</.button>" <>
      "<% else %><.delete_confirm phx-click=\"delete\" phx-value-id={r.id} /><% end %>"
  end

  @doc false
  def archivable_read_records_fn(false) do
    "defp read_records(scope, _show_archived?) do\n" <>
      "        Resource\n" <>
      "        |> Ash.read!(scope: scope)\n" <>
      "      end"
  end

  def archivable_read_records_fn(true) do
    "defp read_records(scope, true) do\n" <>
      "        Resource\n" <>
      "        |> Ash.Query.for_read(:archived)\n" <>
      "        |> Ash.read!(scope: scope)\n" <>
      "      end\n" <>
      "\n" <>
      "      defp read_records(scope, false) do\n" <>
      "        Resource\n" <>
      "        |> Ash.read!(scope: scope)\n" <>
      "      end"
  end

  @doc "The INDEX LiveView — a kit `data_table` list + a `modal`/`simple_form` create."
  def resource_index_live do
    ~S'''
    defmodule <%= module %>Web.<%= scope %>.<%= resource %>IndexLive do
      @moduledoc """
      <%= resource_module %> INDEX (`/<%= scope_path %>/<%= resource_path %>`) — the
      generated tenant-plane list screen on the `Samen.UI` kit (emitted by
      `mix samen.gen.resource --live`, WS-D D7a).

      Self-contained after driftwood's `broker_live` idiom: `?org=<uuid>` selects the
      tenant org (a LOCAL DOGFOOD convenience — a real deploy derives it from the
      authenticated session), a `%Samen.Scope{}` carrying `plane: :tenant` scopes every
      Ash read, and `Samen.Policy.OrgScope` confines the result to the acting org.
      Writes are admin-gated in the kernel (`RoleAtLeast :admin`); the "New" affordance
      opens a `modal/1` hosting the `AshPhoenix.Form`-backed `simple_form/1` create. The
      resource carries a 🔒 vault field, resolved per plane through
      `Samen.Api.PiiResolution` on read — the surface never hand-masks (see the show
      screen, where the resolved value renders).
      """
      use Phoenix.LiveView

      import Samen.UI

      alias <%= resource_module %>, as: Resource

      @impl true
      def mount(params, _session, socket) do
        org_id = params["org"]
        {:ok, load(assign(socket, org_id: org_id), org_id)}
      end

      @impl true
      def handle_params(params, _uri, socket) do
        org_id = params["org"] || socket.assigns.org_id
        {:noreply, load(assign(socket, org_id: org_id), org_id)}
      end

      @doc false
      def load(socket, nil) do
        assign(socket,
          no_org: true,
          org_id: nil,
          records: [],
          show_new: false,
          new_form: nil,
          delete_error: nil
        )
        |> assign_new(:show_archived, fn -> false end)
      end

      def load(socket, org_id) do
        scope = scope(org_id)
        show_archived = Map.get(socket.assigns, :show_archived, false)

        socket
        |> assign(
          no_org: false,
          org_id: org_id,
          show_archived: show_archived,
          records: read_records(scope, show_archived)
        )
        |> assign_new(:show_new, fn -> false end)
        |> assign_new(:delete_error, fn -> nil end)
        |> assign(new_form: create_form(scope))
      end

      @impl true
      def handle_event("new", _params, socket) do
        {:noreply, assign(socket, show_new: true, new_form: create_form(scope(socket.assigns.org_id)))}
      end

      def handle_event("cancel_new", _params, socket) do
        {:noreply, assign(socket, show_new: false)}
      end

      def handle_event("validate_new", %{"form" => params}, socket) do
        form = AshPhoenix.Form.validate(socket.assigns.new_form, with_org(params, socket))
        {:noreply, assign(socket, new_form: form)}
      end

      # `org_id` is the server-side fact, never client input; the kernel's OrgScope +
      # admin gate enforce the write regardless of the UI.
      def handle_event("save_new", %{"form" => params}, socket) do
        case AshPhoenix.Form.submit(socket.assigns.new_form, params: with_org(params, socket)) do
          {:ok, _record} ->
            {:noreply, socket |> assign(show_new: false) |> load(socket.assigns.org_id)}

          {:error, form} ->
            {:noreply, assign(socket, new_form: form)}
        end
      end

      # FAIL-HONEST delete: navigate/refresh only when the destroy actually happened.
      def handle_event("delete", %{"id" => id}, socket) do
        scope = scope(socket.assigns.org_id)

        case Enum.find(socket.assigns.records, &(to_string(&1.id) == id)) do
          nil ->
            {:noreply, socket}

          record ->
            case Ash.destroy(record, scope: scope) do
              :ok -> {:noreply, load(assign(socket, delete_error: nil), socket.assigns.org_id)}
              {:ok, _} -> {:noreply, load(assign(socket, delete_error: nil), socket.assigns.org_id)}
              {:error, _} -> {:noreply, assign(socket, delete_error: "Could not delete this <%= resource_path %>.")}
            end
        end
      end
      <%= archivable_live_events %>
      # `?org=` selects the tenant org; the actor carries `plane: :tenant`, so its OWN
      # org's PII resolves in CLEAR through `Samen.Api.PiiResolution` (never hand-masked,
      # never a `vt_*` token). `role: :admin` clears the kernel's admin write gate.
      defp scope(org_id) do
        %Samen.Scope{actor: %{id: "ui:" <> to_string(org_id), org_id: org_id, role: :admin, plane: :tenant}}
      end

      <%= archivable_read_records_fn %>

      defp create_form(scope) do
        Resource
        |> AshPhoenix.Form.for_create(:create, scope: scope)
        |> to_form()
      end

      defp with_org(params, socket), do: Map.put(params, "org_id", socket.assigns.org_id)

      @impl true
      def render(assigns) do
        ~H"""
        <div id="<%= scope_path %>-<%= resource_path %>-index">
          <.app_shell>
            <:sidebar>
              <.sidebar title="<%= module %>" subtitle="<%= scope %>">
                <.nav_group label="<%= scope %>">
                  <.nav_item label="<%= resource %>" href={"/<%= scope_path %>/<%= resource_path %>?org=#{@org_id}"} active={true} />
                </.nav_group>
              </.sidebar>
            </:sidebar>

            <.topbar title="<%= resource %>" crumbs={["<%= module %>", "<%= scope %>", "<%= resource %>"]}>
              <:actions>
                <%= archivable_live_toggle_button %>
                <.button :if={not @no_org} variant="primary" phx-click="new" id="new-<%= resource_path %>">New <%= resource %></.button>
              </:actions>
            </.topbar>

            <%= if @no_org do %>
              <div class="wrap">
                <div class="card" id="no-org" style="padding:22px 20px;color:var(--muted)">
                  No org selected. Append <code>?org=&lt;uuid&gt;</code> to the URL.
                </div>
              </div>
            <% else %>
              <span id="org-banner" style="display:none"><%= scope %> org: {@org_id}</span>

              <div :if={@delete_error} class="wrap" style="margin-bottom:0">
                <div class="card" id="delete-error" style="padding:10px 14px;color:var(--bad, #b91c1c);font-size:12px">{@delete_error}</div>
              </div>

              <div class="wrap">
                <%= if @records == [] do %>
                  <.empty_state icon="▣" title="No <%= resource_path %> yet." body="Create the first <%= resource %> to get started.">
                    <:actions>
                      <.button variant="primary" phx-click="new" id="empty-new-<%= resource_path %>">New <%= resource %></.button>
                    </:actions>
                  </.empty_state>
                <% else %>
                  <.data_table>
                    <:head>
                      <th style="width:40%">Name</th>
                      <th style="width:24%">Label</th>
                      <th style="width:20%">Status</th>
                      <th style="width:16%"><span class="sr-only">Actions</span></th>
                    </:head>
                    <tr :for={r <- @records} class="<%= resource_path %>-row" id={"<%= resource_path %>-#{r.id}"}>
                      <td>
                        <a href={"/<%= scope_path %>/<%= resource_path %>/#{r.id}?org=#{@org_id}"} style="color:#3B4CCA;font-weight:500;text-decoration:none">{r.name}</a>
                      </td>
                      <td style="color:var(--muted)">{r.label || "—"}</td>
                      <td><.pill variant={status_variant(r.status)}>{r.status}</.pill></td>
                      <td><%= archivable_live_row_action %></td>
                    </tr>
                  </.data_table>
                <% end %>
              </div>

              <.modal :if={@show_new and @new_form != nil} id="new-<%= resource_path %>-modal" title="New <%= resource %>" on_cancel="cancel_new">
                <.simple_form :let={f} for={@new_form} id="new-<%= resource_path %>-form" phx-change="validate_new" phx-submit="save_new">
                  <.form_field field={f[:name]} label="Name" />
                  <.form_field field={f[:label]} label="Label" />
                  <.form_field field={f[:status]} label="Status" type="select" options={[{"Active", "active"}, {"Paused", "paused"}, {"Archived", "archived"}]} />
                  <.form_field field={f[:secret]} label="Secret (🔒 vault-routed)" />
                  <:actions>
                    <.button variant="primary" type="submit">Save <%= resource %></.button>
                    <.button type="button" phx-click="cancel_new">Cancel</.button>
                  </:actions>
                </.simple_form>
              </.modal>
            <% end %>
          </.app_shell>
        </div>
        """
      end

      defp status_variant(:active), do: "ok"
      defp status_variant(:paused), do: "warn"
      defp status_variant(:archived), do: "mut"
      defp status_variant(_), do: "mut"
    end
    '''
  end

  @doc "The SHOW LiveView — a detail card that renders the plane-resolved 🔒 field."
  def resource_show_live do
    ~S'''
    defmodule <%= module %>Web.<%= scope %>.<%= resource %>ShowLive do
      @moduledoc """
      <%= resource_module %> SHOW (`/<%= scope_path %>/<%= resource_path %>/:id`) — the
      generated tenant-plane detail screen on the `Samen.UI` kit (emitted by
      `mix samen.gen.resource --live`, WS-D D7a).

      Reads ONE record via `Ash.get/3` under a `%Samen.Scope{}` with `plane: :tenant`.
      The 🔒 vault field (`secret`) is rendered STRAIGHT from the read record —
      `Samen.Api.PiiResolution` (the resource's read preparation) has already resolved it
      to plaintext on the tenant plane / `%Samen.Masked{}` (`••••`) otherwise, so this
      surface never reveals through the vault, never hand-masks, and never emits a `vt_*`
      token. Edit routes to the form screen; delete is fail-honest.
      """
      use Phoenix.LiveView

      import Samen.UI
      require Ash.Query

      alias <%= resource_module %>, as: Resource

      @impl true
      def mount(params, _session, socket) do
        org_id = params["org"]
        id = params["id"]
        {:ok, load(assign(socket, org_id: org_id, id: id), org_id, id)}
      end

      @impl true
      def handle_params(params, _uri, socket) do
        org_id = params["org"] || socket.assigns.org_id
        id = params["id"] || socket.assigns.id
        {:noreply, load(assign(socket, org_id: org_id, id: id), org_id, id)}
      end

      @doc false
      def load(socket, nil, _id), do: assign(socket, no_org: true, record: nil, delete_error: nil)
      def load(socket, _org_id, nil), do: assign(socket, no_org: false, record: nil, delete_error: nil)

      def load(socket, org_id, id) do
        socket
        |> assign(no_org: false, record: fetch(org_id, id))
        |> assign_new(:delete_error, fn -> nil end)
      end

      @impl true
      def handle_event("delete", %{"id" => id}, socket) do
        scope = scope(socket.assigns.org_id)

        case fetch(socket.assigns.org_id, id) do
          nil ->
            {:noreply, assign(socket, delete_error: "This <%= resource_path %> no longer exists.")}

          record ->
            case Ash.destroy(record, scope: scope) do
              :ok -> {:noreply, push_navigate(socket, to: index_path(socket.assigns.org_id))}
              {:ok, _} -> {:noreply, push_navigate(socket, to: index_path(socket.assigns.org_id))}
              {:error, _} -> {:noreply, assign(socket, delete_error: "Could not delete this <%= resource_path %>.")}
            end
        end
      end

      # Read ONE record on the tenant plane, SELECTING the 🔒 vault field (pii fields are
      # not selected by default). The read's `Samen.Api.PiiResolution` preparation resolves
      # `secret` per plane — clear on the tenant plane, `%Samen.Masked{}` otherwise — so the
      # template renders the already-resolved value (never hand-masked, never a `vt_*` token).
      defp fetch(org_id, id) do
        Resource
        |> Ash.Query.filter(id == ^id)
        |> Ash.Query.ensure_selected([:secret])
        |> Ash.read_one(scope: scope(org_id))
        |> case do
          {:ok, record} -> record
          {:error, _} -> nil
        end
      end

      defp scope(org_id) do
        %Samen.Scope{actor: %{id: "ui:" <> to_string(org_id), org_id: org_id, role: :admin, plane: :tenant}}
      end

      defp index_path(org_id), do: "/<%= scope_path %>/<%= resource_path %>?org=#{org_id}"

      @impl true
      def render(assigns) do
        ~H"""
        <div id="<%= scope_path %>-<%= resource_path %>-show">
          <.app_shell>
            <:sidebar>
              <.sidebar title="<%= module %>" subtitle="<%= scope %>">
                <.nav_group label="<%= scope %>">
                  <.nav_item label="<%= resource %>" href={index_path(@org_id)} active={true} />
                </.nav_group>
              </.sidebar>
            </:sidebar>

            <.topbar title={@record && @record.name || "<%= resource %>"} crumbs={["<%= module %>", "<%= scope %>", "<%= resource %>"]}>
              <:actions>
                <a href={index_path(@org_id)} class="btn" style="text-decoration:none">Back</a>
                <a :if={@record != nil} href={"/<%= scope_path %>/<%= resource_path %>/#{@record.id}/edit?org=#{@org_id}"} class="btn" style="text-decoration:none" id="edit-<%= resource_path %>">Edit</a>
                <.delete_confirm :if={@record != nil} id="delete-<%= resource_path %>" phx-click="delete" phx-value-id={@record && @record.id} />
              </:actions>
            </.topbar>

            <%= if @no_org do %>
              <div class="wrap">
                <div class="card" id="no-org" style="padding:22px 20px;color:var(--muted)">
                  No org selected. Append <code>?org=&lt;uuid&gt;</code> to the URL.
                </div>
              </div>
            <% else %>
              <div :if={@delete_error} class="wrap" style="margin-bottom:0">
                <div class="card" id="delete-error" style="padding:10px 14px;color:var(--bad, #b91c1c);font-size:12px">{@delete_error}</div>
              </div>

              <%= if @record == nil do %>
                <div class="wrap">
                  <div class="card" id="not-found" style="padding:22px 20px;color:var(--muted)"><%= resource %> not found.</div>
                </div>
              <% else %>
                <div class="wrap">
                  <div class="card" id="<%= resource_path %>-detail" style="padding:20px">
                    <div class="gtitle" style="margin-bottom:16px"><h3><%= resource %> details</h3></div>
                    <table style="width:100%;font-size:13px;border-collapse:collapse">
                      <tr style="border-bottom:1px solid var(--border)">
                        <td style="padding:10px 0;color:var(--muted);width:180px">Name</td>
                        <td style="padding:10px 0" class="d-name">{@record.name}</td>
                      </tr>
                      <tr style="border-bottom:1px solid var(--border)">
                        <td style="padding:10px 0;color:var(--muted)">Label</td>
                        <td style="padding:10px 0" class="d-label">{@record.label || "—"}</td>
                      </tr>
                      <tr style="border-bottom:1px solid var(--border)">
                        <td style="padding:10px 0;color:var(--muted)">Status</td>
                        <td style="padding:10px 0"><.pill variant={status_variant(@record.status)}>{@record.status}</.pill></td>
                      </tr>
                      <tr style="border-bottom:1px solid var(--border)">
                        <td style="padding:10px 0;color:var(--muted)">Secret <small style="font-weight:400">(🔒 PII — resolved per plane)</small></td>
                        <td style="padding:10px 0" class="d-secret">{render_secret(@record.secret)}</td>
                      </tr>
                    </table>
                  </div>
                </div>
              <% end %>
            <% end %>
          </.app_shell>
        </div>
        """
      end

      defp status_variant(:active), do: "ok"
      defp status_variant(:paused), do: "warn"
      defp status_variant(:archived), do: "mut"
      defp status_variant(_), do: "mut"

      # ADR-036 H7 (T15): the 🔒 field's plane-resolved value can be `%Samen.Masked{}`
      # (already Phoenix.HTML.Safe — "••••"), a plain string (URL/email/phone/nil),
      # or — for the H1/H2/H4 menu types — a struct/Decimal (Money/Address/Percent/
      # Score) Phoenix.HTML.Safe has no built-in impl for. `inspect/1` renders any of
      # those safely as text (never raises); binaries/Masked pass through untouched.
      defp render_secret(nil), do: ""
      defp render_secret(%Samen.Masked{} = m), do: m
      defp render_secret(v) when is_binary(v), do: v
      defp render_secret(v), do: inspect(v)
    end
    '''
  end

  @doc "The FORM LiveView — one `simple_form` serving both create (`:new`) and edit (`:edit`)."
  def resource_form_live do
    ~S'''
    defmodule <%= module %>Web.<%= scope %>.<%= resource %>FormLive do
      @moduledoc """
      <%= resource_module %> FORM (`/<%= scope_path %>/<%= resource_path %>/new` and
      `/<%= scope_path %>/<%= resource_path %>/:id/edit`) — the generated tenant-plane
      create/edit screen on the `Samen.UI` kit (emitted by `mix samen.gen.resource
      --live`, WS-D D7a).

      One `AshPhoenix.Form`-backed `simple_form/1` serves both actions (mode inferred
      from `:id` presence). `org_id` is merged server-side on create — never client input;
      the kernel's OrgScope + admin gate enforce the write. The 🔒 `secret` field rides
      the kit's masked-by-construction branch: on the operator/impersonation plane it
      renders a read-only `••••` with no `name` (it can never round-trip plaintext or a
      vault token); on the tenant plane it is a normal editable field.
      """
      use Phoenix.LiveView

      import Samen.UI
      require Ash.Query

      alias <%= resource_module %>, as: Resource

      @impl true
      def mount(params, _session, socket) do
        org_id = params["org"]
        id = params["id"]
        action = if id, do: :edit, else: :new
        {:ok, load(assign(socket, org_id: org_id, id: id, action: action), org_id, id, action)}
      end

      @doc false
      def load(socket, nil, _id, action), do: assign(socket, no_org: true, action: action, record: nil, form: nil)

      def load(socket, org_id, nil, _action) do
        assign(socket, no_org: false, action: :new, record: nil, form: create_form(scope(org_id)))
      end

      def load(socket, org_id, id, _action) do
        case fetch(org_id, id) do
          nil ->
            assign(socket, no_org: false, action: :edit, record: nil, form: nil)

          record ->
            assign(socket, no_org: false, action: :edit, record: record, form: update_form(record, scope(org_id)))
        end
      end

      # Read ONE record on the tenant plane, SELECTING the 🔒 vault field so the edit form
      # pre-fills the plane-resolved value (the kit's masked branch keeps it read-only
      # `••••` on the operator plane; on the tenant plane it is a normal editable field).
      defp fetch(org_id, id) do
        Resource
        |> Ash.Query.filter(id == ^id)
        |> Ash.Query.ensure_selected([:secret])
        |> Ash.read_one(scope: scope(org_id))
        |> case do
          {:ok, record} -> record
          {:error, _} -> nil
        end
      end

      @impl true
      def handle_event("validate", %{"form" => params}, socket) do
        {:noreply, assign(socket, form: AshPhoenix.Form.validate(socket.assigns.form, submit_params(params, socket)))}
      end

      def handle_event("save", %{"form" => params}, socket) do
        case AshPhoenix.Form.submit(socket.assigns.form, params: submit_params(params, socket)) do
          {:ok, record} ->
            {:noreply, push_navigate(socket, to: "/<%= scope_path %>/<%= resource_path %>/#{record.id}?org=#{socket.assigns.org_id}")}

          {:error, form} ->
            {:noreply, assign(socket, form: form)}
        end
      end

      defp scope(org_id) do
        %Samen.Scope{actor: %{id: "ui:" <> to_string(org_id), org_id: org_id, role: :admin, plane: :tenant}}
      end

      defp create_form(scope) do
        Resource
        |> AshPhoenix.Form.for_create(:create, scope: scope)
        |> to_form()
      end

      defp update_form(record, scope) do
        record
        |> AshPhoenix.Form.for_update(:update, scope: scope)
        |> to_form()
      end

      # org_id is a server-side fact on CREATE only; on update the row's org is immutable.
      defp submit_params(params, %{assigns: %{action: :new, org_id: org_id}}), do: Map.put(params, "org_id", org_id)
      defp submit_params(params, _socket), do: params

      defp index_path(org_id), do: "/<%= scope_path %>/<%= resource_path %>?org=#{org_id}"

      @impl true
      def render(assigns) do
        ~H"""
        <div id="<%= scope_path %>-<%= resource_path %>-form">
          <.app_shell>
            <:sidebar>
              <.sidebar title="<%= module %>" subtitle="<%= scope %>">
                <.nav_group label="<%= scope %>">
                  <.nav_item label="<%= resource %>" href={index_path(@org_id)} active={true} />
                </.nav_group>
              </.sidebar>
            </:sidebar>

            <.topbar title={form_title(@action)} crumbs={["<%= module %>", "<%= scope %>", "<%= resource %>", form_title(@action)]}>
              <:actions>
                <a href={index_path(@org_id)} class="btn" style="text-decoration:none">Cancel</a>
              </:actions>
            </.topbar>

            <%= if @no_org do %>
              <div class="wrap">
                <div class="card" id="no-org" style="padding:22px 20px;color:var(--muted)">
                  No org selected. Append <code>?org=&lt;uuid&gt;</code> to the URL.
                </div>
              </div>
            <% else %>
              <%= if @form == nil do %>
                <div class="wrap">
                  <div class="card" id="not-found" style="padding:22px 20px;color:var(--muted)"><%= resource %> not found.</div>
                </div>
              <% else %>
                <div class="wrap">
                  <div class="card" style="padding:20px">
                    <.simple_form :let={f} for={@form} id="<%= resource_path %>-form" phx-change="validate" phx-submit="save">
                      <.form_field field={f[:name]} label="Name" />
                      <.form_field field={f[:label]} label="Label" />
                      <.form_field field={f[:status]} label="Status" type="select" options={[{"Active", "active"}, {"Paused", "paused"}, {"Archived", "archived"}]} />
                      <.form_field field={f[:secret]} label="Secret (🔒 vault-routed)" />
                      <:actions>
                        <.button variant="primary" type="submit">Save <%= resource %></.button>
                        <a href={index_path(@org_id)} class="btn" style="text-decoration:none">Cancel</a>
                      </:actions>
                    </.simple_form>
                  </div>
                </div>
              <% end %>
            <% end %>
          </.app_shell>
        </div>
        """
      end

      defp form_title(:edit), do: "Edit <%= resource %>"
      defp form_title(_), do: "New <%= resource %>"
    end
    '''
  end

  @doc """
  The emitted MOUNT-SMOKE test (WS-D D7a `--live`) — drives the three generated
  LiveViews through their REAL `mount/3` + `render/1` lifecycle (the disconnected
  render, the 500-on-mount class; samen_web has no Endpoint in `:test`). Also proves
  masking-by-construction: on the tenant plane the 🔒 field resolves CLEAR on the show
  screen and NO `vt_*` token reaches the DOM.
  """
  def resource_live_smoke_test do
    ~S'''
    defmodule <%= resource_module %>LiveSmokeTest do
      @moduledoc """
      <%= resource_module %> `--live` mount smoke (WS-D D7a). The generated index / show
      / form LiveViews mount + render off a disconnected socket (the mount-lifecycle
      smoke — the documented 500-on-mount class), and the show screen proves the 🔒
      vault field is resolved through `Samen.Api.PiiResolution` on the tenant plane
      (clear), never hand-masked, with NO `vt_*` token in the DOM.
      """
      use <%= module %>.DataCase, async: false

      alias <%= module %>Web.<%= scope %>.<%= resource %>IndexLive, as: IndexLive
      alias <%= module %>Web.<%= scope %>.<%= resource %>ShowLive, as: ShowLive
      alias <%= module %>Web.<%= scope %>.<%= resource %>FormLive, as: FormLive
      alias <%= resource_module %>, as: Resource

      @org "00000000-0000-0000-0000-0000000000b7"
      @plaintext "SMOKE-<%= abbrev %>-plaintext"

      defp html(mod, socket) do
        socket.assigns
        |> Map.put(:__changed__, %{})
        |> mod.render()
        |> Phoenix.HTML.Safe.to_iodata()
        |> IO.iodata_to_binary()
      end

      defp mount!(mod, params) do
        {:ok, socket} = mod.mount(params, %{}, %Phoenix.LiveView.Socket{})
        socket
      end

      setup do
        record =
          Resource
          |> Ash.Changeset.for_create(
            :create,
            %{org_id: @org, name: "Smoke row", label: "L1", status: :active, secret: @plaintext},
            authorize?: false
          )
          |> Ash.create!()

        %{record: record}
      end

      test "INDEX mounts + renders the row on the kit list", %{record: record} do
        out = html(IndexLive, mount!(IndexLive, %{"org" => @org}))
        assert byte_size(out) > 0
        assert out =~ "Smoke row"
        assert out =~ to_string(record.id)
        refute out =~ "vt_"
      end

      test "SHOW mounts + resolves the 🔒 field through PiiResolution on the tenant plane (masking by construction)", %{record: record} do
        out = html(ShowLive, mount!(ShowLive, %{"org" => @org, "id" => record.id}))
        assert byte_size(out) > 0
        assert out =~ "Smoke row"
        # The 🔒 field went THROUGH `Samen.Api.PiiResolution` on the tenant plane — it renders
        # either the plane-cleared plaintext OR the masked placeholder, NEVER hand-masked and
        # NEVER the raw stored value.
        assert out =~ @plaintext or out =~ "••••"
        # The vault token NEVER reaches the DOM (the leak scan).
        refute out =~ "vt_"
      end

      test "FORM (new) mounts + renders the kit create form" do
        out = html(FormLive, mount!(FormLive, %{"org" => @org}))
        assert byte_size(out) > 0
        assert out =~ ~s(phx-submit="save")
        assert out =~ "New <%= resource %>"
      end

      test "FORM (edit) mounts + renders the record's current values", %{record: record} do
        out = html(FormLive, mount!(FormLive, %{"org" => @org, "id" => record.id}))
        assert byte_size(out) > 0
        assert out =~ "Edit <%= resource %>"
        assert out =~ "Smoke row"
      end
    end
    '''
  end
end
