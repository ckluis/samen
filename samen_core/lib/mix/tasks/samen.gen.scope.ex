defmodule Mix.Tasks.Samen.Gen.Scope do
  @shortdoc "Scaffold a new authored scope (Ash domain) into an existing Samen app."

  @moduledoc """
  `mix samen.gen.scope` — the POST-APP scope generator (WS-D D7a; AC-G4-7). Adds a new
  authored **scope** (an `Ash.Domain` namespace the vertical author owns) to an app that
  already exists (one scaffolded by `mix samen.gen.app`). The scope starts EMPTY;
  `mix samen.gen.resource --scope <Scope> …` lands Tier-0 resources into it.

  Automates the scope half of scope-authoring §10: emits the domain module and registers
  it in BOTH `:ash_domains` config lists (the app's own + `:samen_core`) so the verifier
  gate scans every resource mounted there — no hand-edit of config.

  ## Usage

      mix samen.gen.scope --scope Crm [--app-dir /path/to/app]

  Options:

    * `--scope`   (required) — the scope base name, e.g. `Crm` (module `<App>.Crm`).
    * `--app-dir` (optional) — the existing app root. Defaults to the current directory.
  """

  use Mix.Task

  alias Samen.Gen.Post

  @switches [scope: :string, app_dir: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, strict: @switches)

    scope =
      case Keyword.get(opts, :scope) do
        nil -> Mix.raise("mix samen.gen.scope: missing required --scope")
        "" -> Mix.raise("mix samen.gen.scope: --scope may not be empty")
        val -> val
      end

    app_dir = Keyword.get(opts, :app_dir) || File.cwd!()

    spec = Post.build_scope_spec(app_dir: app_dir, scope: scope)

    Post.validate_scope!(spec)
    Post.write_scope!(spec)

    Mix.shell().info(
      "samen.gen.scope: wrote #{spec.scope_module} + registered it in both :ash_domains lists " <>
        "+ emitted the authn-coverage guard test/tenant_authn_coverage_test.exs. " <>
        "Add resources with `mix samen.gen.resource --scope #{scope} --resource <Name> --abbrev <abc>`.\n\n" <>
        Post.scope_router_guidance(spec)
    )

    :ok
  end
end
