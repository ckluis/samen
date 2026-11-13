defmodule Samen.GenArgsTest do
  @moduledoc """
  DX-7 / AX-8 — the generators and the abbrev allocator refuse unknown or malformed flags BEFORE any side effect.
  A guessed `--dry-run` or a typo (`--modlues`) used to be silently dropped, so the task did a REAL run and
  permanently reserved abbrevs. Each case runs against a PRIVATE copy of the registry (the gen probes' guarded
  seam) and proves the registry is byte-identical and nothing was written.

  `async: false`: the registry override is process-global (see `Samen.AbbrevRegistryOverrideTest`).
  """
  use ExUnit.Case, async: false

  alias Samen.Gen.Args

  @env "SAMEN_ABBREV_REGISTRY"
  @guard "SAMEN_ABBREV_REGISTRY_GUARD"

  setup do
    priors = for var <- [@env, @guard], do: {var, System.get_env(var)}
    dir = Path.join(System.tmp_dir!(), "gen_args_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    registry = Path.join(dir, "registry.json")
    File.cp!(Samen.AbbrevRegistry.path(), registry)
    System.put_env(@guard, "gen_probe_guard")
    System.put_env(@env, registry)

    on_exit(fn ->
      for {var, prior} <- priors do
        if prior, do: System.put_env(var, prior), else: System.delete_env(var)
      end

      File.rm_rf(dir)
    end)

    {:ok, dir: dir, registry: registry, sha: sha(registry)}
  end

  defp sha(path), do: :crypto.hash(:sha256, File.read!(path))

  defp refused!(mod, argv, fragments) do
    err = assert_raise Mix.Error, fn -> mod.run(argv) end
    for f <- fragments, do: assert(err.message =~ f, "#{inspect(f)} not in: #{err.message}")
    err
  end

  test "parse!/3 returns the options for valid argv" do
    assert [module: "X", compile: false] =
             Args.parse!("t", ["--module", "X", "--no-compile"], module: :string, compile: :boolean)
  end

  test "parse!/3 names the unknown flag and lists the valid ones" do
    err = assert_raise Mix.Error, fn -> Args.parse!("t", ["--modlues", "files"], modules: :string, compile: :boolean) end
    assert err.message =~ "unknown flag --modlues"
    assert err.message =~ "--modules"
    assert err.message =~ "--compile/--no-compile"
  end

  test "parse!/3 refuses a flag missing its value, a bad integer, and positional arguments" do
    sw = [port: :integer, module: :string]
    assert_raise Mix.Error, ~r/--module needs a value/, fn -> Args.parse!("t", ["--module"], sw) end
    assert_raise Mix.Error, ~r/--port has an invalid value "abc"/, fn -> Args.parse!("t", ["--port", "abc"], sw) end
    assert_raise Mix.Error, ~r/unexpected positional argument "oops"/, fn -> Args.parse!("t", ["oops"], sw) end
  end

  test "gen.app: a typo'd flag is refused; nothing is generated and the registry is untouched", ctx do
    target = Path.join(ctx.dir, "out")

    refused!(
      Mix.Tasks.Samen.Gen.App,
      ~w(--module Harbor --prefix hb --abbrev hrb --modlues files --target #{target} --no-compile),
      ["unknown flag --modlues", "--modules", "Nothing was written"]
    )

    refute File.exists?(target)
    assert sha(ctx.registry) == ctx.sha
  end

  test "gen.app: a guessed --dry-run is refused rather than doing a real run", ctx do
    target = Path.join(ctx.dir, "out")

    refused!(
      Mix.Tasks.Samen.Gen.App,
      ~w(--module Harbor --prefix hb --abbrev hrb --dry-run --target #{target}),
      ["unknown flag --dry-run"]
    )

    refute File.exists?(target)
    assert sha(ctx.registry) == ctx.sha
  end

  test "gen.resource / gen.scope / gen.agent refuse unknown flags before writing", ctx do
    app = Path.join(ctx.dir, "app")
    File.mkdir_p!(app)

    refused!(
      Mix.Tasks.Samen.Gen.Resource,
      ~w(--scope Crm --resource Deal --abbrev dzz --app-dir #{app} --fields name:string),
      ["unknown flag --fields"]
    )

    refused!(Mix.Tasks.Samen.Gen.Scope, ~w(--scope Crm --app-dir #{app} --dry-run), ["unknown flag --dry-run"])
    refused!(Mix.Tasks.Samen.Gen.Agent, ~w(--scope Crm --name T --app-dir #{app} --tool x), ["unknown flag --tool"])

    assert File.ls!(app) == []
    assert sha(ctx.registry) == ctx.sha
  end

  test "abbrev.reserve: a guessed --dry-run does NOT reserve; the registry is byte-identical", ctx do
    refused!(
      Mix.Tasks.Samen.Abbrev.Reserve,
      ~w(--host zhost --abbrev zqz --owner Zhost.Thing --dry-run --registry #{ctx.registry}),
      ["unknown flag --dry-run", "--allow-cross-host-reuse"]
    )

    assert sha(ctx.registry) == ctx.sha
    refute File.read!(ctx.registry) =~ "zqz"
  end
end
