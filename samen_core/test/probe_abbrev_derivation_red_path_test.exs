defmodule Samen.ProbeAbbrevDerivationRedPathTest do
  @moduledoc """
  RED PATH for P1-probe-slice-matcherror.

  Both permanent generative CI proofs — `priv/gen_app_flagship_probe.exs` and
  `priv/gen_post_probe.exs` — derive two test-abbrev letters from a
  `System.unique_integer([:positive])` value:

      suffix  = <int> |> Integer.to_string() |> ...slice(-2, 2)
      letters = for <<c <- suffix>>, do: rem(c - ?0, 26) + ?a
      [l1, l2] = letters

  When the VM hands out a single-digit first positive unique_integer (common
  under `mix run` boot — scheduler-count / prior-allocation dependent), an
  UNPADDED `String.slice(-2, 2)` returns a 1-char string, `letters` has one
  element, and `[l1, l2] = letters` raises MatchError with a true exit 1 —
  turning the AC-X-1 flagship step and the AC-G4-7/G26 post-app step
  intermittently RED for a reason wholly unrelated to the generators.

  The fix pads the integer string to >= 2 chars before slicing. This test
  pins the derivation as a TOTAL function over every unique_integer value the
  VM can hand out, and its anti-tautology control proves the OLD (unpadded)
  form actually crashed on the same inputs — so the test guards the real bug,
  not a tautology.
  """
  use ExUnit.Case, async: true

  # The FIXED derivation, byte-identical to what both probes now run. Both
  # probe scripts pad-lead to 2 before the (-2, 2) slice, so `suffix` is
  # always >= 2 chars and `letters` always has exactly two elements.
  defp derive_fixed(n) do
    suffix =
      n
      |> Integer.to_string()
      |> String.pad_leading(2, "0")
      |> String.slice(-2, 2)

    letters = for <<c <- suffix>>, do: rem(c - ?0, 26) + ?a
    [l1, l2] = letters
    <<l1, l2>>
  end

  # The ORIGINAL (buggy) derivation — no pad. Present ONLY as the
  # anti-tautology control below.
  defp derive_unpadded(n) do
    suffix = n |> Integer.to_string() |> String.slice(-2, 2)
    letters = for <<c <- suffix>>, do: rem(c - ?0, 26) + ?a
    [l1, l2] = letters
    <<l1, l2>>
  end

  # Every value the pathological VM boot can hand out as the first positive
  # unique_integer, plus a spread of multi-digit and large values.
  @single_digits Enum.to_list(0..9)
  @multi_digit [10, 42, 99, 100, 12_345, 999_999, 1_000_000]

  test "GREEN: fixed derivation is total — always yields exactly two a..z letters" do
    for n <- @single_digits ++ @multi_digit do
      out = derive_fixed(n)

      assert byte_size(out) == 2,
             "derive_fixed(#{n}) produced #{inspect(out)}; expected a 2-byte abbrev"

      for <<c <- out>> do
        assert c in ?a..?z,
               "derive_fixed(#{n}) produced non a..z byte #{inspect(<<c>>)}"
      end
    end
  end

  test "GREEN: single-digit unique_integer (the crash trigger) no longer raises" do
    # These are the exact inputs the finding reproduced on (first positive
    # unique_integer under `mix run` boot). Padding makes them total.
    for n <- @single_digits do
      assert byte_size(derive_fixed(n)) == 2
    end
  end

  # ==========================================================================
  # ANTI-TAUTOLOGY CONTROL: the OLD (unpadded) form crashed on the same inputs.
  # If this control ever stops raising, the GREEN tests above are vacuous.
  # ==========================================================================

  test "RED (control): unpadded derivation raises MatchError on every single-digit input" do
    for n <- @single_digits do
      assert_raise MatchError, fn -> derive_unpadded(n) end
    end
  end

  test "RED (control): unpadded derivation still works for multi-digit inputs (bug was single-digit-only)" do
    # Proves the crash was specifically the short-slice case, not a blanket
    # breakage — so the pad is the minimal, correct fix.
    for n <- @multi_digit do
      assert byte_size(derive_unpadded(n)) == 2
      assert derive_unpadded(n) == derive_fixed(n)
    end
  end
end
