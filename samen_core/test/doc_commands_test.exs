defmodule Samen.Gen.DocCommandsTest do
  @moduledoc """
  WS-D D9 — the DOC-COMMAND EXTRACTOR gate (AC-G10-1 / AC-G10-2).

  Binds the root `README.md` and `docs/guides/getting-started.md` to reality: every
  fenced command in them must be in the CI probes' executed set (the flagship probe +
  the post-app generator probe, both permanent steps of the root `ci.sh`), be cheaply
  executed here directly, or carry an explicit `# operator-TODO` marker.

  Fail-closed in BOTH directions:
    * an aspirational command added to either doc → this suite fails (the red path);
    * a probe edited to stop executing what a doc claims → this suite fails (drift).

  Anti-vacuity: the extraction itself is asserted non-trivial (exact minimum command
  counts + the load-bearing command shapes present), so a silently-broken extractor
  cannot green-wash the docs. The red paths below prove the extractor's failure modes
  actually fire.

  Cheap direct execution ("or runs them directly where cheap"): the tutorial's example
  generator inputs are run through the REAL fail-closed validation
  (`Samen.Gen.App.validate_against!/2` against the committed registry, read-only) and
  every `mix samen.*` task named in a doc command must resolve to a real task module —
  so the example values are runnable, not placeholders.
  """
  use ExUnit.Case, async: true

  alias Samen.AbbrevRegistry
  alias Samen.Gen.App, as: Gen
  alias Samen.Gen.DocCommands

  @core_root Path.expand("..", __DIR__)
  @repo_root Path.expand("../..", __DIR__)

  @doc_paths [
    {"README.md", Path.join(@repo_root, "README.md")},
    {"docs/guides/getting-started.md", Path.join(@repo_root, "docs/guides/getting-started.md")},
    {"docs/guides/cookbook.md", Path.join(@repo_root, "docs/guides/cookbook.md")},
    {"docs/guides/gate-failures.md", Path.join(@repo_root, "docs/guides/gate-failures.md")}
  ]

  # The sources that EXECUTE the documented commands (see DocCommands.rules/0).
  @source_paths %{
    flagship_probe: Path.join(@core_root, "priv/gen_app_flagship_probe.exs"),
    post_probe: Path.join(@core_root, "priv/gen_post_probe.exs"),
    gen_app_task: Path.join(@core_root, "lib/mix/tasks/samen.gen.app.ex"),
    gen_engine: Path.join(@core_root, "lib/samen/gen/app.ex"),
    templates: Path.join(@core_root, "lib/samen/gen/templates.ex")
  }

  defp docs, do: for({name, path} <- @doc_paths, do: {name, File.read!(path)})

  defp sources,
    do: Map.new(@source_paths, fn {key, path} -> {key, File.read!(path)} end)

  defp extracted do
    Enum.flat_map(docs(), fn {name, md} -> DocCommands.extract(name, md) end)
  end

  # ------------------------------------------------------------------ the green gate

  test "AC-G10-1/2: every fenced command in README + getting-started is in the probes' executed set" do
    case DocCommands.verify(docs(), sources()) do
      :ok ->
        :ok

      {:error, failures} ->
        flunk(
          "doc-command extractor found #{length(failures)} aspirational/drifted " <>
            "command(s):\n  " <> Enum.join(failures, "\n  ")
        )
    end
  end

  test "anti-vacuity: the extractor actually extracted the load-bearing command set" do
    commands = extracted()
    by_doc = Enum.group_by(commands, & &1.doc)

    # Exact floors — if the fence format or the extractor regresses and extraction
    # silently returns little/nothing, verify/2 would pass vacuously. This stops that.
    assert length(Map.fetch!(by_doc, "README.md")) >= 8
    assert length(Map.fetch!(by_doc, "docs/guides/getting-started.md")) >= 15
    # D9b: the cookbook's recipes + the gate-failure index's fix commands.
    assert length(Map.fetch!(by_doc, "docs/guides/cookbook.md")) >= 7
    assert length(Map.fetch!(by_doc, "docs/guides/gate-failures.md")) >= 2

    has? = fn pred -> Enum.any?(commands, fn c -> pred.(c.argv) end) end

    assert has?.(&match?(["mix", "samen.gen.app" | _], &1)), "gen.app command not extracted"
    assert has?.(&match?(["mix", "samen.gen.scope" | _], &1)), "gen.scope command not extracted"
    assert has?.(&match?(["mix", "samen.gen.resource" | _], &1)), "gen.resource not extracted"
    assert has?.(&(&1 == ["bash", "ci.sh"])), "bash ci.sh not extracted"
    assert has?.(&(&1 == ["mix", "harbor.seed"])), "mix harbor.seed not extracted"
    assert has?.(&(&1 == ["mix", "phx.server"])), "mix phx.server not extracted"

    # `&&` chains split + env prefixes captured (the ecto.create && ecto.migrate line).
    create = Enum.find(commands, &(&1.argv == ["mix", "ecto.create"]))
    assert %{env: ["MIX_ENV=dev"]} = create
    assert has?.(&(&1 == ["mix", "ecto.migrate"]))
  end

  # ------------------------------------------------------------------ red paths

  test "RED PATH: an aspirational command added to the tutorial FAILS the extractor" do
    doc = """
    # tutorial

    ```bash
    mix samen.deploy.magic --to prod
    ```
    """

    assert {:error, [failure]} = DocCommands.verify([{"tutorial.md", doc}], sources())
    assert failure =~ "mix samen.deploy.magic --to prod"
    assert failure =~ "aspirational"
    assert failure =~ "tutorial.md:4"
  end

  test "RED PATH: an aspirational FLAG on a real command fails (no rule matches it)" do
    doc = """
    ```bash
    mix samen.gen.app --module Harbor --prefix hb --abbrev hrb --deploy fly
    ```
    """

    assert {:error, [failure]} = DocCommands.verify([{"t.md", doc}], sources())
    assert failure =~ "--deploy"
    assert failure =~ "aspirational"
  end

  test "RED PATH: a probe that stops executing a documented command fails the docs (drift)" do
    doc = """
    ```bash
    MIX_ENV=test bash ci.sh
    ```
    """

    drifted =
      Map.update!(sources(), :flagship_probe, fn src ->
        String.replace(src, ~s|System.cmd("bash", ["ci.sh"]|, ~s|System.cmd("bash", ["no.sh"]|)
      end)

    assert {:error, failures} = DocCommands.verify([{"t.md", doc}], drifted)
    assert Enum.any?(failures, &(&1 =~ "GONE from :flagship_probe"))

    # Positive control: the same doc against the REAL sources is green.
    assert :ok = DocCommands.verify([{"t.md", doc}], sources())
  end

  test "operator-TODO marker: an explicitly-human command is allowed; unmarked it fails" do
    marked = """
    ```bash
    fly deploy # operator-TODO: needs the operator's real Fly account (ADR-024)
    ```
    """

    unmarked = """
    ```bash
    fly deploy
    ```
    """

    block_marked = """
    ```bash operator-todo
    fly deploy
    ```
    """

    assert :ok = DocCommands.verify([{"t.md", marked}], sources())
    assert :ok = DocCommands.verify([{"t.md", block_marked}], sources())
    assert {:error, [failure]} = DocCommands.verify([{"t.md", unmarked}], sources())
    assert failure =~ "fly deploy"
  end

  # ------------------------------------------------------------------ cheap direct runs

  test "the tutorial's gen.app example values pass the REAL fail-closed validation" do
    # Run the front half of the documented command for real: build the spec from the
    # tutorial's exact flag values and validate it against the COMMITTED registry
    # (read-only — Gen.validate_against!/2 is the pure core of Gen.validate!/1).
    flags = doc_flag_values("docs/guides/getting-started.md", "samen.gen.app")

    spec =
      Gen.build_spec(
        module: Map.fetch!(flags, "--module"),
        prefix: Map.fetch!(flags, "--prefix"),
        abbrev: Map.fetch!(flags, "--abbrev"),
        target: System.tmp_dir!()
      )

    assert :ok = Gen.validate_against!(spec, AbbrevRegistry.load())
  end

  test "the tutorial's gen.resource example abbrev is well-formed and honestly reservable" do
    flags = doc_flag_values("docs/guides/getting-started.md", "samen.gen.resource")
    abbrev = Map.fetch!(flags, "--abbrev")

    assert Regex.match?(AbbrevRegistry.pattern(), abbrev)

    # Unowned (or already owned by the tutorial's own module — idempotent example):
    # anything else means the tutorial tells the reader to run a command that fails.
    case Map.get(AbbrevRegistry.load(), abbrev) do
      nil -> :ok
      "Harbor." <> _ -> :ok
      other -> flunk("tutorial example abbrev #{inspect(abbrev)} is owned by #{other}")
    end
  end

  test "every documented `mix samen.*` command resolves to a real, loadable Mix task" do
    tasks =
      extracted()
      |> Enum.map(& &1.argv)
      |> Enum.filter(&match?(["mix", "samen." <> _ | _], &1))
      |> Enum.map(&Enum.at(&1, 1))
      |> Enum.uniq()

    assert tasks != [], "no samen.* tasks extracted from the docs"

    for task <- tasks do
      assert Mix.Task.get(task), "doc names `mix #{task}`, but no such Mix task exists"
    end
  end

  # Pull the --flag values off the FIRST doc command for the given samen task.
  defp doc_flag_values(doc_name, task) do
    cmd =
      Enum.find(extracted(), fn c ->
        c.doc == doc_name and match?(["mix", ^task | _], c.argv)
      end)

    assert cmd, "#{doc_name} has no `mix #{task}` command"

    cmd.argv
    |> Enum.drop(2)
    |> Enum.chunk_every(2)
    |> Map.new(fn [flag, value] -> {flag, value} end)
  end
end
