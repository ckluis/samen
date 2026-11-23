defmodule Samen.CatalogMeaning do
  @moduledoc """
  The rules behind `mix samen.verify.catalog_meaning` (ADR-043 §8a): every catalogued table and field has a
  description of real quality, and the debt that exists today is an exact, shrink-only baseline.

  Pure core. `introspect/1` reads each resource through the domains' own resources (NOT `Samen.AI.Catalog.dict/1`,
  which drops a failing table by design: a verifier must fail closed on it) into plain data; `check/3` applies the
  rules to that data and a baseline file's text:

    * **R0 fail closed**: zero resources discovered is a violation; a resource whose meaning cannot be read is a
      violation naming it (reported through `Samen.Observability.Failure`).
    * **R1/R2**: every catalogued table and field has a description (after the reader's derivations: a relationship
      describes its FK, the framework describes its injected fields).
    * **R3 quality**, for every PRESENT description: trimmed, at least 3 words, at most 300 characters, no
      `TODO`/`TBD`/`FIXME`, no `vt_` (`Samen.AI.VtSentinel`), and not a restatement of the name (after dropping
      stopwords it must hold a word that is in neither the logical name nor the label).
    * **R4 synonyms**: 1-40 characters; unique within a resource, case-insensitively, across table and field
      synonyms; never equal to another field's logical name or label. Across tables of one app: a TABLE synonym may
      not equal another table's label, humanized resource name, table name or synonym; a FIELD synonym may not equal
      another table's label or synonym ("file" on an attachment must not name the Files table). A table with the
      SAME label (the twin mount of a scope a host mounts twice) is exempt: twins are one concept.
    * **R5 units**: at most 40 characters, and none authored where the type fixes its own. (The `meaning`
      transformer refuses both at compile time; this re-checks the catalogue so a host that bypassed the DSL is
      still caught.)
    * **R6 baseline exactness**: the set of undescribed entries must EQUAL the baseline's, and its ceiling must equal
      its entry count. A new undescribed entry is always a violation; a described entry still listed is a violation
      until `--shrink` removes it. With no baseline file the check is strict (a brand-new app before adoption); the end state of
      an adopted host is its file kept at `# ceiling: 0`, never deleted (`Baseline.ratchet/3`).

  Only "undescribed" is debt. A quality violation is never baselinable, whatever the file lists.
  """

  alias Samen.AI.VtSentinel
  alias Samen.Catalog.Meaning
  alias Samen.CatalogMeaning.Baseline

  @min_words 3
  @max_description 300
  @max_synonym 40
  @max_units 40

  @stopwords ~w(the a an of this that these those record records field fields value values for to and or is are it its in on by with as be at from)

  @type field_info :: %{
          logical_name: String.t(),
          label: String.t(),
          description: String.t() | nil,
          synonyms: [String.t()],
          authored_units: String.t() | nil,
          units_fixed?: boolean()
        }
  @type relationship_info :: %{
          name: String.t(),
          type: atom() | String.t(),
          source_attribute: String.t() | nil,
          description: String.t() | nil
        }
  @type table_info :: %{
          table_name: String.t(),
          resource: String.t(),
          label: String.t(),
          module_label: String.t(),
          description: String.t() | nil,
          synonyms: [String.t()],
          fields: [field_info()],
          relationships: [relationship_info()]
        }

  @type finding :: %{kind: :undescribed | :quality, key: String.t(), message: String.t()}

  @new_message "describe it — new tables and fields are described from day one; the baseline never grows"
  @stale_message "now described (or gone) — run mix samen.verify.catalog_meaning --shrink"

  # --- introspection ----------------------------------------------------------------------------------------------

  @doc """
  Read every resource into plain data. Returns `{tables, errors}`: a resource whose meaning cannot be read is an
  error string naming it (and reported through `Samen.Observability.Failure`), never skipped.
  """
  @spec introspect([module()]) :: {[table_info()], [String.t()]}
  def introspect(resources) when is_list(resources) do
    {oks, errors} =
      resources
      |> Enum.uniq()
      |> Enum.map(&introspect_one/1)
      |> Enum.split_with(&match?({:ok, _}, &1))

    {Enum.map(oks, fn {:ok, info} -> info end), Enum.map(errors, fn {:error, message} -> message end)}
  end

  defp introspect_one(resource) do
    {:ok, read(resource)}
  rescue
    e ->
      Samen.Observability.Failure.report(:catalog_meaning_introspect, nil, e)

      {:error,
       "#{inspect(resource)}: its meaning could not be read (#{Exception.message(e)}) — " <>
         "a resource the verifier cannot read is never skipped"}
  end

  defp read(resource) do
    tam = Samen.Catalog.table(resource)
    table = Meaning.table(resource)
    meanings = Meaning.fields(resource)
    types = Map.new(Ash.Resource.Info.attributes(resource), &{to_string(&1.name), &1.type})
    authored = Map.new(Spark.Dsl.Extension.get_entities(resource, [:meaning]), &{to_string(&1.name), &1.units})
    rel_descriptions = Meaning.relationship_descriptions(resource)

    %{
      table_name: tam.table_name,
      resource: tam.resource,
      label: table.label,
      module_label: module_label(resource),
      description: table.description,
      synonyms: table.synonyms,
      fields:
        for f <- Samen.Catalog.fields(resource) do
          meaning = Map.fetch!(meanings, f.logical_name)

          %{
            logical_name: f.logical_name,
            label: meaning.label,
            description: meaning.description,
            synonyms: meaning.synonyms,
            authored_units: Map.get(authored, f.logical_name),
            units_fixed?: Meaning.fixes_units?(Map.get(types, f.logical_name))
          }
        end,
      relationships:
        for r <- Samen.Catalog.relationships(resource) do
          %{
            name: r.name,
            type: r.type,
            source_attribute: r.source_attribute,
            description: Map.get(rel_descriptions, r.name)
          }
        end
    }
  end

  defp module_label(resource), do: resource |> Module.split() |> List.last() |> Macro.underscore() |> Meaning.humanize()

  # --- the debt ---------------------------------------------------------------------------------------------------

  @doc "Every undescribed entry (`table_name`, `table_name.logical_name`), sorted and unique: what the baseline must list."
  @spec undescribed([table_info()]) :: [String.t()]
  def undescribed(tables) do
    tables |> undescribed_findings() |> Enum.map(& &1.key) |> Enum.uniq() |> Enum.sort()
  end

  defp undescribed_findings(tables) do
    Enum.flat_map(tables, fn t ->
      table = if is_nil(t.description), do: [undescribed_finding(t.table_name)], else: []
      fields = for f <- t.fields, is_nil(f.description), do: undescribed_finding("#{t.table_name}.#{f.logical_name}")
      table ++ fields
    end)
  end

  defp undescribed_finding(key), do: %{kind: :undescribed, key: key, message: "#{key}: undescribed — #{@new_message}"}

  # --- the check --------------------------------------------------------------------------------------------------

  @doc """
  Every violation, as a string naming the table and field. `tables`/`errors` come from `introspect/1`;
  `baseline_src` is the baseline file's text, or `nil` when the host has none (strict).
  """
  @spec check([table_info()], [String.t()], String.t() | nil) :: [String.t()]
  def check(tables, errors, baseline_src) do
    discovery =
      if tables == [] and errors == [] do
        ["no resources discovered — nothing was verified (check the domains / `config :ash, :domains`)"]
      else
        []
      end

    findings = undescribed_findings(tables) ++ quality_findings(tables)

    discovery ++ errors ++ baseline_violations(findings, undescribed(tables), baseline_src)
  end

  defp baseline_violations(findings, _undescribed, nil), do: Enum.map(findings, & &1.message)

  defp baseline_violations(findings, undescribed, baseline_src) do
    baseline = Baseline.parse(baseline_src)
    listed = MapSet.new(baseline.entries)
    current = MapSet.new(undescribed)

    # Only "undescribed" is debt: a quality finding is reported whatever the file lists.
    reported = Enum.reject(findings, &(&1.kind == :undescribed and MapSet.member?(listed, &1.key)))

    stale = for e <- Enum.sort(listed), not MapSet.member?(current, e), do: "#{e}: baseline entry is #{@stale_message}"

    ceiling =
      cond do
        is_nil(baseline.ceiling) -> []
        baseline.ceiling == length(baseline.entries) -> []
        true -> ["baseline ceiling is #{baseline.ceiling} but it lists #{length(baseline.entries)} entries — they must be equal"]
      end

    Enum.map(baseline.problems, &"#{Baseline.file_name()}: #{&1}") ++
      Enum.map(reported, & &1.message) ++ stale ++ ceiling
  end

  # --- quality (R3, R4, R5) ---------------------------------------------------------------------------------------

  defp quality_findings(tables) do
    Enum.flat_map(tables, &table_quality/1) ++ cross_table_synonyms(tables)
  end

  defp table_quality(t) do
    table_words = words([t.label, t.module_label, t.table_name])

    table_desc = description_findings(t.table_name, t.description, table_words)

    field_desc =
      Enum.flat_map(t.fields, fn f ->
        description_findings("#{t.table_name}.#{f.logical_name}", f.description, words([f.logical_name, f.label]))
      end)

    rel_desc =
      for r <- t.relationships,
          not derived_fk_description?(t, r),
          finding <- description_findings("#{t.table_name} relationship #{r.name}", r.description, words([r.name])),
          do: finding

    table_desc ++ field_desc ++ rel_desc ++ synonym_findings(t) ++ units_findings(t)
  end

  # A belongs_to description that already became its FK field's description was checked there.
  defp derived_fk_description?(t, %{type: type, source_attribute: source, description: description}) do
    to_string(type) == "belongs_to" and
      Enum.any?(t.fields, &(&1.logical_name == source and &1.description == description))
  end

  defp description_findings(_key, nil, _name_words), do: []

  defp description_findings(key, description, name_words) do
    tokens = tokens(description)

    problems =
      [
        {description != String.trim(description), "has leading or trailing whitespace"},
        {length(String.split(description)) < @min_words, "has fewer than #{@min_words} words"},
        {String.length(description) > @max_description, "is longer than #{@max_description} characters"},
        {Regex.match?(~r/\b(todo|tbd|fixme)\b/i, description), "is a placeholder (TODO/TBD/FIXME)"},
        {VtSentinel.in_string?(description), "contains the vault-token sentinel `#{VtSentinel.sentinel()}`"},
        {restates?(tokens, name_words), "only restates the name — say what it IS or does, in words the name does not hold"}
      ]

    for {true, problem} <- problems,
        do: finding(:quality, key, "description #{problem} (#{inspect(description)})")
  end

  @doc false
  @spec restates?([String.t()], MapSet.t(String.t())) :: boolean()
  def restates?(tokens, name_words) do
    content = Enum.reject(tokens, &(&1 in @stopwords))
    content == [] or Enum.all?(content, &MapSet.member?(name_words, stem(&1)))
  end

  defp finding(kind, key, message), do: %{kind: kind, key: key, message: "#{key}: #{message}"}

  defp tokens(text), do: ~r/[[:alnum:]]+/u |> Regex.scan(String.downcase(text)) |> List.flatten()

  # Name words are stemmed (a trailing "s" dropped); the description's words are stemmed at comparison.
  defp words(names), do: names |> Enum.flat_map(&tokens/1) |> MapSet.new(&stem/1)

  defp stem(word), do: String.trim_trailing(word, "s")

  defp norm(text), do: text |> String.trim() |> String.downcase() |> String.replace("_", " ")

  # R4, within one resource.
  defp synonym_findings(t) do
    owned =
      Enum.map(t.synonyms, &{&1, nil, t.table_name}) ++
        for f <- t.fields, s <- f.synonyms, do: {s, f, "#{t.table_name}.#{f.logical_name}"}

    shape =
      for {s, _f, key} <- owned, String.trim(s) == "" or String.length(s) > @max_synonym do
        finding(:quality, key, "synonym #{inspect(s)} must be 1-#{@max_synonym} characters")
      end

    duplicates =
      owned
      |> Enum.group_by(fn {s, _, _} -> norm(s) end)
      |> Enum.filter(fn {n, group} -> n != "" and length(group) > 1 end)
      |> Enum.flat_map(fn {n, group} ->
        for {_s, _f, key} <- group,
            do: finding(:quality, key, "synonym #{inspect(n)} is declared more than once in #{inspect(t.resource)}")
      end)

    collisions =
      for {s, owner, key} <- owned,
          other <- t.fields,
          other != owner,
          norm(s) in [norm(other.logical_name), norm(other.label)] do
        finding(:quality, key, "synonym #{inspect(s)} is the name or label of another field (#{other.logical_name})")
      end

    shape ++ duplicates ++ collisions
  end

  # R4, across the tables of one app.
  defp cross_table_synonyms(tables) do
    # normalized name -> [{table_name, :name | :synonym}]
    index =
      Enum.reduce(tables, %{}, fn t, acc ->
        names = Enum.map([t.label, t.module_label, t.table_name], &{norm(&1), :name})
        synonyms = Enum.map(t.synonyms, &{norm(&1), :synonym})

        Enum.reduce(Enum.uniq(names ++ synonyms), acc, fn {n, via}, acc ->
          Map.update(acc, n, [{t.table_name, via, t.label}], &[{t.table_name, via, t.label} | &1])
        end)
      end)

    Enum.flat_map(tables, fn t ->
      table_side =
        for s <- t.synonyms,
            {other, _via, label} <- Map.get(index, norm(s), []),
            other != t.table_name,
            not twin?(t, label),
            do: finding(:quality, t.table_name, "synonym #{inspect(s)} names another table (#{other}, #{inspect(label)})")

      field_side =
        for f <- t.fields,
            s <- f.synonyms,
            {other, via, label} <- Map.get(index, norm(s), []),
            other != t.table_name,
            not twin?(t, label),
            # a FIELD synonym may not equal another table's label or synonym (its bare table name is not a word a
            # person would use for a column, so it is not held against it)
            via == :synonym or norm(s) == norm(label),
            do:
              finding(
                :quality,
                "#{t.table_name}.#{f.logical_name}",
                "synonym #{inspect(s)} names another table (#{other}, #{inspect(label)})"
              )

      table_side ++ field_side
    end)
  end

  # A scope mounted twice in a host (Billing, Support) gives every table a twin with the SAME label, and a blueprint
  # synonym lands on both mounts. Twins are one concept: the label they share is already (equally) ambiguous, so
  # their names and synonyms never collide with each other. A table with a DIFFERENT label still collides.
  defp twin?(t, other_label), do: norm(other_label) == norm(t.label)

  # R5.
  defp units_findings(t) do
    for f <- t.fields,
        units = f.authored_units,
        problem <- units_problems(f, units),
        do: finding(:quality, "#{t.table_name}.#{f.logical_name}", problem)
  end

  defp units_problems(field, units) do
    [
      {String.length(units) > @max_units, "units #{inspect(units)} are longer than #{@max_units} characters"},
      {field.units_fixed?, "units #{inspect(units)} are authored on a type that fixes its own units"}
    ]
    |> Enum.filter(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end
end
