defmodule Samen.RedPath do
  @moduledoc """
  Red-path / anti-tautology test scaffolding (WS-D D1.3; AC-G26-2;
  scope-authoring §9) — the sabotage-probe pattern from 15+ gates, encoded as
  a test-helper library so the four mandated per-scope test files collapse to
  a few macro calls (and so `samen.gen.resource`/`samen.gen.scope` can EMIT
  those files, D7/AC-G26-1):

    1. **policy matrix** — `policy_matrix/1` (+ `masked_by_default/1` for extra
       🔒 resources): cross-org read denied as a PROPERTY over org pairs,
       org-less fail-closed, cross-org write denied, positive read/write
       controls, PII `%Samen.Masked{}` by default. Canonical template:
       `demo/test/identity_policy_matrix_test.exs`.
    2. **RBAC red path** — `rbac_role_model/0` (pure `Samen.Scope.Role` rank
       matrix incl. fail-closed unknowns), `rbac_escalation_red_path/1`
       (escalation denied through the REAL authorizer, positive control),
       `admin_gate_red_path/1` (Tier-0 config rows: member write denied,
       admin allowed).
    3. **vault routing** — `vault_routing/1`: every 🔒 field lands a `vt_*`
       token in the raw domain row, plaintext NOWHERE in the row, ciphertext
       (never plaintext) in `pii_vault`, and the `Samen.Type.VaultField`
       last-line guard refuses a raw plaintext write.
    4. **catalog-parity red path** — `catalog_parity_red_path/1`: green when
       catalogued (positive control), deleting a `fld_field` row FLIPS the
       verifier (the anti-tautology probe is real, not vacuous — AC-G26-3),
       ghost-table detection.

  ## Anti-tautology discipline

  Every macro pairs its denial assertions with POSITIVE CONTROLS (the check is
  not vacuously false) and each guarantee is bound to a mechanism that a
  sabotage flips: e.g. sabotaging `Samen.Policy.OrgScope.filter/3` to
  `expr(true)` makes the `policy_matrix` cross-org property FAIL (the D1.3
  probe); deleting a catalog row makes `catalog_parity_red_path` FAIL. A test
  generated from these macros that cannot fail is a bug.

  ## Usage (a host test file becomes a few macro calls)

      defmodule MyApp.CrmScopePolicyMatrixTest do
        use MyApp.DataCase, async: false
        use Samen.RedPath, repo: MyApp.Repo

        policy_matrix(
          resource: MyApp.Crm.Person,
          org: MyApp.Identity.Org,
          attrs: fn org_id ->
            Map.merge(
              %{org_id: org_id, display_name: "Aster Vale"},
              Samen.Factory.person("Aster", "Vale", email: "aster@sample.invalid")
            )
          end,
          update: {:update, %{display_name: "changed"}},
          pii: [:full_name, :emails]
        )
      end

  `use Samen.RedPath` must come AFTER the host's `use MyApp.DataCase` (it
  needs the ExUnit case + SQL sandbox) and injects `use ExUnitProperties`
  (property tests) + `import Samen.RedPath`. Fixture writes go through
  `Samen.Factory.create!/3` — the vault-aware seed path (D1.2) — so seeded PII
  takes the SAME write path the assertions probe.
  """

  import ExUnit.Assertions
  import Ecto.Query, only: [from: 2]

  @orgless_actor %{id: "nobody", org_id: nil, role: :member}

  defmacro __using__(opts) do
    quote do
      use ExUnitProperties
      import Samen.RedPath

      @samen_red_path_repo unquote(opts[:repo])
    end
  end

  # ===========================================================================
  # 1. Policy matrix — the canonical org-scope + masked-by-default file.
  # ===========================================================================

  @doc """
  The org-scope policy matrix (file 1 of 4). Options:

    * `:resource` (required) — the mounted tenant-plane resource under test.
    * `:org` (required) — the org anchor resource (created with `%{name: name}`
      unless `:org_attrs` (a `fn name -> attrs end`) is given).
    * `:attrs` (required) — `fn org_id -> attrs end` for creating a row of
      `:resource` in that org (through `Samen.Factory.create!/3`,
      `authorize?: false` — the fixture plane).
    * `:update` — `{action, attrs_map}`; adds the cross-org-write-denied red
      path + the own-org positive write control.
    * `:pii` — list of 🔒 fields; adds the masked-by-default assertion.
    * `:role` — the acting role (default `:member`).
    * `:max_runs` — property iterations (default `25`).

  Generates: the cross-org read-denied PROPERTY (org B's rows are invisible —
  filtered, not forbidden), the org-less fail-closed test, the positive read
  control, and (per options) the write matrix + masked-by-default test.
  """
  defmacro policy_matrix(opts) do
    resource = Keyword.fetch!(opts, :resource)
    org = Keyword.fetch!(opts, :org)
    attrs = Keyword.fetch!(opts, :attrs)
    org_attrs = Keyword.get(opts, :org_attrs)
    update = Keyword.get(opts, :update)
    pii = Keyword.get(opts, :pii, [])
    role = Keyword.get(opts, :role, :member)
    max_runs = Keyword.get(opts, :max_runs, 25)
    label = label(resource, __CALLER__)

    read_tests =
      quote do
        property "an actor scoped to org A never reads another org's #{unquote(label)} rows (cross-org read denied)" do
          check all(
                  name_a <- string(:alphanumeric, min_length: 1, max_length: 8),
                  name_b <- string(:alphanumeric, min_length: 1, max_length: 8),
                  max_runs: unquote(max_runs)
                ) do
            org_a = Samen.RedPath.create_org!(unquote(org), "A-" <> name_a, unquote(org_attrs))
            org_b = Samen.RedPath.create_org!(unquote(org), "B-" <> name_b, unquote(org_attrs))

            rec_a =
              Samen.Factory.create!(unquote(resource), unquote(attrs).(org_a.id),
                authorize?: false
              )

            _rec_b =
              Samen.Factory.create!(unquote(resource), unquote(attrs).(org_b.id),
                authorize?: false
              )

            scope_a = Samen.RedPath.actor_scope(org_a.id, unquote(role), rec_a.id)

            # Actor A reads through the policy authorizer. Select org_id explicitly
            # so we can assert on the tenant boundary of every returned row.
            query = unquote(resource) |> Ash.Query.select([:id, :org_id])
            {:ok, seen} = Ash.read(query, actor: scope_a.actor, authorize?: true)
            seen_orgs = seen |> Enum.map(& &1.org_id) |> Enum.uniq()

            # Every row seen belongs to org A. Org B's row is invisible (not
            # forbidden — filtered out; the correct multi-tenant semantics).
            assert seen_orgs == [org_a.id]
            refute org_b.id in seen_orgs
          end
        end

        test "an org-less actor (no org_id scope) sees zero #{unquote(label)} rows (fail closed)" do
          org = Samen.RedPath.create_org!(unquote(org), "orgless-probe", unquote(org_attrs))
          _rec = Samen.Factory.create!(unquote(resource), unquote(attrs).(org.id), authorize?: false)

          # An actor with a nil org_id → the org-scope filter is `false`. Fail
          # closed: empty result or forbidden outright — never a foreign org's rows.
          case Ash.read(unquote(resource), actor: Samen.RedPath.orgless_actor(), authorize?: true) do
            {:ok, seen} -> assert seen == []
            {:error, %Ash.Error.Forbidden{}} -> assert true
          end
        end

        test "an actor DOES see its own org's #{unquote(label)} rows (positive case)" do
          org = Samen.RedPath.create_org!(unquote(org), "self-read", unquote(org_attrs))
          rec = Samen.Factory.create!(unquote(resource), unquote(attrs).(org.id), authorize?: false)
          scope = Samen.RedPath.actor_scope(org.id, unquote(role), rec.id)

          query = unquote(resource) |> Ash.Query.select([:id, :org_id])
          {:ok, seen} = Ash.read(query, actor: scope.actor, authorize?: true)
          assert length(seen) == 1
          assert hd(seen).org_id == org.id
        end
      end

    write_tests =
      if update do
        {update_action, update_attrs} = update

        quote do
          test "an actor cannot update a foreign org's #{unquote(label)} (cross-org write denied)" do
            org_a = Samen.RedPath.create_org!(unquote(org), "wa", unquote(org_attrs))
            org_b = Samen.RedPath.create_org!(unquote(org), "wb", unquote(org_attrs))

            rec_a =
              Samen.Factory.create!(unquote(resource), unquote(attrs).(org_a.id),
                authorize?: false
              )

            rec_b =
              Samen.Factory.create!(unquote(resource), unquote(attrs).(org_b.id),
                authorize?: false
              )

            scope_a = Samen.RedPath.actor_scope(org_a.id, unquote(role), rec_a.id)

            result =
              rec_b
              |> Ash.Changeset.for_update(unquote(update_action), unquote(update_attrs))
              |> Ash.update(actor: scope_a.actor, authorize?: true)

            assert {:error, %Ash.Error.Forbidden{}} = result
          end

          test "an actor CAN update its own org's #{unquote(label)} (positive write case)" do
            org = Samen.RedPath.create_org!(unquote(org), "selfwrite", unquote(org_attrs))
            rec = Samen.Factory.create!(unquote(resource), unquote(attrs).(org.id), authorize?: false)
            scope = Samen.RedPath.actor_scope(org.id, unquote(role), rec.id)

            assert {:ok, updated} =
                     rec
                     |> Ash.Changeset.for_update(unquote(update_action), unquote(update_attrs))
                     |> Ash.update(actor: scope.actor, authorize?: true)

            # Positive control is not vacuous: every written value round-trips.
            Enum.each(unquote(update_attrs), fn {field, value} ->
              assert Map.fetch!(updated, field) == value
            end)
          end
        end
      end

    masked_test =
      if pii != [] do
        quote do
          test "#{unquote(label)} PII (#{Enum.join(unquote(pii), ", ")}) is %Samen.Masked{} by default on a tenant-plane read" do
            org = Samen.RedPath.create_org!(unquote(org), "mask", unquote(org_attrs))
            rec = Samen.Factory.create!(unquote(resource), unquote(attrs).(org.id), authorize?: false)
            scope = Samen.RedPath.actor_scope(org.id, unquote(role), rec.id)

            query = unquote(resource) |> Ash.Query.select([:id | unquote(pii)])
            {:ok, [read_rec]} = Ash.read(query, actor: scope.actor, authorize?: true)

            Enum.each(unquote(pii), fn field ->
              assert %Samen.Masked{} = Map.fetch!(read_rec, field)
            end)

            # The masked value renders as bullets, never plaintext.
            rendered =
              read_rec
              |> Map.fetch!(hd(unquote(pii)))
              |> Phoenix.HTML.Safe.to_iodata()
              |> IO.iodata_to_binary()

            assert rendered =~ "•"
          end
        end
      end

    [read_tests, write_tests, masked_test] |> Enum.reject(&is_nil/1)
  end

  @doc """
  Masked-by-default for an ADDITIONAL 🔒 resource in the same file (e.g. the
  invitation in the Identity template). Options: `:resource`, `:org`, `:attrs`
  (`fn org_id -> attrs end`), `:pii` (required, 🔒 fields), `:role` (default
  `:member`), `:refute_plaintext` (strings that must not appear in the read
  struct), `:org_attrs`.
  """
  defmacro masked_by_default(opts) do
    resource = Keyword.fetch!(opts, :resource)
    org = Keyword.fetch!(opts, :org)
    attrs = Keyword.fetch!(opts, :attrs)
    pii = Keyword.fetch!(opts, :pii)
    role = Keyword.get(opts, :role, :member)
    refute_plaintext = Keyword.get(opts, :refute_plaintext, [])
    org_attrs = Keyword.get(opts, :org_attrs)
    label = label(resource, __CALLER__)

    quote do
      test "#{unquote(label)} PII (#{Enum.join(unquote(pii), ", ")}) is %Samen.Masked{} by default (🔒 vault routing)" do
        org = Samen.RedPath.create_org!(unquote(org), "#{unquote(label)}-mask", unquote(org_attrs))
        rec = Samen.Factory.create!(unquote(resource), unquote(attrs).(org.id), authorize?: false)
        scope = Samen.RedPath.actor_scope(org.id, unquote(role))

        query = unquote(resource) |> Ash.Query.select([:id | unquote(pii)])
        {:ok, [read_rec]} = Ash.read(query, actor: scope.actor, authorize?: true)

        Enum.each(unquote(pii), fn field ->
          value = Map.fetch!(read_rec, field)
          assert %Samen.Masked{} = value
          refute is_binary(value)
        end)

        # The plaintext never appears in the read struct.
        Enum.each(unquote(refute_plaintext), fn plaintext ->
          refute inspect(read_rec) =~ plaintext
        end)
      end
    end
  end

  # ===========================================================================
  # 2. RBAC red path — pure rank model + escalation through the authorizer.
  # ===========================================================================

  @doc """
  The pure `Samen.Scope.Role` rank-model matrix (mechanism behind the RBAC red
  path): escalation denied, positive controls, unknown/nil roles fail closed.
  """
  defmacro rbac_role_model(_opts \\ []) do
    quote do
      test "role rank model: a member cannot manage an admin; an admin cannot manage an owner" do
        alias Samen.Scope.Role

        # The mechanism behind the red path.
        refute Role.may_manage?(:member, :admin)
        refute Role.may_manage?(:member, :owner)
        refute Role.may_manage?(:admin, :owner)
        refute Role.may_manage?(:admin, :admin)
        refute Role.may_manage?(:owner, :owner)
        refute Role.may_manage?(:viewer, :viewer)

        # The allowed cases (positive control — the check is not vacuously false).
        assert Role.may_manage?(:owner, :admin)
        assert Role.may_manage?(:owner, :member)
        assert Role.may_manage?(:admin, :member)
        assert Role.may_manage?(:admin, :viewer)

        # Unknown / nil roles rank below everything (fail closed).
        refute Role.may_manage?(nil, :viewer)
        refute Role.may_manage?(:bogus, :viewer)
      end
    end
  end

  @doc """
  Role escalation denied through the REAL policy authorizer on membership
  writes (`Samen.Policy.RoleAtLeast` + `Samen.Policy.ManageRole`). Options:
  `:membership` (the membership resource), `:org`, `:target_resource` +
  `:target_attrs` (`fn org_id -> attrs end`, the user being granted a role),
  `:fk` (membership FK to the target, default `:user_id`), `:org_attrs`.
  """
  defmacro rbac_escalation_red_path(opts) do
    membership = Keyword.fetch!(opts, :membership)
    org = Keyword.fetch!(opts, :org)
    target_resource = Keyword.fetch!(opts, :target_resource)
    target_attrs = Keyword.fetch!(opts, :target_attrs)
    fk = Keyword.get(opts, :fk, :user_id)
    org_attrs = Keyword.get(opts, :org_attrs)

    quote do
      test "a member actor CANNOT create an admin membership (RoleAtLeast denies)" do
        org = Samen.RedPath.create_org!(unquote(org), "esc1", unquote(org_attrs))

        target =
          Samen.Factory.create!(unquote(target_resource), unquote(target_attrs).(org.id),
            authorize?: false
          )

        member_scope = Samen.RedPath.actor_scope(org.id, :member)

        result =
          unquote(membership)
          |> Ash.Changeset.for_create(
            :create,
            %{:org_id => org.id, unquote(fk) => target.id, :role => :admin}
          )
          |> Ash.create(actor: member_scope.actor, authorize?: true)

        assert {:error, %Ash.Error.Forbidden{}} = result
      end

      test "an admin actor CANNOT create an owner membership (ManageRole denies escalation)" do
        org = Samen.RedPath.create_org!(unquote(org), "esc2", unquote(org_attrs))

        target =
          Samen.Factory.create!(unquote(target_resource), unquote(target_attrs).(org.id),
            authorize?: false
          )

        admin_scope = Samen.RedPath.actor_scope(org.id, :admin)

        result =
          unquote(membership)
          |> Ash.Changeset.for_create(
            :create,
            %{:org_id => org.id, unquote(fk) => target.id, :role => :owner}
          )
          |> Ash.create(actor: admin_scope.actor, authorize?: true)

        assert {:error, %Ash.Error.Forbidden{}} = result
      end

      test "an admin actor CAN create a member membership (positive control)" do
        org = Samen.RedPath.create_org!(unquote(org), "esc3", unquote(org_attrs))

        target =
          Samen.Factory.create!(unquote(target_resource), unquote(target_attrs).(org.id),
            authorize?: false
          )

        admin_scope = Samen.RedPath.actor_scope(org.id, :admin)

        assert {:ok, membership} =
                 unquote(membership)
                 |> Ash.Changeset.for_create(
                   :create,
                   %{:org_id => org.id, unquote(fk) => target.id, :role => :member}
                 )
                 |> Ash.create(actor: admin_scope.actor, authorize?: true)

        assert membership.role == :member
      end

      test "an admin CANNOT promote an existing member to owner (update escalation denied)" do
        org = Samen.RedPath.create_org!(unquote(org), "esc4", unquote(org_attrs))

        target =
          Samen.Factory.create!(unquote(target_resource), unquote(target_attrs).(org.id),
            authorize?: false
          )

        admin_scope = Samen.RedPath.actor_scope(org.id, :admin)

        {:ok, membership} =
          unquote(membership)
          |> Ash.Changeset.for_create(
            :create,
            %{:org_id => org.id, unquote(fk) => target.id, :role => :member}
          )
          |> Ash.create(actor: admin_scope.actor, authorize?: true)

        result =
          membership
          |> Ash.Changeset.for_update(:update, %{role: :owner})
          |> Ash.update(actor: admin_scope.actor, authorize?: true)

        assert {:error, %Ash.Error.Forbidden{}} = result
      end
    end
  end

  @doc """
  Admin-gated writes on a Tier-0 config resource: the deny-role's create is
  Forbidden (red path), the allow-role's create succeeds (positive control).
  Options: `:resource`, `:org`, `:attrs` (`fn org_id -> attrs end`),
  `:deny_role` (default `:member`), `:allow_role` (default `:admin`),
  `:org_attrs`.
  """
  defmacro admin_gate_red_path(opts) do
    resource = Keyword.fetch!(opts, :resource)
    org = Keyword.fetch!(opts, :org)
    attrs = Keyword.fetch!(opts, :attrs)
    deny_role = Keyword.get(opts, :deny_role, :member)
    allow_role = Keyword.get(opts, :allow_role, :admin)
    org_attrs = Keyword.get(opts, :org_attrs)
    label = label(resource, __CALLER__)

    quote do
      test "a #{unquote(deny_role)} actor cannot create a #{unquote(label)} (admin-gate red path)" do
        org = Samen.RedPath.create_org!(unquote(org), "gate-deny", unquote(org_attrs))
        scope = Samen.RedPath.actor_scope(org.id, unquote(deny_role))

        result =
          unquote(resource)
          |> Ash.Changeset.for_create(:create, unquote(attrs).(org.id))
          |> Ash.create(actor: scope.actor, authorize?: true)

        assert {:error, %Ash.Error.Forbidden{}} = result
      end

      test "an #{unquote(allow_role)} actor CAN create a #{unquote(label)} (positive control)" do
        org = Samen.RedPath.create_org!(unquote(org), "gate-allow", unquote(org_attrs))
        scope = Samen.RedPath.actor_scope(org.id, unquote(allow_role))

        assert {:ok, _created} =
                 unquote(resource)
                 |> Ash.Changeset.for_create(:create, unquote(attrs).(org.id))
                 |> Ash.create(actor: scope.actor, authorize?: true)
      end
    end
  end

  # ===========================================================================
  # 3. Vault routing — vt_* tokens at rest, plaintext nowhere, last-line guard.
  # ===========================================================================

  @doc """
  Vault routing (file 3 of 4). Options: `:resource`, `:org`, `:attrs`
  (`fn org_id -> attrs end` — must write the 🔒 fields), `:plaintexts`
  (required: the literal PII strings the attrs carry — asserted absent from
  the raw row AND refused by the `VaultField` guard), `:fields` (the 🔒 fields
  the attrs write; default: all of the resource's `pii_attribute`s),
  `:org_attrs`. Requires `use Samen.RedPath, repo: MyApp.Repo`.

  Generates the raw-row scan test (tokens + no plaintext + ciphertext vault
  rows) and the `Samen.Type.VaultField` last-line-guard red path.
  """
  defmacro vault_routing(opts) do
    resource = Keyword.fetch!(opts, :resource)
    org = Keyword.fetch!(opts, :org)
    attrs = Keyword.fetch!(opts, :attrs)
    plaintexts = Keyword.fetch!(opts, :plaintexts)
    fields = Keyword.get(opts, :fields, :all)
    org_attrs = Keyword.get(opts, :org_attrs)
    label = label(resource, __CALLER__)

    quote do
      test "#{unquote(label)} 🔒 fields write vt_ tokens to the vault; plaintext never in the domain row" do
        org = Samen.RedPath.create_org!(unquote(org), "vault-#{unquote(label)}", unquote(org_attrs))
        rec = Samen.Factory.create!(unquote(resource), unquote(attrs).(org.id), authorize?: false)

        Samen.RedPath.assert_vault_routed!(
          @samen_red_path_repo,
          unquote(resource),
          rec.id,
          unquote(fields),
          unquote(plaintexts)
        )
      end

      test "the VaultField last-line guard refuses a raw #{unquote(label)} plaintext write (red path)" do
        # Even if a bug bypassed Samen.Vault.Change, the VaultField type's dump
        # guard refuses to persist anything that is not already a vt_* token.
        assert {:ok, "vt_realtoken"} = Samen.Type.VaultField.dump_to_native("vt_realtoken", [])

        Enum.each(unquote(plaintexts), fn plaintext ->
          assert :error == Samen.Type.VaultField.dump_to_native(plaintext, [])
        end)
      end
    end
  end

  # ===========================================================================
  # 4. Catalog-parity red path — the verifier is a genuine discriminator.
  # ===========================================================================

  @doc """
  Catalog-parity red path (file 4 of 4; AC-G26-3). Options: `:table` +
  `:column` (the physical names whose `fld_field` row gets deleted inside the
  sandbox transaction), `:ghost_table` (optional: a table whose whole
  `tam_table` entry is removed → ghost-table violation). Requires
  `use Samen.RedPath, repo: MyApp.Repo`.

  Green control first, then the sabotage MUST flip the verifier — if the check
  passed regardless of catalog contents, the probe fails (anti-tautology).
  The sandbox rolls the deletes back automatically.
  """
  defmacro catalog_parity_red_path(opts) do
    table = Keyword.fetch!(opts, :table)
    column = Keyword.fetch!(opts, :column)
    ghost_table = Keyword.get(opts, :ghost_table)

    base =
      quote do
        test "catalog_parity is GREEN when every #{unquote(table)} column is catalogued (positive control)" do
          violations = Mix.Tasks.Samen.Verify.CatalogParity.check(@samen_red_path_repo)
          assert violations == [], "Expected no violations; got: #{inspect(violations)}"
        end

        test "deleting the catalog row for #{unquote(table)}.#{unquote(column)} makes catalog_parity FAIL (anti-tautology probe)" do
          # Sanity: green first.
          assert Mix.Tasks.Samen.Verify.CatalogParity.check(@samen_red_path_repo) == []

          # Sabotage: remove the fld_field row (as if the mount migration forgot
          # catalog_sync for that column). Runs inside the sandbox transaction —
          # rolled back at test end.
          {:ok, _} =
            @samen_red_path_repo.query(
              "DELETE FROM fld_field WHERE fld_table_name = '#{unquote(table)}' " <>
                "AND fld_column_name = '#{unquote(column)}'"
            )

          violations = Mix.Tasks.Samen.Verify.CatalogParity.check(@samen_red_path_repo)

          refute violations == [],
                 "catalog_parity must FAIL when #{unquote(table)}.#{unquote(column)} is uncatalogued"

          assert Enum.any?(violations, fn v ->
                   v =~ unquote(table) and (v =~ "uncatalogued" or v =~ unquote(column))
                 end),
                 "expected a violation for #{unquote(table)}.#{unquote(column)}; got: #{inspect(violations)}"
        end
      end

    ghost =
      if ghost_table do
        quote do
          test "removing the #{unquote(ghost_table)} tam_table entry is caught as a ghost table" do
            assert Mix.Tasks.Samen.Verify.CatalogParity.check(@samen_red_path_repo) == []

            {:ok, _} =
              @samen_red_path_repo.query(
                "DELETE FROM fld_field WHERE fld_table_name = '#{unquote(ghost_table)}'"
              )

            {:ok, _} =
              @samen_red_path_repo.query(
                "DELETE FROM tam_table WHERE tam_table_name = '#{unquote(ghost_table)}'"
              )

            violations = Mix.Tasks.Samen.Verify.CatalogParity.check(@samen_red_path_repo)

            assert Enum.any?(violations, fn v ->
                     v =~ unquote(ghost_table) and v =~ "ghost table"
                   end),
                   "expected a 'ghost table: #{unquote(ghost_table)}' violation; got: #{inspect(violations)}"
          end
        end
      end

    [base, ghost] |> Enum.reject(&is_nil/1)
  end

  # ===========================================================================
  # Runtime helpers (called from the generated test bodies).
  # ===========================================================================

  @doc """
  Create an org anchor row on the fixture plane (`authorize?: false`), through
  `Samen.Factory.create!/3`. `attrs_fun` (`fn name -> attrs end`) overrides the
  default `%{name: name}` shape.
  """
  def create_org!(org_resource, name, attrs_fun \\ nil) do
    attrs = if attrs_fun, do: attrs_fun.(name), else: %{name: name}
    Samen.Factory.create!(org_resource, attrs, authorize?: false)
  end

  @doc """
  A tenant-plane `%Samen.Scope{}` for `org_id` with `role` — the acting scope
  the generated tests authorize as. `id` defaults to a fresh UUID.
  """
  def actor_scope(org_id, role \\ :member, id \\ nil) do
    Samen.Scope.new(%{id: id || Ash.UUID.generate(), org_id: org_id, role: role})
  end

  @doc """
  The canonical org-less actor (`org_id: nil`) for the fail-closed test.
  """
  def orgless_actor, do: @orgless_actor

  @doc """
  Raw-row vault-routing assertions for one record (the file-3 core):

    * each checked 🔒 field's PHYSICAL column holds a `vt_*` token;
    * none of `plaintexts` appears in the token columns, the WHOLE raw row,
      or any `pii_vault` ciphertext for the subject;
    * at least one vault row per checked field exists, each with binary
      ciphertext.

  `fields` is `:all` (every `pii_attribute`) or a list of logical field names.
  """
  def assert_vault_routed!(repo, resource, record_id, fields, plaintexts) do
    if is_nil(repo) do
      raise ArgumentError,
            "Samen.RedPath.assert_vault_routed!/5 needs a repo — " <>
              "`use Samen.RedPath, repo: MyApp.Repo`"
    end

    all_fields = Samen.Pii.Info.fields(resource)

    checked =
      case fields do
        :all -> all_fields
        names when is_list(names) -> Enum.filter(all_fields, &(&1.name in names))
      end

    assert checked != [],
           "no vault-routed (pii_attribute) fields to check on #{inspect(resource)} " <>
             "for #{inspect(fields)} — a vacuous vault-routing test is a tautology"

    table = AshPostgres.DataLayer.Info.table(resource)
    pk_attr = Ash.Resource.Info.attribute(resource, :id)
    pk = (pk_attr && (pk_attr.source || pk_attr.name)) || :id
    pk_value = Ecto.UUID.dump!(record_id)

    # Each 🔒 field's raw domain column holds a vt_* token, never plaintext.
    Enum.each(checked, fn field ->
      %{rows: [[value]]} =
        repo.query!("SELECT #{field.storage_name} FROM #{table} WHERE #{pk} = $1", [pk_value])

      assert is_binary(value) and String.starts_with?(value, "vt_"),
             "expected #{table}.#{field.storage_name} to hold a vt_* token, got: #{inspect(value)}"

      Enum.each(plaintexts, fn plaintext ->
        refute value =~ plaintext,
               "plaintext #{inspect(plaintext)} found in #{table}.#{field.storage_name}"
      end)
    end)

    # The plaintext appears NOWHERE in the whole raw row.
    %{rows: [row_values]} = repo.query!("SELECT * FROM #{table} WHERE #{pk} = $1", [pk_value])
    row_text = row_values |> Enum.map(&inspect/1) |> Enum.join(" ")

    Enum.each(plaintexts, fn plaintext ->
      refute row_text =~ plaintext,
             "plaintext #{inspect(plaintext)} found in the raw #{table} row"
    end)

    # Vault rows exist for the subject, carrying ciphertext (binary), not plaintext.
    vault_rows =
      repo.all(from(v in Samen.Vault.VaultRow, where: v.subject_id == ^record_id))

    assert length(vault_rows) >= length(checked),
           "expected >= #{length(checked)} pii_vault rows for subject #{record_id}, " <>
             "got #{length(vault_rows)}"

    Enum.each(vault_rows, fn row ->
      assert is_binary(row.ciphertext)

      Enum.each(plaintexts, fn plaintext ->
        refute row.ciphertext =~ plaintext,
               "plaintext #{inspect(plaintext)} found in a pii_vault ciphertext"
      end)
    end)

    :ok
  end

  # A short, unique-enough label for generated test names (multiple macro
  # invocations per module must not collide on test names).
  defp label(resource_ast, caller) do
    resource_ast
    |> Macro.expand(caller)
    |> Module.split()
    |> List.last()
  end
end
