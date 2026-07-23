defmodule Samen.NoPanColumnsRedPathTest do
  @moduledoc """
  RED PATH for the B5 `NoPanColumns` no-PAN invariant (ADR-038 §3.5; T23;
  done-criterion 1 — "no column matching PAN/card-number/cvc shapes ANYWHERE",
  HARD RULE 2: every guarantee ships a must-fail test + an anti-tautology probe).

  Unlike the aggregate-plane-only `NoPiiColumns` verifier, `NoPanColumns` is wired
  into the BASE `Samen.Extension` — it runs on every plane, in every host. A
  resource declaring a PAN/CVC-shaped attribute (a throwaway, compiled-then-purged
  fixture here — exactly the "add a throwaway PAN-shaped column locally, confirm
  the probe catches it, remove it" proof the task demands) must NOT COMPILE,
  anywhere.

  Anti-tautology (built in): the SAME resource shape WITHOUT the PAN-shaped
  attribute — a CLEAN, ordinary resource — compiles fine and the rule reports zero
  violations on it. So the red path fails because of the PAN-shaped attribute
  specifically, not because ordinary resources are broken in general. A second
  anti-tautology axis: attribute names that LOOK card-adjacent but are NOT
  PAN-shaped (`last4`, `exp_month`, `exp_year`, `brand` — the ADR-038 §3.5
  explicitly-allowed display metadata, and `medical_card_expiry` — a real,
  unrelated attribute already live in `driftwood/lib/driftwood/freight.ex`) must
  NOT be flagged, proving the rule discriminates on SHAPE, not on the bare
  substring "card"/"pan".

  Fixtures use the abbrevs reserved for them in `priv/abbrev_registry.json`
  (`samen_core/spc`, `samen_core/spd`, reserved via the sanctioned
  `mix samen.abbrev.reserve` allocator — ADR-023) so the abbrev-registry macro
  check passes and the B5 behaviour under test is what the assertion exercises.
  """
  use ExUnit.Case, async: false

  alias Samen.Verifiers.NoPanColumns

  # ==========================================================================
  # pan_shaped?/1 — the pure shape-matching rule, unit-tested directly (fast,
  # exhaustive coverage of the token-based matching without needing a compile
  # per case).
  # ==========================================================================

  describe "NoPanColumns.pan_shaped?/1 — the shape rule" do
    test "flags PAN/CVC-shaped names" do
      for name <- ~w(card_number cc_number credit_card_number pan cvc cvv cvc2 cvv2
                     card_cvc card_cvv security_code card_security_code cardnumber
                     cardnum ccnum CARD_NUMBER Pan CVC) do
        assert NoPanColumns.pan_shaped?(name), "expected #{inspect(name)} to be flagged as PAN-shaped"
      end
    end

    test "does NOT flag the ADR-038 §3.5 explicitly-allowed display metadata" do
      for name <- ~w(brand last4 exp_month exp_year payment_method_type) do
        refute NoPanColumns.pan_shaped?(name), "expected #{inspect(name)} to be ALLOWED (non-PAN metadata)"
      end
    end

    test "does NOT flag unrelated words containing the bare substrings pan/card" do
      # Anti-tautology: a naive substring check on "pan"/"card" would false-positive
      # on all of these. The real, already-live driftwood attribute is included.
      for name <- ~w(expansion company spanish medical_card_expiry cardigan expand) do
        refute NoPanColumns.pan_shaped?(name), "expected #{inspect(name)} to be a SAFE unrelated word"
      end
    end
  end

  # ==========================================================================
  # A CLEAN resource — the anti-tautology positive control (compiles + zero
  # violations).
  # ==========================================================================

  @clean """
  defmodule SamenCore.Support.PanFixture.CleanProjection do
    use Samen.Resource,
      otp_app: :samen_core,
      domain: nil,
      validate_domain_inclusion?: false,
      data_layer: AshPostgres.DataLayer,
      abbrev: "spc"

    postgres do
      table "spc_thing"
      repo SamenCore.TestRepo
    end

    attributes do
      attribute :brand, :string, public?: true
      attribute :last4, :string, public?: true
      attribute :exp_month, :integer, public?: true
      attribute :exp_year, :integer, public?: true
    end

    actions do
      defaults [:read, :destroy, create: :*, update: :*]
    end
  end
  """

  test "control (anti-tautology): a resource with ONLY ADR-038 §3.5-allowed display metadata compiles clean" do
    purge(SamenCore.Support.PanFixture.CleanProjection)

    modules = Code.compile_string(@clean)
    mod = SamenCore.Support.PanFixture.CleanProjection
    assert Enum.any?(modules, fn {m, _} -> m == mod end)

    # The rule finds NO violations on it — proves the rule discriminates, it does
    # not flag every resource that merely mentions card-adjacent metadata.
    assert NoPanColumns.violations(mod, mod) == []
  after
    purge(SamenCore.Support.PanFixture.CleanProjection)
  end

  # ==========================================================================
  # RED — a PAN-shaped attribute fails compile, base-wired (any plane, any host).
  # ==========================================================================

  @pan_attr """
  defmodule SamenCore.Support.PanFixture.DirtyProjection do
    use Samen.Resource,
      otp_app: :samen_core,
      domain: nil,
      validate_domain_inclusion?: false,
      data_layer: AshPostgres.DataLayer,
      abbrev: "spd"

    postgres do
      table "spd_thing"
      repo SamenCore.TestRepo
    end

    attributes do
      attribute :card_number, :string, public?: true
    end

    actions do
      defaults [:read, :destroy, create: :*, update: :*]
    end
  end
  """

  test "RED: a PAN-shaped attribute (card_number) FAILS compile — base-wired, not aggregate-only" do
    purge(SamenCore.Support.PanFixture.DirtyProjection)

    err = assert_raise Spark.Error.DslError, fn -> Code.compile_string(@pan_attr) end
    msg = Exception.message(err)
    assert msg =~ "PAN/CVC-shaped"
    assert msg =~ "card_number"
  after
    purge(SamenCore.Support.PanFixture.DirtyProjection)
  end

  @cvc_attr """
  defmodule SamenCore.Support.PanFixture.DirtyProjection do
    use Samen.Resource,
      otp_app: :samen_core,
      domain: nil,
      validate_domain_inclusion?: false,
      data_layer: AshPostgres.DataLayer,
      abbrev: "spd"

    postgres do
      table "spd_thing"
      repo SamenCore.TestRepo
    end

    attributes do
      attribute :cvc, :string, public?: true
    end

    actions do
      defaults [:read, :destroy, create: :*, update: :*]
    end
  end
  """

  test "RED: a CVC-shaped attribute (cvc) FAILS compile" do
    purge(SamenCore.Support.PanFixture.DirtyProjection)

    err = assert_raise Spark.Error.DslError, fn -> Code.compile_string(@cvc_attr) end
    msg = Exception.message(err)
    assert msg =~ "PAN/CVC-shaped"
    assert msg =~ "cvc"
  after
    purge(SamenCore.Support.PanFixture.DirtyProjection)
  end

  defp purge(mod) do
    :code.purge(mod)
    :code.delete(mod)
  end
end
