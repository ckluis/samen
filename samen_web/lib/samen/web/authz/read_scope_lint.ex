defmodule Samen.Web.Authz.ReadScopeLint do
  @moduledoc """
  The five-tree sweep over the `authorize?: false` read-scope lint (T132, companion to T127;
  S15 widened it to the verticals).

  The scanner itself — the rule, the pin / sanction-marker granularity (R3/R4/R5) and the
  moduledoc that explains them — is `Samen.Lint.ReadScope` in `samen_core`, so any host or
  generated app can run it with `mix samen.verify.read_scope` (no `samen_web` needed). This
  module owns only the repo-wide configuration: WHICH trees the framework's own suite sweeps
  (`samen_core/lib`, `samen_web/lib`, `demo/lib`, `driftwood/lib`, `pawchart/lib`) and the
  seed / fixture harnesses it skips.
  """

  alias Samen.Lint.ReadScope
  alias Samen.Web.Authz.UnscopedReadError

  # Basenames skipped: seed / fixture harnesses whose authorize?: false reads run under
  # a system actor at setup, not a tenant request (no cross-tenant surface to leak), and this sweep
  # itself. The scanner (`Samen.Lint.ReadScope`) is swept like any other file: it holds no read call.
  @skip_basenames ~w(factory.ex red_path.ex read_scope_lint.ex)

  @doc """
  The `.ex` source files under lint: everything beneath `samen_core/lib`,
  `samen_web/lib`, AND the three vertical trees (`demo/lib`, `driftwood/lib`,
  `pawchart/lib` — the S15 sweep extension; a tree absent from the checkout, e.g. in
  a generated app, simply globs to `[]`), minus the seed/fixture harnesses. Anchored
  on THIS file's compile-time path so the glob resolves wherever the suite runs from.
  """
  def source_files do
    # __ENV__.file = .../samen_web/lib/samen/web/authz/read_scope_lint.ex — climb to the
    # samen_web app root, then one more to the repo root that holds all the app trees.
    samen_web_root = __ENV__.file |> Path.dirname() |> Path.join("../../../..") |> Path.expand()
    repo_root = Path.expand(Path.join(samen_web_root, ".."))

    # Samen.SourceScan, not Path.wildcard: five `**` walks through the node's single :file_server_2 queue behind every other
    # test's file I/O and outran ExUnit's 60 s on a loaded machine (the file reads here already bypass it).
    ~w(samen_core/lib samen_web/lib demo/lib driftwood/lib pawchart/lib)
    |> Enum.flat_map(&Samen.SourceScan.files(Path.join(repo_root, &1), [".ex"]))
    |> Enum.reject(fn f -> Path.basename(f) in @skip_basenames end)
    |> Enum.sort()
  end

  @doc "Scan one module's `source` — see `Samen.Lint.ReadScope.scan_source/2`."
  defdelegate scan_source(source, file), to: ReadScope

  @doc """
  Scan every file in `files` (default `source_files/0`). Returns
  `{:ok, %{files:, governed_reads:, sanctioned_reads:}}` when every
  `authorize?: false` read is pinned or sanctioned; raises `UnscopedReadError`
  listing every unpinned offender (and every file it could not inspect) otherwise — the
  LOUD gate failure T132 requires.
  """
  def assert_all_scoped!(files \\ source_files()) do
    case ReadScope.scan_files(files) do
      %{violations: [], errors: [], files: n, governed_reads: g, sanctioned_reads: s} ->
        {:ok, %{files: n, governed_reads: g, sanctioned_reads: s}}

      %{violations: violations, errors: errors} ->
        raise UnscopedReadError,
          message:
            ReadScope.remedy() <>
              "\n" <>
              Enum.join(
                Enum.map(violations, &("  * " <> ReadScope.format_violation(&1))) ++
                  Enum.map(errors, fn {file, why} -> "  * #{Path.relative_to_cwd(file)} — #{why}" end),
                "\n"
              )
    end
  end
end
