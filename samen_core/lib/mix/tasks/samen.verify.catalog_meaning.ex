defmodule Mix.Tasks.Samen.Verify.CatalogMeaning do
  @shortdoc "Fail build on an undescribed or low-quality catalog table/field (shrink-only baseline)."

  @moduledoc """
  `mix samen.verify.catalog_meaning` — every catalogued table and field has a description of real quality
  (ADR-043 §8a, `Samen.CatalogMeaning`), and the debt that exists today is an exact, shrink-only baseline.

  It reads the resources of the host's domains (the same resolver as `mix samen.catalog.dump`) and needs NO database:
  it reads compile-time metadata only. The rules (R0-R6) are in `Samen.CatalogMeaning`: fail closed on zero resources
  or an unreadable one; every table and field described; quality for every present description (trimmed, at least 3
  words, at most 300 characters, no TODO/TBD/FIXME, no `vt_`, not a restatement of the name); synonym rules
  (including across tables); units; and baseline exactness.

  ## The baseline

  `catalog_meaning.baseline` in the host's root (override: `--baseline <path>`) lists the table and field entries
  that are undescribed today (`table_name`, `table_name.logical_name`), under a `# ceiling: N` header equal to the
  entry count. The undescribed set must EQUAL the file:

    * an undescribed entry the file does not list is a violation: new tables and fields are described from day one;
    * a listed entry that is now described is a violation until `--shrink` removes it;
    * a quality violation is never baselinable.

  With NO file the check is strict (a brand-new app before adoption). A host that has paid all its debt KEEPS its file
  at `# ceiling: 0` with no entries and never deletes it: the ratchet test refuses a baseline that is absent at a merge
  base which already has this verifier (a deleted file, re-initialised, would hide new debt).

  ## Usage

      mix samen.verify.catalog_meaning             # verify (exit 1 on any violation)
      mix samen.verify.catalog_meaning --init      # write the baseline once (refuses when the file exists)
      mix samen.verify.catalog_meaning --shrink    # rewrite it as file ∩ still-undescribed; lowers the ceiling
      mix samen.verify.catalog_meaning --domain MyApp.Crm --baseline path/to/catalog_meaning.baseline

  `--init` and `--shrink` refuse to run while a resource is unreadable or none is found (an unreadable resource would
  otherwise look "gone" and shrink its debt away). `--shrink` never adds an entry. The list can only shrink: a test in
  samen_core compares every host's baseline with the merge base's.
  """
  use Mix.Task

  alias Samen.CatalogMeaning
  alias Samen.CatalogMeaning.Baseline

  @task_name "samen.verify.catalog_meaning"

  @impl Mix.Task
  def run(args) do
    {opts, rest} =
      OptionParser.parse!(args,
        strict: [init: :boolean, shrink: :boolean, baseline: :string, domain: [:string, :keep]]
      )

    if rest != [], do: Mix.raise("#{@task_name}: unexpected argument(s) #{inspect(rest)}")
    if opts[:init] && opts[:shrink], do: Mix.raise("#{@task_name}: --init and --shrink are exclusive")

    path = Keyword.get(opts, :baseline, Baseline.file_name())

    Mix.Task.run("compile")

    {tables, errors} = introspect(Keyword.get_values(opts, :domain))

    cond do
      opts[:init] -> init(path, tables, errors)
      opts[:shrink] -> shrink(path, tables, errors)
      true -> :ok
    end

    {violations, count} = verify(path, tables, errors)

    if violations == [] do
      IO.puts("#{@task_name}: #{length(tables)} table(s), #{count} undescribed entr#{if count == 1, do: "y", else: "ies"} (baseline: #{baseline_note(path)})")
    end

    Samen.Verifier.halt_if_violations(@task_name, violations)
  end

  @doc """
  The whole verification of `path` (the baseline file; absent = strict) over already-introspected `tables`/`errors`:
  `{violations, undescribed_count}`. Separated from `run/1` so tests can call it without `:erlang.halt/1`.
  """
  @spec verify(Path.t(), [CatalogMeaning.table_info()], [String.t()]) :: {[String.t()], non_neg_integer()}
  def verify(path, tables, errors) do
    baseline_src = if File.exists?(path), do: File.read!(path)
    {CatalogMeaning.check(tables, errors, baseline_src), length(CatalogMeaning.undescribed(tables))}
  end

  @doc "`--init`: write the baseline of everything undescribed now. Raises when the file exists or discovery is unsound."
  @spec init(Path.t(), [CatalogMeaning.table_info()], [String.t()]) :: :ok
  def init(path, tables, errors) do
    refuse_unsound!("--init", tables, errors)

    if File.exists?(path) do
      Mix.raise("#{@task_name}: #{path} already exists — --init writes it once. Use --shrink to lower it.")
    end

    File.write!(path, Baseline.render(CatalogMeaning.undescribed(tables)))
    Mix.shell().info("#{@task_name}: wrote #{path} (#{length(CatalogMeaning.undescribed(tables))} entries)")
  end

  @doc "`--shrink`: rewrite the file as its intersection with what is still undescribed. Raises when there is no file."
  @spec shrink(Path.t(), [CatalogMeaning.table_info()], [String.t()]) :: :ok
  def shrink(path, tables, errors) do
    refuse_unsound!("--shrink", tables, errors)

    unless File.exists?(path), do: Mix.raise("#{@task_name}: #{path} does not exist — nothing to shrink (--init writes it)")

    File.write!(path, Baseline.shrink(File.read!(path), CatalogMeaning.undescribed(tables)))
    Mix.shell().info("#{@task_name}: shrank #{path}")
  end

  defp refuse_unsound!(flag, tables, errors) do
    if errors != [] or tables == [] do
      Mix.raise(
        "#{@task_name}: #{flag} refused — " <>
          if(errors == [], do: "no resources were discovered", else: Enum.join(errors, "; "))
      )
    end
  end

  defp introspect(domain_args) do
    domains =
      case Samen.Catalog.Domains.resolve(domain_args, Mix.Project.config()[:app]) do
        {:ok, domains} -> domains
        {:error, message} -> Mix.raise(message)
      end

    if domains == [] do
      Mix.raise(
        "#{@task_name}: no domains found. Configure :ash, :domains in your app config, " <>
          "or pass --domain MyApp.SomeDomain."
      )
    end

    domains |> Samen.Catalog.resource_modules() |> CatalogMeaning.introspect()
  end

  defp baseline_note(path), do: if(File.exists?(path), do: path, else: "none, strict")
end
