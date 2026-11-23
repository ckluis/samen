defmodule SamenCore.CatalogMeaningReaderTest do
  @moduledoc """
  ADR-043 §8a — `Samen.Catalog.Meaning` reads descriptions, label, synonyms, units and derived facts, and the
  `Samen.Catalog.Verifiers.MeaningDeclarations` compile-time verifier refuses bad meaning text.
  """
  use ExUnit.Case, async: false

  alias Samen.Catalog.Meaning

  # The abbrev registry is permanent and hands-off, so a fixture cannot invent an abbrev. These two owner
  # names are already registered to compile-string-only fixtures (`pii_red_path_test.exs` compiles and purges them
  # the same way); every fixture here is compiled under one of them and purged on exit.
  @full_owner {SamenCore.PiiRedPath.BadVault, "piv"}
  @scratch_owner {SamenCore.PiiRedPath.UnclassifiedNonPii, "piu"}

  defp compile!(name, body, _abbrev) do
    {mod, abbrev} = if name == "Full", do: @full_owner, else: @scratch_owner
    purge(mod)

    src = """
    defmodule #{inspect(mod)} do
      use Samen.Resource,
        otp_app: :samen_core,
        domain: nil,
        validate_domain_inclusion?: false,
        data_layer: AshPostgres.DataLayer,
        abbrev: "#{abbrev}",
        archivable: true

      postgres do
        table "#{abbrev}_thing"
        repo SamenCore.TestRepo
      end

      #{body}
    end
    """

    Code.compile_string(src)
    on_exit(fn -> purge(mod) end)
    mod
  end

  defp purge(mod) do
    for m <- [mod, Module.concat(Inspect, mod)] do
      :code.purge(m)
      :code.delete(m)
    end
  end

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
      assert f["rate"].units == "percent points (0–100)"
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
end
