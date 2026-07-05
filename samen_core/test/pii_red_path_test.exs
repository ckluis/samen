defmodule Samen.PiiRedPathTest do
  @moduledoc """
  RED PATHS for the T1.3 PII DSL (HARD RULE 2 — every guarantee ships with a
  must-fail test). Two red paths, each with an anti-tautology control:

    1. **Undeclared vault fails compile.** A `pii_attribute` routing to a vault the
       `pii do` block never declared is a `Spark.Error.DslError` at compile time
       (closed-world routing). Enforced by `Samen.Transformers.MaterializePii`
       (transformer stage — reliably aborts compile) with the
       `Samen.Pii.Verifiers.VaultDeclared` verifier as defense-in-depth. Control:
       the SAME resource with the vault declared compiles.

    2. **A likely-PII composite type declared OUTSIDE a `pii do` block is not
       silently plain.** Declaring `attribute :full_name, Samen.Type.FullName`
       (a composite PII type) as a plain attribute compiles (it is a valid Ash
       attribute) but the classification oracle flags it: `classify(type) == :pii`
       while `vault_routed? == false`. That mismatch is exactly what the C4
       `pii_classify` verifier (T1.8c) keys on — the composite is NOT treated as
       plain. Control: a genuinely non-PII plain attribute (`:boolean`) is cleared.

  The compile-time fixtures use the abbrevs reserved for them in
  `priv/abbrev_registry.json` (`piv`, `piu`) so the registry check passes and the
  PII behaviour under test is what the assertion exercises.
  """
  use ExUnit.Case, async: false

  alias Samen.Pii.Classification
  alias Samen.Pii.Info

  # ==========================================================================
  # RED PATH 1 — undeclared vault fails compile
  # ==========================================================================

  @bad_vault """
  defmodule SamenCore.PiiRedPath.BadVault do
    use Samen.Resource,
      otp_app: :samen_core,
      domain: nil,
      validate_domain_inclusion?: false,
      data_layer: AshPostgres.DataLayer,
      abbrev: "piv"

    postgres do
      table "piv_thing"
      repo SamenCore.TestRepo
    end

    pii do
      vault :pii_name
      pii_attribute :dob, :date, vault: :pii_dob_typo
    end
  end
  """

  @good_vault """
  defmodule SamenCore.PiiRedPath.BadVault do
    use Samen.Resource,
      otp_app: :samen_core,
      domain: nil,
      validate_domain_inclusion?: false,
      data_layer: AshPostgres.DataLayer,
      abbrev: "piv"

    postgres do
      table "piv_thing"
      repo SamenCore.TestRepo
    end

    pii do
      vault :pii_name
      vault :pii_dob
      pii_attribute :dob, :date, vault: :pii_dob
    end
  end
  """

  test "red path: pii_attribute routing to an undeclared vault fails compile" do
    purge(SamenCore.PiiRedPath.BadVault)

    err = assert_raise Spark.Error.DslError, fn -> Code.compile_string(@bad_vault) end

    msg = Exception.message(err)
    assert msg =~ "pii_dob_typo"
    assert msg =~ ~r/not declared/i
    assert msg =~ ~r/closed-world/i
  end

  test "control: the SAME resource with the vault DECLARED compiles cleanly" do
    # Anti-tautology: proves the red path fails because of the undeclared vault,
    # not because the resource shape or pii block is broken in general.
    purge(SamenCore.PiiRedPath.BadVault)

    modules = Code.compile_string(@good_vault)
    assert Enum.any?(modules, fn {m, _} -> m == SamenCore.PiiRedPath.BadVault end)

    assert Info.vault_routed?(SamenCore.PiiRedPath.BadVault, :dob)
    assert Info.routing(SamenCore.PiiRedPath.BadVault)[:pii_dob] == [:pii_piv_dob]
  after
    purge(SamenCore.PiiRedPath.BadVault)
  end

  # ==========================================================================
  # RED PATH 2 — a likely-PII composite type outside `pii do` is NOT silently plain
  # ==========================================================================

  @composite_as_plain """
  defmodule SamenCore.PiiRedPath.UnclassifiedNonPii do
    use Samen.Resource,
      otp_app: :samen_core,
      domain: nil,
      validate_domain_inclusion?: false,
      data_layer: AshPostgres.DataLayer,
      abbrev: "piu"

    postgres do
      table "piu_thing"
      repo SamenCore.TestRepo
    end

    attributes do
      # A composite PII type declared as a PLAIN attribute, OUTSIDE any pii do block.
      attribute :full_name, Samen.Type.FullName, public?: true
      # A genuinely non-PII plain attribute — the control.
      attribute :active, :boolean, public?: true
    end
  end
  """

  test "red path: a composite PII type declared outside `pii do` is flagged, not silently plain" do
    purge(SamenCore.PiiRedPath.UnclassifiedNonPii)

    # It compiles (a plain attribute of a composite type is a valid Ash attribute)...
    modules = Code.compile_string(@composite_as_plain)
    mod = SamenCore.PiiRedPath.UnclassifiedNonPii
    assert Enum.any?(modules, fn {m, _} -> m == mod end)

    attrs = Map.new(Ash.Resource.Info.attributes(mod), &{&1.name, &1})

    # ...but it is NOT vault-routed (it was never declared in a pii block)...
    refute Info.vault_routed?(mod, :full_name)

    # ...and the classification ORACLE flags its type as PII. This mismatch —
    # a :pii-classified type that is NOT vault-routed — is precisely the C4
    # `pii_classify` violation. The composite is NOT treated as plain-by-omission.
    assert Classification.classify(attrs[:full_name].type) == :pii,
           "a composite PII type left outside `pii do` must classify :pii (not silently plain)"

    # Anti-tautology control: the genuinely non-PII plain attribute IS cleared —
    # proving the oracle discriminates, and does not just call everything PII.
    assert Classification.classify(attrs[:active].type) == :non_pii
    refute Info.vault_routed?(mod, :active)
  after
    purge(SamenCore.PiiRedPath.UnclassifiedNonPii)
  end

  defp purge(mod) do
    :code.purge(mod)
    :code.delete(mod)
  end
end
