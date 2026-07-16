defmodule Samen.Gen.Post do
  @moduledoc """
  The engine behind the POST-APP generators (WS-D D7a; design.md §1.1 "Post-app
  generators"; ACs AC-G4-7 / AC-G26-1 / AC-G26-3): `mix samen.gen.scope` and
  `mix samen.gen.resource`. Where `Samen.Gen.App` scaffolds a whole app from zero,
  these ADD to an app that already exists — the second scope, the second resource —
  so *every resource after the first is scaffolded, not hand-copied against a prose
  checklist* (scope-authoring §10).

  Reuses the `Samen.Gen.App` engine primitives verbatim: the same pure `<%= key %>`
  substitution (`render/2`), the same fail-closed abbrev validation
  (`validate_against!`-shaped rules), and the same append-only registry reservation
  (`reserve_abbrevs!` — the CURRENT mechanism; ADR-023/D8 upgrades it to the
  host-namespaced allocator later, and this module routes through whatever
  `Samen.Gen.App.reserve_abbrevs!/2` becomes). No new template ENGINE.

  ## What `mix samen.gen.scope` emits (into an existing app dir)

  A new authored **domain module** (`<App>.<Scope>` — an `Ash.Domain`), registered in
  BOTH `:ash_domains` config lists (the app's own and `:samen_core`, so the verifier
  gate scans it). A scope is a namespace the vertical author owns; `gen.resource` then
  lands Tier-0 resources into it. The scope module is emitted EMPTY (no resources yet)
  and `gen.resource` appends resources + wires the domain's `resources do … end`.

  ## What `mix samen.gen.resource` emits (into an existing scope)

  Per the malleability ladder (scope-authoring §7) the default is a **Tier-0 config
  resource**: org-scoped (OrgScope on reads), **admin-gated writes** (RoleAtLeast
  `:admin` on create/update/destroy — the doc's "bounded-enum + admin-gated" shape),
  a bounded-enum `status` column, plain label columns, and ONE scalar `pii do` vault
  field (so the vault-routing red path is non-vacuous). It emits:

    * the resource module on the `use Samen.Resource` base macro idiom (Tier-3 code
      composition — the malleability ladder's most-capable rung, which a Tier-0
      *resource* is authored on: substrate inherited, only the 20% authored);
    * a `Samen.Migration` (abbrev-prefixed columns + `catalog_sync`) for the table;
    * the abbrev registry append (the current append-only mechanism);
    * the resource wired into its domain's `resources do … end`;
    * the FOUR mandated G26 test files as thin `Samen.RedPath` macro calls
      (policy matrix + masked-by-default PII, RBAC admin-gate red path, vault
      routing, catalog-parity red path) + a per-resource `anti_tautology_probe.exs`.

  The four files target the app's `<App>.Operator.{Org,User,Membership}` mount (the
  `--web` default app's Identity substrate) as the org anchor / RBAC subjects — the
  same substrate the flagship probe boots against.

  ## Fail-closed

  `validate!/1` refuses: a non-existent app dir, a scope/resource module that already
  exists in the app, a non-3-letter abbrev, an abbrev colliding with a DIFFERENT owner
  in the global registry (permanence — ADR-006), and (for `gen.resource`) a target
  scope domain that is not present in the app.
  """

  alias Samen.Gen.App
  alias Samen.AbbrevRegistry

  # ===========================================================================
  # Scope generation
  # ===========================================================================

  defmodule ScopeSpec do
    @moduledoc "A fully-derived `mix samen.gen.scope` spec."
    @enforce_keys [:app_module, :otp_app, :app_dir, :scope, :scope_module]
    defstruct [:app_module, :otp_app, :app_dir, :scope, :scope_module]
  end

  @doc """
  Build a scope spec. `opts`: `:app_dir` (the existing app root), `:scope` (the scope
  base name, e.g. `Crm`). The app module + otp_app are read from the app dir's mix.exs.
  """
  def build_scope_spec(opts) do
    app_dir = Keyword.fetch!(opts, :app_dir) |> Path.expand()
    scope = Keyword.fetch!(opts, :scope) |> to_string()
    {app_module, otp_app} = read_app_identity!(app_dir)

    %ScopeSpec{
      app_module: app_module,
      otp_app: otp_app,
      app_dir: app_dir,
      scope: scope,
      scope_module: "#{app_module}.#{scope}"
    }
  end

  @doc "Fail-closed validation for a scope spec."
  def validate_scope!(%ScopeSpec{} = s) do
    unless File.dir?(s.app_dir) do
      raise ArgumentError, "app dir does not exist: #{s.app_dir}"
    end

    unless Regex.match?(~r/\A[A-Z][A-Za-z0-9]*\z/, s.scope) do
      raise ArgumentError, "--scope must be a valid Elixir module alias (got #{inspect(s.scope)})"
    end

    scope_file = scope_file_path(s)

    if File.exists?(scope_file) do
      raise ArgumentError,
            "scope #{s.scope_module} already exists (#{scope_file}). Refusing to overwrite."
    end

    :ok
  end

  @doc "Write the scope domain module + register it in both `:ash_domains` lists."
  def write_scope!(%ScopeSpec{} = s) do
    b = scope_bindings(s)
    dest = scope_file_path(s)
    File.mkdir_p!(Path.dirname(dest))
    File.write!(dest, App.render(Samen.Gen.PostTemplates.scope_module(), b))

    register_domain!(s.app_dir, s.otp_app, s.app_module, s.scope_module)
    :ok
  end

  # ===========================================================================
  # Resource generation
  # ===========================================================================

  defmodule ResourceSpec do
    @moduledoc "A fully-derived `mix samen.gen.resource` spec."
    @enforce_keys [
      :app_module,
      :otp_app,
      :app_dir,
      :scope,
      :scope_module,
      :resource,
      :resource_module,
      :abbrev,
      :table
    ]
    defstruct [
      :app_module,
      :otp_app,
      :app_dir,
      :scope,
      :scope_module,
      :resource,
      :resource_module,
      :abbrev,
      :table,
      :migration_ts
    ]
  end

  @doc """
  Build a resource spec. `opts`: `:app_dir`, `:scope` (the target scope base name),
  `:resource` (the resource base name, e.g. `Widget`), `:abbrev` (3 lowercase letters).
  """
  def build_resource_spec(opts) do
    app_dir = Keyword.fetch!(opts, :app_dir) |> Path.expand()
    scope = Keyword.fetch!(opts, :scope) |> to_string()
    resource = Keyword.fetch!(opts, :resource) |> to_string()
    abbrev = Keyword.fetch!(opts, :abbrev) |> to_string() |> String.downcase()
    {app_module, otp_app} = read_app_identity!(app_dir)

    scope_module = "#{app_module}.#{scope}"

    %ResourceSpec{
      app_module: app_module,
      otp_app: otp_app,
      app_dir: app_dir,
      scope: scope,
      scope_module: scope_module,
      resource: resource,
      resource_module: "#{scope_module}.#{resource}",
      abbrev: abbrev,
      table: "#{abbrev}_#{Macro.underscore(resource)}",
      migration_ts: Keyword.get(opts, :migration_ts, next_migration_ts(app_dir))
    }
  end

  @doc """
  Fail-closed validation for a resource spec. Optionally pass a registry map
  (`validate_resource!/2`) to make the abbrev-collision rule unit-testable without
  touching the committed registry.
  """
  def validate_resource!(%ResourceSpec{} = s), do: validate_resource!(s, AbbrevRegistry.load())

  def validate_resource!(%ResourceSpec{} = s, registry) when is_map(registry) do
    unless File.dir?(s.app_dir) do
      raise ArgumentError, "app dir does not exist: #{s.app_dir}"
    end

    unless Regex.match?(~r/\A[A-Z][A-Za-z0-9]*\z/, s.resource) do
      raise ArgumentError,
            "--resource must be a valid Elixir module alias (got #{inspect(s.resource)})"
    end

    unless Regex.match?(~r/\A[a-z]{3}\z/, s.abbrev) do
      raise ArgumentError, "--abbrev must be exactly 3 lowercase letters (got #{inspect(s.abbrev)})"
    end

    # The target scope must already be a registered domain in the app (gen.scope first).
    unless File.exists?(scope_file_path_for(s.app_dir, s.app_module, s.scope)) do
      raise ArgumentError,
            "target scope #{s.scope_module} does not exist. Run " <>
              "`mix samen.gen.scope --scope #{s.scope}` first."
    end

    resource_file = resource_file_path(s)

    if File.exists?(resource_file) do
      raise ArgumentError,
            "resource #{s.resource_module} already exists (#{resource_file}). Refusing to overwrite."
    end

    # ADR-006 permanence: an abbrev owned by a DIFFERENT module is never recycled.
    case Map.get(registry, s.abbrev) do
      nil ->
        :ok

      owner when owner == s.resource_module ->
        :ok

      other ->
        raise ArgumentError,
              "abbrev #{inspect(s.abbrev)} is already reserved to #{other} in the global " <>
                "registry (#{AbbrevRegistry.path()}). Abbrevs are permanent and never " <>
                "recycled — pick a different --abbrev."
    end

    :ok
  end

  @doc "The single `{abbrev, owner}` pair this resource reserves."
  def reserved_pairs(%ResourceSpec{} = s), do: [{s.abbrev, s.resource_module}]

  @doc """
  Reserve the resource's abbrev via the ADR-023 allocator (`Samen.Abbrev.Allocator`),
  writing into the app's HOST namespace (`s.otp_app`) — the human never hand-edits
  `abbrev_registry.json`. Append-only + idempotent + fail-closed on cross-owner collision
  within the host namespace *or* the global cross-host net. `path` defaults to the
  committed registry; probes/tests pass a scratch copy.
  """
  def reserve_abbrevs!(%ResourceSpec{} = s, path \\ AbbrevRegistry.path()) do
    for {abbrev, owner} <- reserved_pairs(s) do
      Samen.Abbrev.Allocator.reserve!(to_string(s.otp_app), abbrev, owner, path)
    end

    :ok
  end

  @doc """
  Write the resource module + its migration + the FOUR G26 test files + the
  per-resource anti-tautology probe, and wire the resource into its scope domain.
  """
  def write_resource!(%ResourceSpec{} = s) do
    b = resource_bindings(s)

    files = [
      {resource_rel_path(s), Samen.Gen.PostTemplates.resource_module()},
      {"priv/repo/migrations/#{s.migration_ts}_add_#{Macro.underscore(s.resource)}.exs",
       Samen.Gen.PostTemplates.resource_migration()},
      {"test/#{test_stem(s)}_policy_matrix_test.exs",
       Samen.Gen.PostTemplates.policy_matrix_test()},
      {"test/#{test_stem(s)}_rbac_red_path_test.exs", Samen.Gen.PostTemplates.rbac_red_path_test()},
      {"test/#{test_stem(s)}_vault_routing_test.exs",
       Samen.Gen.PostTemplates.vault_routing_test()},
      {"test/#{test_stem(s)}_catalog_parity_red_path_test.exs",
       Samen.Gen.PostTemplates.catalog_parity_red_path_test()},
      {"priv/#{test_stem(s)}_anti_tautology_probe.exs",
       Samen.Gen.PostTemplates.anti_tautology_probe()}
    ]

    for {rel, template} <- files do
      dest = Path.join(s.app_dir, App.render(rel, b))
      File.mkdir_p!(Path.dirname(dest))
      File.write!(dest, App.render(template, b))
    end

    wire_resource_into_domain!(s)
    :ok
  end

  @doc """
  The relative test-file stem — lowercased `<scope>_<resource>` (e.g. `crm_widget`) —
  the four mandated files and the probe are named from it.
  """
  def test_stem(%ResourceSpec{} = s) do
    "#{Macro.underscore(s.scope)}_#{Macro.underscore(s.resource)}"
  end

  # ===========================================================================
  # Bindings
  # ===========================================================================

  @doc false
  def scope_bindings(%ScopeSpec{} = s) do
    %{
      "module" => s.app_module,
      "otp_app" => to_string(s.otp_app),
      "scope" => s.scope,
      "scope_module" => s.scope_module
    }
  end

  @doc false
  def resource_bindings(%ResourceSpec{} = s) do
    %{
      "module" => s.app_module,
      "otp_app" => to_string(s.otp_app),
      "scope" => s.scope,
      "scope_module" => s.scope_module,
      "resource" => s.resource,
      "resource_module" => s.resource_module,
      "abbrev" => s.abbrev,
      "table" => s.table,
      "test_stem" => test_stem(s)
    }
  end

  # ===========================================================================
  # App-identity + domain-registration helpers (operate on the app tree)
  # ===========================================================================

  @doc """
  Read `{app_module_string, otp_app_atom}` from an app dir's mix.exs — the `app:`
  key and the `mod: {<Module>.Application, []}` line.
  """
  def read_app_identity!(app_dir) do
    mix_exs = Path.join(app_dir, "mix.exs")

    unless File.exists?(mix_exs) do
      raise ArgumentError, "not a mix app dir (no mix.exs): #{app_dir}"
    end

    src = File.read!(mix_exs)

    otp_app =
      case Regex.run(~r/app:\s*:([a-z0-9_]+)/, src) do
        [_, app] -> String.to_atom(app)
        _ -> raise ArgumentError, "could not read `app:` from #{mix_exs}"
      end

    app_module =
      case Regex.run(~r/mod:\s*\{([A-Za-z0-9_.]+)\.Application/, src) do
        [_, mod] -> mod
        _ -> Macro.camelize(to_string(otp_app))
      end

    {app_module, otp_app}
  end

  # Register a new domain in BOTH `:ash_domains` lists in config/config.exs (the app's
  # own ecto/ash registration + the `:samen_core` list the verifier gate scans). The
  # edit is idempotent — a domain already listed is left as-is.
  defp register_domain!(app_dir, _otp_app, app_module, domain_module) do
    config = Path.join(app_dir, "config/config.exs")
    src = File.read!(config)

    if String.contains?(src, domain_module) do
      :ok
    else
      # Two `:ash_domains` lists (the app's own + the `:samen_core` gate list). Both emit
      # in single-line (headless) OR multi-line (--web) form; the LAST element is the app's
      # last domain. Append the new domain as the last element of BOTH lists, format-
      # agnostically: find each list body, append the domain, and re-emit.
      updated = insert_into_ash_domains_lists(src, config, app_module, domain_module)
      File.write!(config, updated)
      :ok
    end
  end

  # Append `domain_module` as the last element of every `ash_domains: [ … ]` list in the
  # config source, handling both single-line and multi-line list forms. Fails closed if
  # the expected two lists are not both found.
  defp insert_into_ash_domains_lists(src, config, _app_module, domain_module) do
    # Match `ash_domains: [ … ]` (own list) and `:ash_domains, [ … ]` (samen_core list),
    # non-greedy over the bracket body (which may span lines but never nests a `[`).
    re = ~r/(ash_domains(?::\s*|,\s*)\[)([^\[\]]*?)(\])/s

    {new_src, count} =
      Regex.replace(re, src, fn _whole, open, body, close ->
        # `body` is the element list — append the new domain, matching the existing
        # separator style (multi-line indented vs. single-line comma-joined).
        trimmed = String.trim_trailing(body)

        appended =
          if String.contains?(trimmed, "\n") do
            # Multi-line: infer the element indentation from the last element line.
            indent =
              case Regex.run(~r/\n([ \t]+)\S[^\n]*\z/, trimmed) do
                [_, ws] -> ws
                _ -> "  "
              end

            String.trim_trailing(trimmed) <> ",\n#{indent}#{domain_module}\n"
          else
            trimmed <> ", #{domain_module}"
          end

        open <> appended <> close
      end)
      |> then(fn s -> {s, length(Regex.scan(re, src))} end)

    if count < 2 do
      raise ArgumentError,
            "expected two `ash_domains` lists in #{config} to register the new domain; " <>
              "found #{count}."
    end

    new_src
  end

  # Wire the resource into its scope domain's `resources do … end` block.
  defp wire_resource_into_domain!(%ResourceSpec{} = s) do
    scope_file = scope_file_path_for(s.app_dir, s.app_module, s.scope)
    src = File.read!(scope_file)

    if String.contains?(src, "resource(#{s.resource_module})") do
      :ok
    else
      # Find the `resources do … end` block and insert the resource just before its
      # closing `end`, matching the closing `end`'s indentation (+2 for the new line).
      # Works whether the block is empty (`resources do\n<i>end`) or already populated.
      re = ~r/(resources do\n(?:[^\n]*\n)*?)([ \t]*)(end)/

      unless Regex.match?(re, src) do
        raise ArgumentError,
              "could not find the `resources do … end` block in #{scope_file} to wire " <>
                "#{s.resource_module} into."
      end

      updated =
        Regex.replace(
          re,
          src,
          fn _whole, head, indent, endkw ->
            "#{head}#{indent}  resource(#{s.resource_module})\n#{indent}#{endkw}"
          end,
          global: false
        )

      File.write!(scope_file, updated)
      :ok
    end
  end

  # ===========================================================================
  # Path helpers
  # ===========================================================================

  defp scope_file_path(%ScopeSpec{} = s),
    do: scope_file_path_for(s.app_dir, s.app_module, s.scope)

  defp scope_file_path_for(app_dir, app_module, scope) do
    otp_app = Macro.underscore(app_module)
    Path.join([app_dir, "lib", otp_app, "#{Macro.underscore(scope)}.ex"])
  end

  defp resource_file_path(%ResourceSpec{} = s), do: Path.join(s.app_dir, resource_rel_path(s))

  defp resource_rel_path(%ResourceSpec{} = s) do
    Path.join([
      "lib",
      Macro.underscore(s.app_module),
      Macro.underscore(s.scope),
      "#{Macro.underscore(s.resource)}.ex"
    ])
  end

  # The next migration timestamp — one second past the LATEST existing migration, so a
  # generated resource migration always sorts AFTER the app's substrate migrations
  # (and after any earlier gen'd resource) regardless of wall-clock.
  defp next_migration_ts(app_dir) do
    dir = Path.join(app_dir, "priv/repo/migrations")

    latest =
      case File.ls(dir) do
        {:ok, files} ->
          files
          |> Enum.map(&(String.split(&1, "_") |> hd()))
          |> Enum.filter(&Regex.match?(~r/\A\d{14}\z/, &1))
          |> Enum.map(&String.to_integer/1)
          |> Enum.max(fn -> 20_260_705_010_000 end)

        _ ->
          20_260_705_010_000
      end

    Integer.to_string(latest + 1)
  end
end
