defmodule Samen.RedPathTest do
  @moduledoc """
  RED PATH for S0.3: composing a fragment that declares an extension the
  composing resource does NOT provide must FAIL to compile with a clear
  diagnostic.

  This is the fail-closed guarantee behind single-table composition: a fragment
  cannot smuggle in a DSL section (and its guarantees) that the base macro never
  wired. Spark's own behaviour would silently *union* the extra extension into
  the resource; `Samen.Resource` refuses instead.

  If the first test passes when it should fail (an abbrev-less-of-a-capability
  resource compiles), the spike is NOT green.
  """
  use ExUnit.Case, async: false

  # The composing resource under test. `RedPathFixtures.RogueFragment` declares
  # `extensions: [Samen.Pii, Samen.Audit]`; Samen.Resource provides Pii but NOT
  # Audit, so this composition must be rejected.
  @rogue_source """
  defmodule RedPath.ComposesRogueFragment do
    use Samen.Resource,
      otp_app: :s03_fragments,
      domain: nil,
      validate_domain_inclusion?: false,
      data_layer: AshPostgres.DataLayer,
      abbrev: "rog",
      base: RedPathFixtures.RogueFragment

    postgres do
      table "rog_thing"
      repo S03Fragments.Repo
    end

    attributes do
      uuid_primary_key :id
    end
  end
  """

  @good_source """
  defmodule RedPath.ComposesGoodFragment do
    use Samen.Resource,
      otp_app: :s03_fragments,
      domain: nil,
      validate_domain_inclusion?: false,
      data_layer: AshPostgres.DataLayer,
      abbrev: "gud",
      base: RedPathFixtures.GoodFragment

    postgres do
      table "gud_thing"
      repo S03Fragments.Repo
    end

    attributes do
      uuid_primary_key :id
    end
  end
  """

  test "red path: composing a fragment that requires an unprovided extension fails compile" do
    err =
      assert_raise CompileError, fn ->
        Code.compile_string(@rogue_source)
      end

    # The diagnostic must name the offending extension and explain WHY — not a
    # bare match/KeyError, and not a downstream Spark error about an unknown
    # section. It is caught at the composing resource's `use` line.
    assert err.description =~ "Samen.Audit"
    assert err.description =~ "does not provide"
  end

  # --- Anti-tautology control -------------------------------------------------
  # Prove the red path fails for the RIGHT reason: the SAME composition shape but
  # with a fragment that declares only provided extensions compiles cleanly and
  # folds its attribute in. If this failed, the red path above might be passing
  # because fragment composition is broken in general.
  test "control: composing a fragment that requires only provided extensions compiles fine" do
    modules = Code.compile_string(@good_source)

    assert Enum.any?(modules, fn {mod, _bin} -> mod == RedPath.ComposesGoodFragment end)

    # The fragment's attribute folded in AND inherited the composer's abbrev.
    src = Ash.Resource.Info.attribute(RedPath.ComposesGoodFragment, :note).source
    assert src == :gud_note
  after
    :code.purge(RedPath.ComposesGoodFragment)
    :code.delete(RedPath.ComposesGoodFragment)
  end

  # Second red path (defense in depth): a composed resource with NO abbrev also
  # fails — self-qualifying storage stays mandatory under composition too.
  test "red path: composed resource without an abbrev fails compile" do
    source = """
    defmodule RedPath.NoAbbrevComposed do
      use Samen.Resource,
        otp_app: :s03_fragments,
        domain: nil,
        validate_domain_inclusion?: false,
        data_layer: AshPostgres.DataLayer,
        base: RedPathFixtures.GoodFragment
    end
    """

    err =
      assert_raise CompileError, fn ->
        Code.compile_string(source)
      end

    assert err.description =~ "abbrev"
    assert err.description =~ ~r/self-qualifying storage/i
  end
end
