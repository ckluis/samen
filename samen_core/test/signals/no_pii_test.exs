defmodule Samen.Signals.NoPiiTest do
  @moduledoc """
  Issue #96 D2 — no PII in an `Ash.Signals` signal (`Samen.Signals.NoPii`,
  `mix samen.verify.signals_no_pii`).

    * rule (1): a signal argument whose type classifies `:pii` — a vault/PII type, or a free
      `:string` under mask-unknown-by-default — is refused;
    * rule (2): an `emit` that takes a signal field from a declared `pii_attribute` is
      refused, even when the argument's own type is a cleared scalar;
    * positive controls: a clean signal (an array of ids included) passes, and samen_core's
      real domains pass;
    * zero discovered resources fails closed.

  Fixtures: `test/support/signals_fixture.ex` (domains NOT in `:ash_domains`).
  """
  use ExUnit.Case, async: true

  alias Samen.Signals.NoPii
  alias SamenCore.Support.SignalsFixture

  @project_dir File.cwd!()

  @clean Ash.Domain.Info.resources(SignalsFixture.CleanDomain)
  @leaky Ash.Domain.Info.resources(SignalsFixture.LeakyDomain)

  describe "build-time check" do
    test "a clean signal passes, an array of ids included, and it IS discovered" do
      # ANTI-VACUITY: the clean fixture's signal module is found, so "no violations" is a
      # verdict on a real signal, not on nothing.
      assert NoPii.signal_modules(@clean) == [SignalsFixture.CleanSignals]
      assert NoPii.violations(@clean) == []
    end

    test "RED: a PII-typed signal argument is a violation" do
      assert [_ | _] = violations = NoPii.argument_violations(SignalsFixture.LeakySignals)
      assert Enum.any?(violations, &(&1 =~ "argument :email" and &1 =~ "Samen.Type.EmailAddress"))
      refute Enum.any?(violations, &(&1 =~ "argument :contact_id"))
    end

    test "RED: a free :string signal argument is a violation (mask-unknown-by-default)" do
      violations = NoPii.argument_violations(SignalsFixture.LeakySignals)
      assert Enum.any?(violations, &(&1 =~ "argument :note" and &1 =~ "Ash.Type.String"))
    end

    test "RED: an emit taking a signal field from a PII attribute is a violation" do
      # Rule (1) alone passes this signal: every argument type is a non-PII scalar.
      assert NoPii.argument_violations(SignalsFixture.TaxSignals) == []

      assert [violation] = NoPii.emit_violations(SignalsFixture.Taxpayer)
      assert violation =~ "action :record"
      assert violation =~ "signal field :tax_id is taken from the PII attribute :tax_id"
    end

    test "the leaky domain reports every violation, each rule included" do
      violations = NoPii.violations(@leaky)
      assert length(violations) == 3

      assert NoPii.signal_modules(@leaky) ==
               Enum.sort([SignalsFixture.LeakySignals, SignalsFixture.TaxSignals])
    end
  end

  @tag :exit_code
  test "mix samen.verify.signals_no_pii exits 0 on samen_core's real domains" do
    {output, code} = verify([])
    assert code == 0, output
    assert output =~ "OK"
  end

  @tag :exit_code
  test "mix samen.verify.signals_no_pii exits 0 on the clean fixture domain" do
    {output, code} = verify(["--domain", inspect(SignalsFixture.CleanDomain)])
    assert code == 0, output
    assert output =~ "OK"
  end

  @tag :exit_code
  test "RED: mix samen.verify.signals_no_pii exits 1 on a PII signal" do
    {output, code} = verify(["--domain", inspect(SignalsFixture.LeakyDomain)])
    assert code == 1, output
    assert output =~ "3 violation(s)"
    assert output =~ "argument :email"
    assert output =~ "PII attribute :tax_id"
  end

  @tag :exit_code
  test "RED: mix samen.verify.signals_no_pii exits 1 when it discovers zero resources" do
    {output, code} = verify([], [{"SAMEN_EMPTY_ASH_DOMAINS", "1"}])
    assert code == 1, output
    assert output =~ "ZERO resources"
  end

  defp verify(args, env \\ []) do
    System.cmd("mix", ["samen.verify.signals_no_pii" | args],
      cd: @project_dir,
      env: [{"MIX_ENV", "test"} | env],
      stderr_to_stdout: true
    )
  end
end
