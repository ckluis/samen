defmodule Samen.NoPiiColumnsRedPathTest do
  @moduledoc """
  RED PATHS for the C7 `NoPiiColumns` aggregate-plane invariant (T4.2 clause (b);
  HARD RULE 2 — every guarantee ships a must-fail test + an anti-tautology probe).

  The token-blind aggregate plane's resources must have "no pii_ columns at all"
  (doc §control). A `use Samen.Aggregate.Resource` that could reach vaulted PII must
  NOT COMPILE. Four violation kinds each fail compile:

    1. a declared `pii_attribute`,
    2. a declared `vault`,
    3. a `pii_`-shaped physical column (defense in depth),
    4. a relationship whose destination is a PII-bearing resource.

  The hard abort is `Samen.Aggregate.NoPiiTransformer` (a verifier raise does not
  reliably abort `Code.compile_string` in this Ash/Spark version — see the T1.3
  note). `Samen.Verifiers.NoPiiColumns` is the named C7 verifier (introspection +
  the whole-app sweep's shared rule).

  Anti-tautology (built in): the SAME shape WITHOUT the PII declaration — a CLEAN
  aggregate projection — compiles and reads. So the red paths fail because of the
  PII, not because aggregate resources are broken in general.

  Fixtures use the abbrevs reserved for them in `priv/abbrev_registry.json`
  (`agp`/`agv`/`agr`/`agb`/`agc`) so the abbrev-registry macro check passes and the
  C7 behaviour under test is what the assertion exercises.
  """
  use ExUnit.Case, async: false

  # ==========================================================================
  # A CLEAN aggregate projection — the anti-tautology positive control.
  # ==========================================================================

  @clean """
  defmodule SamenCore.Support.AggregateFixture.CleanProjection do
    use Samen.Aggregate.Resource,
      otp_app: :samen_core,
      domain: nil,
      validate_domain_inclusion?: false,
      data_layer: AshPostgres.DataLayer,
      abbrev: "agc"

    postgres do
      table "agc_thing"
      repo SamenCore.TestRepo
    end

    attributes do
      attribute :tier, :string, public?: true
      attribute :tenant_count, :integer, public?: true
    end

    actions do
      defaults [:read]
    end
  end
  """

  test "control (anti-tautology): a CLEAN aggregate projection compiles and is marked aggregate-plane" do
    purge(SamenCore.Support.AggregateFixture.CleanProjection)

    modules = Code.compile_string(@clean)
    mod = SamenCore.Support.AggregateFixture.CleanProjection
    assert Enum.any?(modules, fn {m, _} -> m == mod end)

    # It carries the aggregate-plane marker...
    assert Samen.Aggregate.Info.aggregate_plane?(mod)
    # ...and the C7 rule finds NO violations on it (proves the rule discriminates —
    # it does not flag every aggregate resource).
    assert Samen.Verifiers.NoPiiColumns.violations(mod, mod) == []
  after
    purge(SamenCore.Support.AggregateFixture.CleanProjection)
  end

  # ==========================================================================
  # RED 1 — a declared pii_attribute fails compile.
  # ==========================================================================

  @pii_attr """
  defmodule SamenCore.Support.AggregateFixture.PiiProjection do
    use Samen.Aggregate.Resource,
      otp_app: :samen_core,
      domain: nil,
      validate_domain_inclusion?: false,
      data_layer: AshPostgres.DataLayer,
      abbrev: "agp"

    postgres do
      table "agp_thing"
      repo SamenCore.TestRepo
    end

    pii do
      vault :pii_name
      pii_attribute :dob, :date, vault: :pii_name
    end
  end
  """

  test "RED 1: a pii_attribute in an aggregate resource FAILS compile" do
    purge(SamenCore.Support.AggregateFixture.PiiProjection)

    err = assert_raise Spark.Error.DslError, fn -> Code.compile_string(@pii_attr) end
    msg = Exception.message(err)
    assert msg =~ "aggregate-plane"
    assert msg =~ ~r/pii_attribute|no pii/i
  after
    purge(SamenCore.Support.AggregateFixture.PiiProjection)
  end

  # ==========================================================================
  # RED 2 — a declared vault (even with no pii_attribute) fails compile.
  # ==========================================================================

  @vault_only """
  defmodule SamenCore.Support.AggregateFixture.VaultProjection do
    use Samen.Aggregate.Resource,
      otp_app: :samen_core,
      domain: nil,
      validate_domain_inclusion?: false,
      data_layer: AshPostgres.DataLayer,
      abbrev: "agv"

    postgres do
      table "agv_thing"
      repo SamenCore.TestRepo
    end

    pii do
      vault :pii_name
    end
  end
  """

  test "RED 2: a declared vault in an aggregate resource FAILS compile" do
    purge(SamenCore.Support.AggregateFixture.VaultProjection)

    err = assert_raise Spark.Error.DslError, fn -> Code.compile_string(@vault_only) end
    msg = Exception.message(err)
    assert msg =~ "aggregate-plane"
    assert msg =~ ~r/vault/i
  after
    purge(SamenCore.Support.AggregateFixture.VaultProjection)
  end

  # ==========================================================================
  # RED 3 — a relationship reaching a PII-bearing resource fails compile.
  # ==========================================================================

  # A PII-bearing target resource (a plain Samen resource with a pii_attribute).
  @pii_bearing_target """
  defmodule SamenCore.Support.AggregateFixture.PiiBearingTarget do
    use Samen.Resource,
      otp_app: :samen_core,
      domain: nil,
      validate_domain_inclusion?: false,
      data_layer: AshPostgres.DataLayer,
      abbrev: "agb"

    postgres do
      table "agb_thing"
      repo SamenCore.TestRepo
    end

    pii do
      vault :pii_name
      pii_attribute :full_name, Samen.Type.FullName, vault: :pii_name
    end

    actions do
      defaults [:read, :destroy, create: :*, update: :*]
    end
  end
  """

  @relationship_to_pii """
  defmodule SamenCore.Support.AggregateFixture.RelationshipProjection do
    use Samen.Aggregate.Resource,
      otp_app: :samen_core,
      domain: nil,
      validate_domain_inclusion?: false,
      data_layer: AshPostgres.DataLayer,
      abbrev: "agr"

    postgres do
      table "agr_thing"
      repo SamenCore.TestRepo
    end

    attributes do
      attribute :n, :integer, public?: true
    end

    relationships do
      belongs_to :target, SamenCore.Support.AggregateFixture.PiiBearingTarget do
        public? true
        attribute_type :uuid
      end
    end

    actions do
      defaults [:read]
    end
  end
  """

  test "RED 3: a relationship reaching a PII-bearing resource FAILS compile" do
    purge(SamenCore.Support.AggregateFixture.RelationshipProjection)
    purge(SamenCore.Support.AggregateFixture.PiiBearingTarget)

    # Compile the PII-bearing target first (a normal resource — legal).
    Code.compile_string(@pii_bearing_target)

    err =
      assert_raise Spark.Error.DslError, fn -> Code.compile_string(@relationship_to_pii) end

    msg = Exception.message(err)
    assert msg =~ "aggregate-plane"
    assert msg =~ ~r/PII-bearing|relationship/i
  after
    purge(SamenCore.Support.AggregateFixture.RelationshipProjection)
    purge(SamenCore.Support.AggregateFixture.PiiBearingTarget)
  end

  defp purge(mod) do
    :code.purge(mod)
    :code.delete(mod)
  end
end
