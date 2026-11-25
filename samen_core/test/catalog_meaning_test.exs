defmodule SamenCore.CatalogMeaningTest do
  @moduledoc """
  `mix samen.verify.catalog_meaning` (ADR-043 §8a, A2): the rules of `Samen.CatalogMeaning`, the baseline file of
  `Samen.CatalogMeaning.Baseline`, and the task's `--init` / `--shrink`. Most tests run the pure core on plain data
  shaped like what `introspect/1` returns; two read the sanctioned fixture resource. Every RED case pairs with a
  green control. Nothing is written outside a scratch dir under `System.tmp_dir!()`.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Mix.Tasks.Samen.Verify.CatalogMeaning, as: Task
  alias Samen.CatalogMeaning
  alias Samen.CatalogMeaning.Baseline
  alias SamenCore.Support.MeaningFixture

  # --- plain-data builders ----------------------------------------------------------------------------------------

  defp field(logical, opts \\ []) do
    %{
      logical_name: logical,
      label: Keyword.get(opts, :label, Samen.Catalog.Meaning.humanize(logical)),
      description: Keyword.get(opts, :description, "Legal or trading name of the company"),
      synonyms: Keyword.get(opts, :synonyms, []),
      authored_units: Keyword.get(opts, :authored_units),
      units_fixed?: Keyword.get(opts, :units_fixed?, false)
    }
  end

  defp table(name, opts \\ []) do
    label = Keyword.get(opts, :label, name |> String.split("_") |> List.last() |> String.capitalize())

    %{
      table_name: name,
      resource: "Fx.#{label}",
      label: label,
      module_label: Keyword.get(opts, :module_label, label),
      description: Keyword.get(opts, :description, "A fixture business record kept for testing the verifier."),
      synonyms: Keyword.get(opts, :synonyms, []),
      fields: Keyword.get(opts, :fields, [field("title")]),
      relationships: Keyword.get(opts, :relationships, [])
    }
  end

  defp baseline(entries), do: Baseline.render(entries)

  defp check(tables, baseline_src), do: CatalogMeaning.check(tables, [], baseline_src)

  # The Mix shell is global: restore it, or every later test that captures task output sees nothing.
  defp quiet_shell! do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.Quiet)
    on_exit(fn -> Mix.shell(previous) end)
  end

  defp scratch! do
    dir = Path.join(System.tmp_dir!(), "samen_catalog_meaning_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp violations_matching(violations, regex), do: Enum.filter(violations, &(&1 =~ regex))

  # --- R1/R2 + R6: undescribed vs the baseline --------------------------------------------------------------------

  describe "baseline exactness" do
    test "a table with every description present and no baseline is clean (green control)" do
      assert check([table("fx_deal")], nil) == []
    end

    test "RED: a new undescribed field not in the baseline is a violation" do
      tables = [table("fx_deal", fields: [field("title"), field("notes", description: nil)])]

      # green control: listed in the baseline, the same field is debt, not a violation
      assert check(tables, baseline(["fx_deal.notes"])) == []

      [message] = check(tables, baseline([]))
      assert message =~ "fx_deal.notes"
      assert message =~ "describe it — new tables and fields are described from day one; the baseline never grows"
    end

    test "an undescribed table is a violation unless listed, and names the table" do
      tables = [table("fx_deal", description: nil)]
      assert check(tables, baseline(["fx_deal"])) == []
      assert [message] = check(tables, baseline([]))
      assert message =~ "fx_deal"
    end

    test "RED: a described field left in the baseline must be shrunk" do
      tables = [table("fx_deal")]

      [message] = check(tables, baseline(["fx_deal.title"]))
      assert message =~ "fx_deal.title"
      assert message =~ "now described (or gone) — run mix samen.verify.catalog_meaning --shrink"

      # green control: once shrunk (the empty baseline), it is clean
      assert check(tables, baseline([])) == []
    end

    test "a baseline entry for a table that no longer exists is stale" do
      assert [first, second] = check([table("fx_deal")], baseline(["fx_gone", "fx_gone.x"]))
      assert first =~ "fx_gone:"
      assert second =~ "fx_gone.x:"
    end

    test "RED: a ceiling that is not the entry count is a violation" do
      tables = [table("fx_deal", fields: [field("notes", description: nil)])]
      good = baseline(["fx_deal.notes"])
      assert check(tables, good) == []

      assert [message] = check(tables, String.replace(good, "# ceiling: 1", "# ceiling: 5"))
      assert message =~ "ceiling is 5 but it lists 1"
    end

    test "RED: a missing ceiling header, a malformed or unsorted entry is a violation (fails closed)" do
      tables = [table("fx_deal", fields: [field("b", description: nil), field("a", description: nil)])]
      entries = ["fx_deal.a", "fx_deal.b"]
      assert check(tables, baseline(entries)) == []

      no_header = "fx_deal.a\nfx_deal.b\n"
      assert Enum.any?(check(tables, no_header), &(&1 =~ "ceiling: N"))

      unsorted = "# ceiling: 2\nfx_deal.b\nfx_deal.a\n"
      assert Enum.any?(check(tables, unsorted), &(&1 =~ "not sorted"))

      assert Enum.any?(check(tables, "# ceiling: 1\nFx Deal!\n"), &(&1 =~ "malformed entry"))
    end

    test "a renamed table cannot hide debt: its old entries are stale and its new ones are new" do
      before = [table("fx_deal", fields: [field("notes", description: nil)])]
      renamed = [table("fx_offer", fields: [field("notes", description: nil)])]
      listed = baseline(["fx_deal.notes"])

      assert check(before, listed) == []

      violations = check(renamed, listed)
      assert [_] = violations_matching(violations, ~r/fx_offer\.notes: undescribed/)
      assert [_] = violations_matching(violations, ~r/fx_deal\.notes: baseline entry is now described/)
    end

    test "with no baseline file the verifier is strict" do
      tables = [table("fx_deal", fields: [field("notes", description: nil)])]
      assert [message] = check(tables, nil)
      assert message =~ "fx_deal.notes"
    end
  end

  # --- R0 ---------------------------------------------------------------------------------------------------------

  describe "fail closed" do
    test "RED: zero discovered resources is a violation" do
      assert [message] = CatalogMeaning.check([], [], nil)
      assert message =~ "no resources discovered"

      # green control: one resource, no violation
      assert CatalogMeaning.check([table("fx_deal")], [], nil) == []
    end

    test "RED: a resource that cannot be introspected is a violation" do
      {result, log} = with_log(fn -> CatalogMeaning.introspect([Enum]) end)
      assert {[], [message]} = result
      # it is reported through Samen.Observability.Failure, not swallowed
      assert log =~ "read=catalog_meaning_introspect"
      assert message =~ "Enum"
      assert message =~ "could not be read"

      assert [_] = CatalogMeaning.check([table("fx_deal")], [message], nil)
      # not "no resources discovered": the unreadable resource is named instead
      refute Enum.any?(CatalogMeaning.check([], [message], nil), &(&1 =~ "no resources discovered"))
    end

    test "a readable resource introspects to plain data (green control)" do
      mod = MeaningFixture.described!()
      on_exit(&MeaningFixture.unload_described/0)

      assert {[info], []} = CatalogMeaning.introspect([mod])
      assert info.table_name == "piv_thing"
      assert info.description == "A fixture deal used to prove catalog meaning."
      assert info.synonyms == ["contract"]

      value = Enum.find(info.fields, &(&1.logical_name == "value"))
      assert value.synonyms == ["amount"]
      assert value.units_fixed?
      assert value.authored_units == nil

      assert "piv_thing.status" in CatalogMeaning.undescribed([info])
    end
  end

  # --- R3 ---------------------------------------------------------------------------------------------------------

  describe "description quality" do
    defp one(description, opts \\ []) do
      name = Keyword.get(opts, :name, "name")
      check([table("fx_company", fields: [field(name, description: description)])], nil)
    end

    test "RED: a description that restates the field name is refused" do
      assert [message] = one("The name of the name")
      assert message =~ "fx_company.name"
      assert message =~ "restates the name"

      # stopwords do not rescue a restatement
      assert [_ | _] = one("The name of this record is the name field value")

      # green controls
      assert one("Legal or trading name of the company") == []
      assert one("Name", name: "title") |> Enum.any?(&(&1 =~ "fewer than 3 words"))
    end

    test "RED: a non-printable description (NUL, invalid UTF-8) is ONE named problem, never an exception; newline and tab are fine" do
      for bad <- ["Legal name of the company\0 as filed", "Legal name of the \xff company as filed"] do
        assert Samen.CatalogMeaning.description_problems(bad, ["name"]) == ["contains a non-printable character or invalid UTF-8"]
        assert [message] = one(bad)
        assert message =~ "non-printable"
      end

      # green controls: printable whitespace is not refused, so no multi-line description in a host trips the rule
      assert one("Legal name of the company,\nas filed\twith the registry") == []
    end

    test "RED: a possessive or a stray letter is not a new word (\"The name's name\" restates `name`)" do
      for text <- ["The name's name", "The name\u2019s name", "The names' name", "Name's value of this record", "The name, i.e. the name e g"] do
        assert [message] = one(text), "#{inspect(text)} must be refused"
        assert message =~ "restates the name"
      end

      # green controls: a possessive of a REAL new word is still a new word; a contraction is not stripped
      assert one("The company's name") == []
      assert one("Legal or trading name of the company's group") == []
      assert one("Name that don't change") == []
    end

    test "a restatement of the LABEL is refused too" do
      tables = [table("fx_company", fields: [field("ref", label: "Customer number", description: "The customer number value")])]
      assert [message] = check(tables, nil)
      assert message =~ "restates"
    end

    test "RED: fewer than 3 words, TODO/TBD/FIXME, over 300 characters, untrimmed and vt_ are each refused" do
      assert Enum.any?(one("Company title"), &(&1 =~ "fewer than 3 words"))
      assert Enum.any?(one("Legal title of the company TODO"), &(&1 =~ "placeholder"))
      assert Enum.any?(one("tbd for the company title"), &(&1 =~ "placeholder"))
      assert Enum.any?(one("Fixme later the company title"), &(&1 =~ "placeholder"))
      assert Enum.any?(one(String.duplicate("company title words ", 20)), &(&1 =~ "longer than 300"))
      assert Enum.any?(one(" Legal title of the company "), &(&1 =~ "whitespace"))
      assert Enum.any?(one("A token like vt_abc names the company"), &(&1 =~ "vault-token sentinel"))

      # green controls: a word that merely contains todo, exactly 300 characters, exactly 3 words
      assert one("Legal title of the mastodon company") == []
      assert one(String.duplicate("abcd ", 59) <> "abcde") == []
      assert one("Legal company title") == []
    end

    test "a present table description is held to the same rules" do
      assert [message] = check([table("fx_company", description: "Company company company")], nil)
      assert message =~ "fx_company:"
      assert [_ | _] = check([table("fx_company", description: "TODO describe this company properly")], nil)
    end

    test "a relationship description is held to the rules; one that became its FK's description is checked once" do
      has_many = %{name: "notes", type: :has_many, source_attribute: "id", description: "TODO about the company"}
      assert [message] = check([table("fx_company", relationships: [has_many])], nil)
      assert message =~ "fx_company relationship notes"

      # the same text as the FK field's own description: reported once, on the field
      belongs = %{name: "owner", type: :belongs_to, source_attribute: "owner_id", description: "TODO about the owner"}
      fk = field("owner_id", description: "TODO about the owner")
      assert [message] = check([table("fx_company", relationships: [belongs], fields: [fk])], nil)
      assert message =~ "fx_company.owner_id"

      # green control
      good = %{has_many | description: "The notes people attached to the company"}
      assert check([table("fx_company", relationships: [good])], nil) == []
    end

    test "RED: a quality violation is not baselinable" do
      tables = [table("fx_company", fields: [field("name", description: "Name")])]

      # the file lists the field as debt: it is not undescribed, so it is stale AND the quality finding stands
      violations = check(tables, baseline(["fx_company.name"]))
      assert Enum.any?(violations, &(&1 =~ "fx_company.name: description only restates the name"))
      assert Enum.any?(violations, &(&1 =~ "baseline entry is now described"))

      # green control: described properly, the same listing is only stale
      good = [table("fx_company", fields: [field("name", description: "Legal or trading name of the company")])]
      assert [only] = check(good, baseline(["fx_company.name"]))
      assert only =~ "baseline entry is now described"
    end
  end

  # --- R4 ---------------------------------------------------------------------------------------------------------

  describe "synonyms" do
    test "RED: a synonym shared by two fields is refused" do
      fields = [field("amount", synonyms: ["cost"]), field("price", synonyms: ["Cost"])]
      violations = check([table("fx_deal", fields: fields)], nil)
      assert [_, _] = violations_matching(violations, ~r/declared more than once/)

      # across table and field synonyms too
      mixed = table("fx_deal", synonyms: ["cost"], fields: [field("amount", synonyms: ["COST"])])
      assert [_, _] = violations_matching(check([mixed], nil), ~r/declared more than once/)

      # green control: distinct synonyms
      ok = [field("amount", synonyms: ["cost"]), field("price", synonyms: ["rate"])]
      assert check([table("fx_deal", fields: ok)], nil) == []
    end

    test "RED: a synonym equal to another field's name or label is refused" do
      fields = [field("amount", synonyms: ["price"]), field("price"), field("close_date", label: "Closing day")]
      assert [message] = check([table("fx_deal", fields: fields)], nil)
      assert message =~ "fx_deal.amount"
      assert message =~ "another field"

      by_label = [field("amount", synonyms: ["closing day"]), field("close_date", label: "Closing day")]
      assert [_] = check([table("fx_deal", fields: by_label)], nil)

      by_underscored = [field("amount", synonyms: ["close date"]), field("close_date")]
      assert [_] = check([table("fx_deal", fields: by_underscored)], nil)

      # a table synonym equal to a field name is refused as well
      assert [_] = check([table("fx_deal", synonyms: ["price"], fields: [field("price")])], nil)

      # green control: a synonym equal to ITS OWN field's label is not "another field"
      assert check([table("fx_deal", fields: [field("amount", label: "Total", synonyms: ["total"])])], nil) == []
    end

    test "a synonym must be 1-40 characters" do
      long = String.duplicate("x", 41)
      assert [_] = check([table("fx_deal", fields: [field("amount", synonyms: [long])])], nil)
      assert [_] = check([table("fx_deal", fields: [field("amount", synonyms: ["  "])])], nil)
      assert check([table("fx_deal", fields: [field("amount", synonyms: [String.duplicate("x", 40)])])], nil) == []
    end

    test "RED: a table synonym that names another table is refused (cross-table)" do
      files = table("fx_file", label: "File")
      attachment = table("fx_attachment", label: "Attachment", synonyms: ["file"])

      violations = check([files, attachment], nil)
      assert [message] = violations
      assert message =~ "fx_attachment"
      assert message =~ "names another table (fx_file"

      # humanized resource name, table name and another table's synonym are all "names"
      relabelled = table("fx_file", label: "Document", module_label: "File")
      assert [_] = check([relabelled, attachment], nil)
      assert [_, _] = check([table("fx_file", label: "Document", module_label: "Document", synonyms: ["File"]), attachment], nil)
      assert [_] = check([table("fx_file", label: "Document", module_label: "Document"), table("x", synonyms: ["fx_file"])], nil)

      # green control: an attached-file synonym names nothing else; and a table never collides with itself
      assert check([files, table("fx_attachment", label: "Attachment", synonyms: ["attached file"])], nil) == []
      assert check([table("fx_file", label: "File", module_label: "File", synonyms: ["file"])], nil) == []
    end

    test "twin mounts are one concept: a table synonym does not collide with the twin (same label), still with any other label" do
      # Billing is mounted twice in a host: both mounts carry the blueprint's synonym, and share the label "Invoice".
      a = table("pbi_invoice", label: "Invoice", synonyms: ["bill"])
      b = table("pmi_invoice", label: "Invoice", synonyms: ["bill"])
      assert check([a, b], nil) == []

      # the twin's other names are the twin's: a synonym equal to the twin's humanized resource or table name is the same concept
      c = table("pmi_invoice", label: "Invoice", module_label: "Invoice", synonyms: ["pmi invoice"])
      assert check([table("pbi_invoice", label: "Invoice", synonyms: ["pmi invoice"]), c], nil) == []

      # control: a DIFFERENT-label table with that synonym (or with that name) is still refused, with a twin present
      bill = table("pbi_bill", label: "Bill")
      assert [_ | _] = check([a, b, bill], nil)
      other_syn = table("pbi_credit", label: "Credit note", synonyms: ["bill"])
      violations = check([a, b, other_syn], nil)
      assert [_, _, _, _] = violations_matching(violations, ~r/names another table/)
      assert Enum.any?(violations, &(&1 =~ "pbi_credit"))
    end

    test "twin mounts: a FIELD synonym does not collide with the twin's label or synonym, still with another table's" do
      twin = table("pmi_plan", label: "Plan", synonyms: ["tariff"], fields: [field("name", synonyms: ["plan"])])
      owner = table("pbi_plan", label: "Plan", synonyms: ["tariff"], fields: [field("name", synonyms: ["plan"])])
      assert check([twin, owner], nil) == []

      # a field synonym equal to the twin's table SYNONYM is the twin's too
      field_owner = table("pbi_plan", label: "Plan", fields: [field("name", synonyms: ["tariff"])])
      assert check([twin, field_owner], nil) == []

      # control: the same field synonyms against a different-label table are refused
      stranger = table("pbi_price", label: "Price", synonyms: ["rate"], fields: [field("amount")])
      by_label = table("pbi_plan", label: "Plan", fields: [field("name", synonyms: ["price"])])
      by_synonym = table("pbi_plan", label: "Plan", fields: [field("name", synonyms: ["rate"])])
      assert [_] = check([twin, stranger, by_label], nil)
      assert [_] = check([twin, stranger, by_synonym], nil)
    end

    test "RED: a field synonym that names another table's label or synonym is refused (cross-table)" do
      contact = table("cnt_contact", label: "Contact", synonyms: ["lead"])

      by_label = table("crm_person", fields: [field("name", synonyms: ["contact"])])
      assert [message] = check([contact, by_label], nil)
      assert message =~ "crm_person.name"
      assert message =~ "names another table (cnt_contact"

      by_synonym = table("crm_person", fields: [field("name", synonyms: ["lead"])])
      assert [_] = check([contact, by_synonym], nil)

      # green control: a field synonym that is only another table's bare table name is not held against it
      bare = table("crm_person", fields: [field("name", synonyms: ["cnt contact"])])
      assert check([contact, bare], nil) == []

      assert check([contact, table("crm_person", fields: [field("name", synonyms: ["full name"])])], nil) == []
    end
  end

  describe "twin mounts against the three real dicts" do
    @hosts ~w(demo driftwood pawchart)

    # table_info from a committed schema.dict.json (the dict has no module label: it is the resource's last segment)
    defp dict_tables(host) do
      path = Path.join([Samen.Lint.KernelSwallow.repo_root(), host, "schema.dict.json"])

      for t <- path |> File.read!() |> Jason.decode!() |> Map.fetch!("tables") do
        %{
          table_name: t["table_name"],
          resource: t["resource"],
          label: t["label"],
          module_label: t["resource"] |> String.split(".") |> List.last() |> Macro.underscore() |> Samen.Catalog.Meaning.humanize(),
          description: t["description"],
          synonyms: Map.get(t, "synonyms", []),
          fields:
            for f <- t["fields"] do
              %{logical_name: f["logical_name"], label: f["label"], description: f["description"], synonyms: Map.get(f, "synonyms", []), authored_units: nil, units_fixed?: false}
            end,
          relationships: []
        }
      end
    end

    defp synonym_violations(tables), do: tables |> check(nil) |> violations_matching(~r/synonym/)

    # A blueprint synonym lands on EVERY mount of the scope: give each twin group (same label) its own new synonym.
    defp with_hypothetical_synonyms(tables) do
      groups = tables |> Enum.group_by(& &1.label) |> Enum.filter(fn {_l, ts} -> length(ts) > 1 end)
      names = for {label, ts} <- groups, t <- ts, do: {t.table_name, "zz hypothetical #{label}"}
      by_table = Map.new(names)

      {Enum.map(tables, fn t ->
         case by_table[t.table_name] do
           nil -> t
           syn -> %{t | synonyms: [syn | t.synonyms]}
         end
       end), length(groups)}
    end

    test "a hypothetical synonym on a twin-mounted scope's tables (on BOTH mounts) is accepted in every host" do
      for host <- @hosts do
        tables = dict_tables(host)
        assert synonym_violations(tables) == [], "#{host}: the committed dict already breaks a synonym rule"

        {extended, groups} = with_hypothetical_synonyms(tables)
        assert groups > 0, "#{host}: no twin-mounted table found (the demonstration would be vacuous)"
        assert synonym_violations(extended) == [], "#{host}: a twin's synonym was refused"
      end
    end

    test "control: the same synonym on a table with a DIFFERENT label is refused, and so is `file` on the attachment" do
      for host <- @hosts do
        {extended, _} = host |> dict_tables() |> with_hypothetical_synonyms()
        twin = Enum.find(extended, &(&1.synonyms |> Enum.any?(fn s -> s =~ "zz hypothetical" end)))
        stranger = Enum.find(extended, &(&1.label != twin.label and &1.synonyms == []))

        clash = Enum.map(extended, &if(&1.table_name == stranger.table_name, do: %{&1 | synonyms: twin.synonyms}, else: &1))
        violations = synonym_violations(clash)
        assert Enum.any?(violations, &(&1 =~ "#{stranger.table_name}:")), "#{host}: #{stranger.table_name} was not refused"
        assert Enum.any?(violations, &(&1 =~ "#{twin.table_name}:")), "#{host}: #{twin.table_name} was not refused"

        # the Files-on-Attachment collision (different label) is still refused
        file_on_attachment =
          Enum.map(extended, fn t ->
            if t.table_name =~ ~r/attachment$/, do: %{t | synonyms: ["file" | t.synonyms]}, else: t
          end)

        assert [_ | _] = violations_matching(synonym_violations(file_on_attachment), ~r/attachment: synonym "file" names another table/)
      end
    end
  end

  # --- R5 ---------------------------------------------------------------------------------------------------------

  describe "units" do
    test "authored units over 40 characters, or on a type that fixes its own, are refused" do
      assert [_] = check([table("fx_deal", fields: [field("count", authored_units: String.duplicate("u", 41))])], nil)
      assert [_] = check([table("fx_deal", fields: [field("value", authored_units: "dollars", units_fixed?: true)])], nil)

      # green controls: 40 characters; fixed units with nothing authored
      assert check([table("fx_deal", fields: [field("count", authored_units: String.duplicate("u", 40))])], nil) == []
      assert check([table("fx_deal", fields: [field("value", units_fixed?: true)])], nil) == []
    end
  end

  # --- baseline file ----------------------------------------------------------------------------------------------

  describe "Baseline" do
    test "render writes the header, the ceiling and the sorted entries; parse reads them back" do
      src = Baseline.render(["b.z", "a", "b", "a"])
      assert src =~ ~r/\A# samen\.verify\.catalog_meaning baseline: .*Shrink-only; never add a line\.\n# ceiling: 3\na\nb\nb\.z\n\z/

      assert %{ceiling: 3, entries: ["a", "b", "b.z"], problems: []} = Baseline.parse(src)
    end

    test "RED: --shrink never adds an entry" do
      src = baseline(["fx_a.one", "fx_a.two", "fx_gone"])

      shrunk = Baseline.shrink(src, ["fx_a.two", "fx_new.field", "fx_new"])
      assert %{entries: ["fx_a.two"], ceiling: 1} = Baseline.parse(shrunk)

      # green control: nothing described since, nothing changes
      assert Baseline.shrink(src, ["fx_a.one", "fx_a.two", "fx_gone"]) == src
    end

    test "growth: a new entry or a higher ceiling against the merge base is refused" do
      base = baseline(["a", "b"])

      assert Baseline.growth(base, base) == []
      assert Baseline.growth(baseline(["a"]), base) == []
      assert Baseline.growth(baseline([]), base) == []

      assert [message] = Baseline.growth(baseline(["a", "b", "c"]), base) |> Enum.reject(&(&1 =~ "ceiling"))
      assert message =~ "c: not in the merge base"

      assert [message] = Baseline.growth(String.replace(base, "ceiling: 2", "ceiling: 9"), base)
      assert message =~ "ceiling rose: 2 -> 9"

      assert [message] = Baseline.growth("a\nb\n", base)
      assert message =~ "ceiling could not be read"
    end
  end

  # --- the task: --init, --shrink, verify -------------------------------------------------------------------------

  describe "mix samen.verify.catalog_meaning" do
    defp debt_tables, do: [table("fx_deal", fields: [field("title"), field("notes", description: nil)])]

    test "--init writes the baseline once and refuses an existing file" do
      path = Path.join(scratch!(), "catalog_meaning.baseline")

      quiet_shell!()
      assert :ok = Task.init(path, debt_tables(), [])
      assert File.read!(path) == baseline(["fx_deal.notes"])

      before = File.read!(path)
      assert_raise Mix.Error, ~r/already exists/, fn -> Task.init(path, [table("fx_other", description: nil)], []) end
      assert File.read!(path) == before
    end

    test "--init and --shrink refuse an unsound discovery (nothing found, or a resource unreadable)" do
      dir = scratch!()
      assert_raise Mix.Error, ~r/no resources were discovered/, fn -> Task.init(Path.join(dir, "a"), [], []) end
      assert_raise Mix.Error, ~r/could not be read/, fn -> Task.init(Path.join(dir, "b"), debt_tables(), ["Fx.X: could not be read"]) end
      refute File.exists?(Path.join(dir, "a"))
      refute File.exists?(Path.join(dir, "b"))

      path = Path.join(dir, "c")
      File.write!(path, baseline(["fx_deal.notes", "fx_other.x"]))
      # the unreadable resource would look "gone" and shrink its debt away: refused
      assert_raise Mix.Error, ~r/--shrink refused/, fn -> Task.shrink(path, debt_tables(), ["Fx.Other: could not be read"]) end
      assert File.read!(path) == baseline(["fx_deal.notes", "fx_other.x"])
    end

    test "--shrink rewrites file ∩ undescribed, lowers the ceiling and never adds" do
      path = Path.join(scratch!(), "catalog_meaning.baseline")
      File.write!(path, baseline(["fx_deal.notes", "fx_deal.title", "fx_gone"]))

      # fx_deal.notes still undescribed; fx_deal.title is described now; fx_gone is gone; a NEW undescribed field is not added
      tables = [table("fx_deal", fields: [field("title"), field("notes", description: nil), field("extra", description: nil)])]
      quiet_shell!()
      assert :ok = Task.shrink(path, tables, [])

      assert File.read!(path) == baseline(["fx_deal.notes"])
      assert %{ceiling: 1} = Baseline.parse(File.read!(path))

      # and the new undescribed field is still a violation: shrinking never absorbs it
      assert {[message], 2} = Task.verify(path, tables, [])
      assert message =~ "fx_deal.extra"
    end

    test "run/1 refuses bad arguments before doing any work" do
      assert_raise Mix.Error, ~r/--init and --shrink are exclusive/, fn -> Task.run(["--init", "--shrink"]) end
      assert_raise Mix.Error, ~r/unexpected argument/, fn -> Task.run(["stray"]) end
      assert_raise OptionParser.ParseError, fn -> Task.run(["--bogus"]) end
    end

    test "RED: --domain with --init or --shrink is refused (a partial discovery would shrink other domains' entries away)" do
      assert_raise Mix.Error, ~r/--domain cannot be combined with --init or --shrink/, fn -> Task.run(["--init", "--domain", "Fx.Domain"]) end
      assert_raise Mix.Error, ~r/--domain cannot be combined with --init or --shrink/, fn -> Task.run(["--shrink", "--domain", "Fx.Domain"]) end
    end

    test "--shrink without a file raises (the strict end state has nothing to shrink)" do
      path = Path.join(scratch!(), "missing.baseline")
      assert_raise Mix.Error, ~r/nothing to shrink/, fn -> Task.shrink(path, debt_tables(), []) end
    end

    test "the end state: a `# ceiling: 0` file with no entries is clean when nothing is undescribed, strict otherwise" do
      path = Path.join(scratch!(), "catalog_meaning.baseline")
      File.write!(path, baseline([]))

      assert {[], 0} = Task.verify(path, [table("fx_deal")], [])

      # RED: an empty file grandfathers nothing, so a new undescribed field is still a violation
      assert {[message], 1} = Task.verify(path, debt_tables(), [])
      assert message =~ "fx_deal.notes"
      assert message =~ "describe it"

      # and --shrink on the empty file keeps it empty (no crash, no entry added)
      quiet_shell!()
      assert :ok = Task.shrink(path, debt_tables(), [])
      assert File.read!(path) == baseline([])
    end

    test "verify reads the baseline file; an absent file is strict, a matching one is clean" do
      path = Path.join(scratch!(), "catalog_meaning.baseline")

      assert {[message], 1} = Task.verify(path, debt_tables(), [])
      assert message =~ "fx_deal.notes"

      File.write!(path, baseline(["fx_deal.notes"]))
      assert {[], 1} = Task.verify(path, debt_tables(), [])
    end
  end
end
