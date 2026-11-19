defmodule Mix.Tasks.Samen.Verify.ReadScope do
  @shortdoc "Fail build on any `authorize?: false` read that bypasses org scoping."

  @moduledoc """
  `mix samen.verify.read_scope` — the read-scope lint (T132/S15, `Samen.Lint.ReadScope`) as a
  verifier any host or generated app runs on its OWN `lib/` tree.

  Tenant isolation is Ash policy (`Samen.Policy.OrgScope`); `authorize?: false` turns that
  policy off. A direct `Ash.read!`/`read`/`stream!`/… with `authorize?: false` and NO
  `org_id`/`id` narrowing returns EVERY org's rows. This task fails the build on one. A read
  passes when it is a by-id lookup, a scalar aggregate, carries a genuine `org_id`/`id`
  `filter`/`for_read`, or carries a `# authz-scope: <why-safe>` marker naming why a deliberately
  org-less read (a system sweep, a pre-auth credential lookup, a webhook ref lookup) is safe.
  The pin / marker is bound to exactly ONE read; the full rule is in `Samen.Lint.ReadScope`.

  ## Usage

      mix samen.verify.read_scope
      mix samen.verify.read_scope --source-dirs lib --source-dirs apps/x/lib
      mix samen.verify.read_scope --max-sanctioned 0

  `--max-sanctioned N` is a CEILING on the `# authz-scope:` reads: more than N fails, so a new
  marker is a conscious change to the number (the reference hosts pin their exact count; a
  generated app starts at 0).

  ## Exit code (fail-closed)

  Exits 0 only when every file was inspected and every governed read is pinned or sanctioned,
  1 otherwise (via `Samen.Verifier`, `:erlang.halt/1`). It FAILS — never passes — on a
  source dir that does not exist, a dir with no `.ex` file (nothing was inspected), and a file
  that cannot be read or parsed.
  """
  use Mix.Task

  alias Samen.Lint.ReadScope

  @task_name "samen.verify.read_scope"

  @impl Mix.Task
  def run(args) do
    {opts, _rest} =
      OptionParser.parse!(args, strict: [source_dirs: [:string, :keep], max_sanctioned: :integer])

    dirs =
      case Keyword.get_values(opts, :source_dirs) do
        [] -> ["lib"]
        dirs -> dirs
      end

    result = scan(dirs, Keyword.get(opts, :max_sanctioned))

    if result.unscoped > 0, do: IO.puts("\n" <> ReadScope.remedy())

    if result.violations == [] do
      IO.puts(
        "#{@task_name}: scanned #{result.files} file(s): #{result.governed_reads} authorize?: false " <>
          "read(s), #{result.sanctioned_reads} sanctioned by # authz-scope:"
      )
    end

    Samen.Verifier.halt_if_violations(@task_name, result.violations)
  end

  @doc """
  Scan `dirs` and return `%{violations: [String.t()], unscoped:, files:, governed_reads:, sanctioned_reads:}`
  (`unscoped` counts the unpinned reads among the violations).
  Separated from `run/1` so tests can call it without `:erlang.halt/1`. `max_sanctioned` is
  the optional ceiling on sanctioned reads.
  """
  @spec scan([Path.t()], non_neg_integer() | nil) :: map()
  def scan(dirs, max_sanctioned \\ nil) do
    {files, dir_violations} =
      Enum.reduce(dirs, {[], []}, fn dir, {files, viol} ->
        found = if File.dir?(dir), do: Samen.SourceScan.files(dir, [".ex"]), else: []

        cond do
          not File.dir?(dir) ->
            {files, viol ++ ["#{dir}: source dir does not exist — nothing was inspected"]}

          found == [] ->
            {files, viol ++ ["#{dir}: no .ex file found — nothing was inspected"]}

          true ->
            {files ++ found, viol}
        end
      end)

    scanned = ReadScope.scan_files(files)

    ceiling =
      case max_sanctioned do
        n when is_integer(n) and scanned.sanctioned_reads > n ->
          [
            "#{scanned.sanctioned_reads} reads carry a `# authz-scope:` marker, over the ceiling of #{n} " <>
              "(--max-sanctioned): a new sanction is a conscious change to that number"
          ]

        _ ->
          []
      end

    violations =
      dir_violations ++
        Enum.map(scanned.violations, &ReadScope.format_violation/1) ++
        Enum.map(scanned.errors, fn {file, why} -> "#{Path.relative_to_cwd(file)} — #{why}" end) ++
        ceiling

    %{scanned | violations: violations} |> Map.put(:unscoped, length(scanned.violations))
  end
end
