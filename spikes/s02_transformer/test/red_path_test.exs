defmodule Samen.RedPathTest do
  @moduledoc """
  RED PATH for S0.2: a Samen resource declared WITHOUT `abbrev:` must fail to
  compile with a clear, actionable diagnostic. Self-qualifying storage is
  mandatory — there is no "unprefixed" fallback.

  This is the fail-closed guarantee: if this test passes when it should fail
  (i.e. an abbrev-less resource compiles), the spike is NOT green.
  """
  use ExUnit.Case, async: false

  @no_abbrev_source """
  defmodule RedPath.NoAbbrevResource do
    use Samen.Resource,
      otp_app: :s02_transformer,
      domain: S02Transformer.Crm,
      data_layer: AshPostgres.DataLayer

    attributes do
      uuid_primary_key :id
      attribute :name, :string, public?: true
    end
  end
  """

  @bad_abbrev_source """
  defmodule RedPath.BadAbbrevResource do
    use Samen.Resource,
      otp_app: :s02_transformer,
      domain: S02Transformer.Crm,
      data_layer: AshPostgres.DataLayer,
      abbrev: "Company_123"

    attributes do
      uuid_primary_key :id
      attribute :name, :string, public?: true
    end
  end
  """

  test "red path: resource with NO abbrev fails to compile with a clear diagnostic" do
    err =
      assert_raise CompileError, fn ->
        Code.compile_string(@no_abbrev_source)
      end

    # The diagnostic must name the missing `abbrev:` and explain WHY (mandatory
    # self-qualifying storage) — not a bare KeyError or match failure.
    assert err.description =~ "abbrev"
    assert err.description =~ ~r/self-qualifying storage/i
  end

  test "red path: resource with a MALFORMED abbrev fails to compile" do
    assert_raise CompileError, ~r/abbrev/, fn ->
      Code.compile_string(@bad_abbrev_source)
    end
  end

  # --- Meta / anti-tautology guard -------------------------------------------
  # Prove the red-path assertion is real: the SAME resource shape but WITH a
  # valid abbrev compiles cleanly. If this failed, the red path above might be
  # passing for the wrong reason (e.g. an unrelated compile error).
  test "control: the identical resource WITH a valid abbrev compiles fine" do
    source = """
    defmodule RedPath.GoodAbbrevResource do
      use Samen.Resource,
        otp_app: :s02_transformer,
        domain: nil,
        validate_domain_inclusion?: false,
        data_layer: AshPostgres.DataLayer,
        abbrev: "rpg"

      postgres do
        table "rpg_thing"
        repo S02Transformer.Repo
      end

      attributes do
        uuid_primary_key :id
        attribute :name, :string, public?: true
      end
    end
    """

    modules = Code.compile_string(source)
    assert Enum.any?(modules, fn {mod, _bin} -> mod == RedPath.GoodAbbrevResource end)

    # And it actually applied the prefix.
    src = Ash.Resource.Info.attribute(RedPath.GoodAbbrevResource, :name).source
    assert src == :rpg_name
  after
    :code.purge(RedPath.GoodAbbrevResource)
    :code.delete(RedPath.GoodAbbrevResource)
  end
end
