defmodule Samen.PiiTypeClearanceTest do
  @moduledoc """
  ADR-034 — the reviewer-gated **type-level** `:non_pii` clearance seam.

  A host Ash type can self-classify `:non_pii` (`samen_pii_class/0 => :non_pii`),
  opting EVERY column of that type out of masking. Left ungoverned that is a
  single-party escape hatch: broader than the per-column `non_pii!` override, yet
  without its two-distinct-party gate. This file proves the hole is CLOSED —
  `Samen.Pii.Classification.classify/1` honors a type's `:non_pii` self-class ONLY
  behind a valid, two-distinct-party clearance, and fails closed (→ `:pii`,
  masked) otherwise.

  GREEN: a valid two-distinct-party clearance → the governed opt-out works.
  RED:   no clearance / a self-review clearance → the SAME type masks (`:pii`).
         Anti-tautology positive control: the same module WITH a valid clearance
         classifies `:non_pii`, so the RED result is the gate biting, not a type
         that could never be non-PII.

  Mutates `:non_pii_type_clearances` app config, so `async: false`; every test
  restores the prior config in `on_exit`.
  """
  use ExUnit.Case, async: false

  alias Samen.Pii.Classification
  alias Samen.NonPii.TypeClearance

  # A host type that self-classifies :non_pii (opts its columns OUT of masking).
  # The SAME module is used for RED (no/invalid clearance → :pii) and GREEN (valid
  # clearance → :non_pii): the only thing that changes is the clearance, which is
  # the anti-tautology control.
  defmodule ClearableNonPiiType do
    @moduledoc false
    def samen_pii_class, do: :non_pii
  end

  # A host type that self-classifies :pii — the SAFE direction, never gated.
  defmodule SelfPiiType do
    @moduledoc false
    def samen_pii_class, do: :pii
  end

  @config_key :non_pii_type_clearances

  setup do
    prior = Application.get_env(:samen_core, @config_key)

    on_exit(fn ->
      case prior do
        nil -> Application.delete_env(:samen_core, @config_key)
        _ -> Application.put_env(:samen_core, @config_key, prior)
      end
    end)

    :ok
  end

  defp put_clearances(list), do: Application.put_env(:samen_core, @config_key, list)

  # ==========================================================================
  # GREEN — the governed opt-out works
  # ==========================================================================

  test "GREEN: a valid two-distinct-party clearance honors the :non_pii self-class" do
    put_clearances([
      %{
        type: ClearableNonPiiType,
        cleared_by: "alice",
        reviewed_by: "bob",
        reason: "opaque tenant-scoped enum token, never carries PII"
      }
    ])

    assert TypeClearance.cleared?(ClearableNonPiiType)
    assert Classification.classify(ClearableNonPiiType) == :non_pii
    assert Classification.classified?(ClearableNonPiiType)
  end

  test "GREEN: self-classifying :pii still classifies :pii (unchanged, ungated)" do
    # No clearance in scope; opting INTO protection needs none.
    assert Classification.classify(SelfPiiType) == :pii
    assert Classification.classified?(SelfPiiType)
  end

  test "GREEN: a structural non-PII scalar primitive still classifies :non_pii (unchanged)" do
    assert Classification.classify(:boolean) == :non_pii
    assert Classification.classify(Ash.Type.UUID) == :non_pii
  end

  # ==========================================================================
  # RED — the escape hatch is closed (fail-closed)
  # ==========================================================================

  test "RED: an ungoverned :non_pii self-classifying type classifies :pii (hole closed)" do
    # No clearance configured at all.
    put_clearances([])

    refute TypeClearance.cleared?(ClearableNonPiiType)
    assert Classification.classify(ClearableNonPiiType) == :pii
    refute Classification.classified?(ClearableNonPiiType)
  end

  test "RED: a SELF-REVIEW clearance (cleared_by == reviewed_by) does NOT honor :non_pii" do
    # A single actor cannot wave a whole type out of masking — the same
    # distinct-party invariant Samen.NonPii.register/1 enforces for columns.
    put_clearances([
      %{
        type: ClearableNonPiiType,
        cleared_by: "alice",
        reviewed_by: "alice",
        reason: "trying to self-clear"
      }
    ])

    refute TypeClearance.cleared?(ClearableNonPiiType)
    assert Classification.classify(ClearableNonPiiType) == :pii
  end

  test "RED: a clearance naming a DIFFERENT type does not clear this one" do
    put_clearances([
      %{
        type: SelfPiiType,
        cleared_by: "alice",
        reviewed_by: "bob",
        reason: "unrelated type"
      }
    ])

    refute TypeClearance.cleared?(ClearableNonPiiType)
    assert Classification.classify(ClearableNonPiiType) == :pii
  end

  test "RED: a malformed clearance (missing/blank reviewer or reason) fails closed" do
    for bad <- [
          %{type: ClearableNonPiiType, cleared_by: "alice", reason: "no reviewer key"},
          %{type: ClearableNonPiiType, cleared_by: "alice", reviewed_by: "", reason: "blank reviewer"},
          %{type: ClearableNonPiiType, cleared_by: "  ", reviewed_by: "bob", reason: "blank clearer"},
          %{type: ClearableNonPiiType, cleared_by: "alice", reviewed_by: "bob", reason: "   "},
          %{type: ClearableNonPiiType, cleared_by: "alice", reviewed_by: "bob"},
          "not even a map"
        ] do
      put_clearances([bad])

      refute TypeClearance.cleared?(ClearableNonPiiType),
             "expected malformed clearance #{inspect(bad)} to fail closed"

      assert Classification.classify(ClearableNonPiiType) == :pii
    end
  end

  # ==========================================================================
  # Anti-tautology: the SAME module flips on the clearance, nothing else
  # ==========================================================================

  test "anti-tautology: the SAME type is :pii without a clearance and :non_pii with one" do
    put_clearances([])
    assert Classification.classify(ClearableNonPiiType) == :pii

    put_clearances([
      %{type: ClearableNonPiiType, cleared_by: "alice", reviewed_by: "bob", reason: "cleared"}
    ])

    assert Classification.classify(ClearableNonPiiType) == :non_pii
  end
end
