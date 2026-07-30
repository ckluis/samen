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
    * `--live` — ALSO scaffold index / show / form LiveViews for the resource on the
      `Samen.UI` kit (a builder gets visible CRUD screens, not just a headless data
      layer). The four `live/3` routes are wired into the generated app's router; the
      🔒 vault field resolves per plane through `Samen.Api.PiiResolution` (never
      hand-masked). Requires a `--web` app (the surfaces mount on samen_web's kit).
    * `--field-type` (optional) — the ONE scalar `pii do` vault field's LOGICAL type
      (ADR-036 §3 H7; T15). One of `Samen.Gen.FieldTypeMenu.menu/0`:
      `string | money | percent | score | duration | priority | url | email | phone |
      address`. Defaults to `"string"` — byte-identical to pre-T15 output. Every menu
      entry still materializes as a `Samen.Type.VaultField` `vt_*` token column
      (`pii_attribute` always vault-routes regardless of its declared logical type) —
      only the resource's declared type + the four generated G26 test files' sample
      values change per entry.
    * `--archivable` (optional, ADR-040 §5.8, T37h) — emit the resource with
      `archivable: true` on its `use Samen.Resource` call, so it gets the FULL E6
      soft-delete substrate (`archived_at`, `:archive`/`:restore`/`:archived`
      actions, the default-read exclusion) with ZERO hand-edits: the migration also
      emits the `<abbrev>_archived_at` column. Defaults to `false` — byte-identical
      to pre-T37h output when omitted. With `--live`, the generated index LiveView
      also gains a restore action + an archived-filter toggle (§5.8's UI clause,
      inherited by any `--live --archivable` resource — never per-vertical hand-wiring).
  """

  use Mix.Task

  alias Samen.Gen.Post

  @switches [
    scope: :string,
    resource: :string,
    abbrev: :string,
    app_dir: :string,
    reserve_abbrevs: :boolean,
    live: :boolean,
    field_type: :string,
    archivable: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, strict: @switches)

    scope = require_opt!(opts, :scope)
    resource = require_opt!(opts, :resource)
    abbrev = require_opt!(opts, :abbrev)
    app_dir = Keyword.get(opts, :app_dir) || File.cwd!()
    reserve? = Keyword.get(opts, :reserve_abbrevs, true)
    live? = Keyword.get(opts, :live, false)
    field_type = Keyword.get(opts, :field_type, "string")
    archivable? = Keyword.get(opts, :archivable, false)

    spec =
      Post.build_resource_spec(
        app_dir: app_dir,
        scope: scope,
        resource: resource,
        abbrev: abbrev,
        live: live?,
        field_type: field_type,
        archivable: archivable?
      )

    Post.validate_resource!(spec)

    if reserve?, do: Post.reserve_abbrevs!(spec)

    Post.write_resource!(spec)

    live_note =
      if live? do
        " + index/show/form LiveViews (Samen.UI) wired into the router"
      else
        ""
      end

    Mix.shell().info(
      "samen.gen.resource: wrote #{spec.resource_module} (table #{spec.table}), its migration, " <>
        "and the four G26 test files#{live_note}. Run `mix ecto.migrate && mix test` to gate it green."
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
