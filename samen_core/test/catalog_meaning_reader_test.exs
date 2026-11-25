defmodule SamenCore.CatalogMeaningReaderTest do
  @moduledoc """
  ADR-043 §8a — `Samen.Catalog.Meaning` reads descriptions, label, synonyms, units and derived facts, and the
  `Samen.Catalog.Transformers.MeaningDeclarations` compile-time transformer refuses bad meaning text.
  """
  use ExUnit.Case, async: false

  alias Samen.Catalog.Meaning

  alias SamenCore.Support.MeaningFixture

  # Fixtures are compiled by `MeaningFixture` under abbrev owners the registry already holds (it is permanent and
  # hands-off); every compile purges first and the module is purged on exit.
  defp compile!(name, body, _abbrev) do
    mod = MeaningFixture.compile!(body, if(name == "Full", do: :full, else: :scratch))
    on_exit(fn -> MeaningFixture.purge(mod) end)
    mod
  end

  defp purge(mod), do: MeaningFixture.purge(mod)

  @full """
  resource do
    description "A fixture thing used to prove catalog meaning."
  end

  meaning do
    label "Fixture widget"
    synonyms ["gadget"]
    field :cost, label: "Unit cost", synonyms: ["price"]
    field :qty, units: "pieces"
  end

  pii do
    vault :pii_name
    pii_attribute :full_name, Samen.Type.FullName, vault: :pii_name, description: "The person's full name, vault-routed."
  end

  attributes do
    attribute :name, :string, public?: true, constraints: [max_length: 40], description: "Short name as entered by a user."
    attribute :blank, :string, public?: true, description: ""
    attribute :status, :atom, public?: true, constraints: [one_of: [:open, :won, :lost]], description: "Overall state of the thing."
    attribute :free, :atom, public?: true
    attribute :cost, Samen.Type.Money, public?: true
    attribute :rate, Samen.Type.Percent, public?: true
    attribute :span, Samen.Type.Duration, public?: true
    attribute :qty, :integer, public?: true
    attribute :close_date, :date, public?: true
    attribute :custom, :map, public?: true
  end

  relationships do
    belongs_to :company, SamenCore.Support.Crm.Company do
      public? true
      description "The company this thing belongs to."
    end

    belongs_to :other, SamenCore.Support.Crm.Company do
      public? true
      attribute_public? true
    end
  end
  """

  setup_all do
    {:ok, mod: compile!("Full", @full, "mfa")}
  end

  describe "Samen.Catalog.Meaning readers" do
    test "native description is read for the resource and an attribute", %{mod: mod} do
      assert Meaning.table(mod).description == "A fixture thing used to prove catalog meaning."
      assert Meaning.fields(mod)["name"].description == "Short name as entered by a user."
    end

    test "an empty paper-trail description counts as missing", %{mod: mod} do
      assert Meaning.fields(mod)["blank"].description == nil
      assert Meaning.blank_to_nil("") == nil
      assert Meaning.blank_to_nil("  ") == nil
      assert Meaning.blank_to_nil("x") == "x"
    end

    test "a belongs_to source attribute is described by its relationship", %{mod: mod} do
      f = Meaning.fields(mod)
      assert f["company_id"].description == "The company this thing belongs to."
      # control: a belongs_to without a description stays missing
      assert f["other_id"].description == nil
      assert Meaning.relationship_descriptions(mod)["company"] == "The company this thing belongs to."
      assert Meaning.relationship_descriptions(mod)["other"] == nil
    end

    test "framework fields are described once by their transformers", %{mod: mod} do
      f = Meaning.fields(mod)

      for key <- ~w(id org_id inserted_at updated_at archived_at custom) do
        assert is_binary(f[key].description), "#{key} has no framework description"
      end
    end

    test "allowed_values are derived from one_of constraints, in declared order", %{mod: mod} do
      f = Meaning.fields(mod)
      assert f["status"].allowed_values == ["open", "won", "lost"]
      assert f["free"].allowed_values == nil
    end

    test "max_length is derived from the constraint", %{mod: mod} do
      f = Meaning.fields(mod)
      assert f["name"].max_length == 40
      assert f["qty"].max_length == nil
    end

    test "Money units are type-derived; Percent and Duration too", %{mod: mod} do
      f = Meaning.fields(mod)
      assert f["cost"].units == "money: amount with per-value ISO 4217 currency"
      assert f["rate"].units == "percent points (0-100)"
      assert f["span"].units == "seconds"
      # control: authored units reach a plain field
      assert f["qty"].units == "pieces"
      assert f["name"].units == nil
    end

    test "labels: humanized by default, overridden by the meaning section", %{mod: mod} do
      f = Meaning.fields(mod)
      assert f["close_date"].label == "Close date"
      assert f["cost"].label == "Unit cost"
      assert f["cost"].synonyms == ["price"]
      assert Meaning.table(mod).label == "Fixture widget"
      assert Meaning.table(mod).synonyms == ["gadget"]
    end

    test "table label falls back to the humanized module name" do
      mod = compile!("PlainThing", "attributes do\n attribute :a, :string, public?: true\nend", "mfb")
      assert Meaning.table(mod).label == "Unclassified non pii"
      assert Meaning.table(mod).description == nil
      assert Meaning.table(mod).synonyms == []
    end

    test "pii_attribute description reaches the materialized attribute", %{mod: mod} do
      attr = Ash.Resource.Info.attribute(mod, :full_name)
      assert attr.description == "The person's full name, vault-routed."
      assert Meaning.fields(mod)["full_name"].description ==
               "The person's full name, vault-routed."
    end

    test "an Ash.Type.Enum yields its values" do
      src = """
      defmodule SamenCore.MeaningFx.Color do
        use Ash.Type.Enum, values: [:red, :green]
      end
      """

      Code.compile_string(src)
      on_exit(fn -> purge(SamenCore.MeaningFx.Color) end)

      mod =
        compile!("EnumThing", "attributes do\n attribute :color, SamenCore.MeaningFx.Color, public?: true\nend", "mfc")

      assert Meaning.fields(mod)["color"].allowed_values == ["red", "green"]
    end
  end

  describe "compile-time verifier" do
    defp body(attr_extra, meaning \\ "") do
      """
      #{meaning}
      attributes do
        attribute :name, :string, public?: true#{attr_extra}
        attribute :cost, Samen.Type.Money, public?: true
      end
      """
    end

    test "RED: meaning field naming a non-attribute fails compile" do
      err =
        assert_raise Spark.Error.DslError, fn ->
          compile!("BadField", body("", "meaning do\n field :nope, label: \"Nope\"\n end"), "mfd")
        end

      assert Exception.message(err) =~ ":nope"
    end

    test "control: meaning field naming a real attribute compiles" do
      compile!("GoodField", body("", "meaning do\n field :name, label: \"Name\"\n end"), "mfd")
    end

    test "RED: vt_ in an attribute description fails compile" do
      assert_raise Spark.Error.DslError, ~r/vt_/, fn ->
        compile!("VtAttr", body(", description: \"Holds a vt_ token for the person.\""), "mfe")
      end
    end

    test "control: a description without the sentinel compiles" do
      compile!("NoVtAttr", body(", description: \"Holds a vault reference for the person.\""), "mfe")
    end

    test "RED: vt_ in a synonym, a resource description, a relationship description and a pii description fail" do
      assert_raise Spark.Error.DslError, ~r/vt_/, fn ->
        compile!("VtSyn", body("", "meaning do\n field :name, synonyms: [\"a vt_b\"]\n end"), "mff")
      end

      assert_raise Spark.Error.DslError, ~r/vt_/, fn ->
        compile!("VtRes", body("", "resource do\n description \"About vt_ things.\"\n end"), "mff")
      end

      assert_raise Spark.Error.DslError, ~r/vt_/, fn ->
        compile!(
          "VtRel",
          "attributes do\n attribute :a, :string, public?: true\nend\nrelationships do\n belongs_to :company, SamenCore.Support.Crm.Company do\n description \"has vt_x\"\n end\nend",
          "mff"
        )
      end

      assert_raise Spark.Error.DslError, ~r/vt_/, fn ->
        compile!(
          "VtPii",
          "pii do\n vault :pii_name\n pii_attribute :full_name, Samen.Type.FullName, vault: :pii_name, description: \"a vt_ token\"\n end",
          "mff"
        )
      end
    end

    test "RED: vt_ in a one_of allowed value fails compile, naming the resource, facet and attribute" do
      err =
        assert_raise Spark.Error.DslError, fn ->
          compile!(
            "VtOneOf",
            "attributes do\n attribute :risk, :atom, public?: true, constraints: [one_of: [:none, :dvt_risk]]\n end",
            "mfh"
          )
        end

      msg = Exception.message(err)
      assert msg =~ "vt_"
      assert msg =~ "UnclassifiedNonPii"
      assert msg =~ "allowed_values"
      assert msg =~ "risk"
    end

    test "control: a one_of without the sentinel compiles and is readable" do
      mod =
        compile!(
          "NoVtOneOf",
          "attributes do\n attribute :risk, :atom, public?: true, constraints: [one_of: [:none, :low]]\n end",
          "mfh"
        )

      assert Meaning.fields(mod)["risk"].allowed_values == ["none", "low"]
    end

    test "RED: vt_ in an Ash.Type.Enum value fails compile; the same enum without it compiles" do
      Code.compile_string("""
      defmodule SamenCore.MeaningFx.VtEnum do
        use Ash.Type.Enum, values: [:calm, :svt_storm]
      end

      defmodule SamenCore.MeaningFx.OkEnum do
        use Ash.Type.Enum, values: [:calm, :storm]
      end
      """)

      on_exit(fn ->
        purge(SamenCore.MeaningFx.VtEnum)
        purge(SamenCore.MeaningFx.OkEnum)
      end)

      assert_raise Spark.Error.DslError, ~r/allowed_values/, fn ->
        compile!("VtEnumThing", "attributes do\n attribute :weather, SamenCore.MeaningFx.VtEnum, public?: true\n end", "mfh")
      end

      compile!("OkEnumThing", "attributes do\n attribute :weather, SamenCore.MeaningFx.OkEnum, public?: true\n end", "mfh")
    end

    test "RED: vt_ in a meaning label or a unit string names the facet" do
      assert_raise Spark.Error.DslError, ~r/label/, fn ->
        compile!("VtLabel", body("", "meaning do\n field :name, label: \"A vt_ label\"\n end"), "mfh")
      end

      assert_raise Spark.Error.DslError, ~r/units/, fn ->
        compile!("VtUnits", body("", "meaning do\n field :name, units: \"vt_pieces\"\n end"), "mfh")
      end
    end

    test "RED: a vt_ in a table label fails compile" do
      assert_raise Spark.Error.DslError, ~r/label/, fn ->
        compile!("VtTableLabel", body("", "meaning do\n label \"A vt_ thing\"\n end"), "mfh")
      end
    end

    test "the sentinel check is the chokepoint's own predicate" do
      assert Samen.AI.VtSentinel.in_string?("a vt_b")
      refute Samen.AI.VtSentinel.in_string?("a vault b")
      assert {:error, :pii_egress_refused} = Samen.AI.Chokepoint.seal(:mcp, [], meta: %{payload: %{"x" => "a vt_b"}})
      assert {:ok, _} = Samen.AI.Chokepoint.seal(:mcp, [], meta: %{payload: %{"x" => "a vault b"}})
    end

    test "the leaf walk reaches map keys, nested values and list elements (positive control)" do
      leaves = Samen.AI.VtSentinel.leaves(%{"a" => ["x", %{"vt_key" => "y"}], "b" => 1})
      assert {["a", "vt_key"], "vt_key"} in leaves
      assert {["a", "vt_key"], "y"} in leaves
      assert Enum.count(leaves, fn {_, t} -> Samen.AI.VtSentinel.in_string?(t) end) == 1
    end

    test "RED: a meaning field entry listed twice for one attribute fails compile" do
      err =
        assert_raise Spark.Error.DslError, fn ->
          compile!("DupField", body("", "meaning do\n field :name, label: \"A\"\n field :name, label: \"B\"\n end"), "mfi")
        end

      assert Exception.message(err) =~ "more than once"
    end

    test "a whitespace-only description counts as missing; a real one still reads" do
      mod =
        compile!(
          "Blanks",
          "attributes do\n attribute :a, :string, public?: true, description: \"   \\n \"\n attribute :b, :string, public?: true, description: \"Real.\"\n end",
          "mfi"
        )

      assert Meaning.fields(mod)["a"].description == nil
      assert Meaning.fields(mod)["b"].description == "Real."
    end

    test "RED: an array of a unit-fixing type reports the type's units and refuses authored ones" do
      src = "attributes do\n attribute :amounts, {:array, Samen.Type.Money}, public?: true\n end"
      mod = compile!("ArrUnits", src, "mfk")
      assert Meaning.fields(mod)["amounts"].units == "money: amount with per-value ISO 4217 currency"

      assert_raise Spark.Error.DslError, ~r/fixes its own units/, fn ->
        compile!("ArrUnitsBad", src <> "\nmeaning do\n field :amounts, units: \"dollars\"\n end", "mfk")
      end
    end

    test "RED: authored units on a Money field fail compile" do
      assert_raise Spark.Error.DslError, ~r/fixes its own units/, fn ->
        compile!("UnitsMoney", body("", "meaning do\n field :cost, units: \"dollars\"\n end"), "mfg")
      end
    end

    test "control: authored units on a plain field compile; over-long units fail" do
      compile!("UnitsOk", "attributes do\n attribute :qty, :integer, public?: true\nend\nmeaning do\n field :qty, units: \"pieces\"\n end", "mfg")

      assert_raise Spark.Error.DslError, ~r/longer than 40/, fn ->
        compile!(
          "UnitsLong",
          "attributes do\n attribute :qty, :integer, public?: true\nend\nmeaning do\n field :qty, units: \"#{String.duplicate("x", 41)}\"\n end",
          "mfg"
        )
      end
    end
  end

  describe "compile-time transformer ordering (attributes the framework or Ash generates)" do
    defp order_body(extra_meaning) do
      """
      meaning do
        #{extra_meaning}
      end

      attributes do
        attribute :custom, :map, public?: true
      end

      relationships do
        belongs_to :company, SamenCore.Support.Crm.Company do
          public? true
          description "The company this thing belongs to."
        end
      end
      """
    end

    test "control: meaning fields on the generated FK, org_id, archived_at and custom are accepted and read back" do
      mod =
        compile!(
          "OrderOk",
          order_body("""
          field :company_id, label: "Company"
          field :org_id, label: "Organization"
          field :archived_at, label: "Archived on"
          field :custom, label: "Extra fields"
          """),
          "mfj"
        )

      f = Meaning.fields(mod)
      assert f["company_id"].label == "Company"
      assert f["org_id"].label == "Organization"
      assert f["archived_at"].label == "Archived on"
      assert f["custom"].label == "Extra fields"
    end

    test "RED: a name that is not an attribute is still refused beside the generated ones" do
      assert_raise Spark.Error.DslError, ~r/:nope/, fn ->
        compile!("OrderNope", order_body("field :company_id, label: \"Company\"\nfield :nope, label: \"Nope\""), "mfj")
      end
    end

    test "RED: vt_ in a belongs_to description is refused when the FK attribute is generated" do
      assert_raise Spark.Error.DslError, ~r/vt_/, fn ->
        compile!(
          "OrderVt",
          """
          relationships do
            belongs_to :company, SamenCore.Support.Crm.Company do
              public? true
              description "holds vt_x"
            end
          end
          """,
          "mfj"
        )
      end
    end

    test "the transformer is declared to run after every transformer that adds or describes attributes" do
      t = Samen.Catalog.Transformers.MeaningDeclarations

      for dep <- [
            Ash.Resource.Transformers.BelongsToAttribute,
            Samen.Transformers.CoreAttributes,
            Samen.Transformers.ArchivableAttribute,
            Samen.Transformers.MaterializeCustomFields,
            Samen.Transformers.MaterializePii,
            Samen.Transformers.AbbrevStorage
          ] do
        assert t.after?(dep), "MeaningDeclarations must run after #{inspect(dep)}"
        refute t.before?(dep)
      end

      # control: it is not declared after an unrelated module
      refute t.after?(Samen.Transformers.NoPanColumns)
    end
  end
end
