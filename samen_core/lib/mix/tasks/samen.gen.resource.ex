defmodule Mix.Tasks.Samen.Gen.Resource do
  @shortdoc "Scaffold a Tier-0 resource + its migration + the four G26 test files into a scope."

  @moduledoc """
  `mix samen.gen.resource` — the POST-APP resource generator (WS-D D7a; AC-G4-7 /
  AC-G26-1 / AC-G26-3). Adds a resource to an existing authored scope (see
  `mix samen.gen.scope`), automating the resource half of scope-authoring §10 so
  *every resource after the first is scaffolded, not hand-copied against a prose
  checklist*.

  Per the malleability ladder (scope-authoring §7) the default is a **Tier-0 config
  resource**: org-scoped reads, admin-gated writes (RoleAtLeast `:admin`), a bounded-enum
  `status`, plain label columns, and ONE scalar `pii do` vault field. It emits:

    * the resource module (`use Samen.Resource` base macro idiom);
    * a `Samen.Migration` (abbrev-prefixed columns + `catalog_sync`);
    * the abbrev reservation in the global registry (append-only; the current mechanism);
    * the resource wired into its scope domain's `resources do … end`;
    * the FOUR mandated G26 test files (policy matrix + masked PII, RBAC admin-gate red,
      vault routing, catalog-parity red — thin `Samen.RedPath` macro calls) + a
      per-resource `anti_tautology_probe.exs`.

  Correct-by-construction: after `mix ecto.migrate`, the four emitted tests pass and the
  verifier gate stays green — no hand-edit.

  ## Usage

      mix samen.gen.resource --scope Crm --resource Widget --abbrev wdg [--app-dir /path]

  Options:

    * `--scope`    (required) — the target scope base name (must exist; run
      `mix samen.gen.scope --scope <Scope>` first).
    * `--resource` (required) — the resource base name, e.g. `Widget`
      (module `<App>.<Scope>.Widget`, table `<abbrev>_widget`).
    * `--abbrev`   (required) — the **3-letter lowercase** abbrev, reserved permanently.
    * `--app-dir`  (optional) — the existing app root. Defaults to the current directory.
    * `--no-reserve-abbrevs` — do NOT append the abbrev to the registry (used by the
      red-path probe to prove the compile-time gate catches a missing reservation).
  """

  use Mix.Task

  alias Samen.Gen.Post

  @switches [
    scope: :string,
    resource: :string,
    abbrev: :string,
    app_dir: :string,
    reserve_abbrevs: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, strict: @switches)

    scope = require_opt!(opts, :scope)
    resource = require_opt!(opts, :resource)
    abbrev = require_opt!(opts, :abbrev)
    app_dir = Keyword.get(opts, :app_dir) || File.cwd!()
    reserve? = Keyword.get(opts, :reserve_abbrevs, true)

    spec =
      Post.build_resource_spec(
        app_dir: app_dir,
        scope: scope,
        resource: resource,
        abbrev: abbrev
      )

    Post.validate_resource!(spec)

    if reserve?, do: Post.reserve_abbrevs!(spec)

    Post.write_resource!(spec)

    Mix.shell().info(
      "samen.gen.resource: wrote #{spec.resource_module} (table #{spec.table}), its migration, " <>
        "and the four G26 test files. Run `mix ecto.migrate && mix test` to gate it green."
    )

    :ok
  end

  defp require_opt!(opts, key) do
    case Keyword.get(opts, key) do
      nil -> Mix.raise("mix samen.gen.resource: missing required --#{key}")
      "" -> Mix.raise("mix samen.gen.resource: --#{key} may not be empty")
      val -> val
    end
  end
end
