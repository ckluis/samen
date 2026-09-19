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

  # A host type that self-classifies NOTHING and is not a known non-PII scalar —
  # i.e. the mask-unknown-by-default case. Load-bearing for `classified?/1`: it is
  # an ATOM (a real, compiled module), so a `classified?` that answers on
  # atom-ness rather than on membership of the non-PII scalar registry would call
  # it "classified" and hand the C4 verifier a deliberately-plain column that is
  # only plain because nobody classified it.
  defmodule PlainUnclassifiedType do
    @moduledoc false
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

  # ==========================================================================
  # The two PUBLIC predicates over classify/1 (MG-01, MG-02)
  #
  # Filed by the mutation gate (ADR-049), not by hand: `scripts/mutate.sh` mutated
  # `pii?/1`'s `classify(type) == :pii` to `!= :pii` and `classified?/1`'s
  # `is_atom(module) and MapSet.member?(...)` to `or`, and this suite — the owning
  # suite for classification.ex — killed NEITHER. Both predicates had zero
  # coverage here: every existing test calls `classify/1` directly. An inverted
  # `pii?/1` is a total fail-open (every PII type reports non-PII to every caller)
  # and it would have shipped green.
  # ==========================================================================

  test "pii?/1 tracks classify/1 in BOTH directions (an inverted predicate is a total fail-open)" do
    # PII direction — the assertion an inverted `==`/`!=` breaks.
    assert Classification.pii?(SelfPiiType)
    assert Classification.pii?(PlainUnclassifiedType), "mask-unknown-by-default: an unclassified type IS PII"

    # NON-PII direction — the positive control. Without it, `pii?/1 = fn _ -> true end`
    # would pass the assertions above, so the pair is what pins the predicate.
    refute Classification.pii?(:boolean)
    refute Classification.pii?(Ash.Type.UUID)
  end

  test "classified?/1 answers on the non-PII REGISTRY, not on atom-ness (fail-open closed)" do
    put_clearances([])

    # RED: a compiled module that self-classifies nothing and is not in the non-PII
    # scalar registry is NOT classified — it is merely unknown, and the default masks
    # it. A `classified?` whose unknown-branch answers `is_atom(module) or
    # MapSet.member?(...)` calls every atom classified and this refute is the only
    # thing standing in its way.
    refute Classification.classified?(PlainUnclassifiedType)
    refute Classification.classified?(:no_such_type_anywhere)

    # GREEN positive control (anti-tautology): a REGISTERED non-PII scalar IS
    # classified, so the refutes above are the registry biting, not a predicate that
    # can never say yes.
    assert Classification.classified?(:boolean)
    assert Classification.classified?(Ash.Type.UUID)
  end

  test "anti-tautology: the SAME type is :pii without a clearance and :non_pii with one" do
    put_clearances([])
    assert Classification.classify(ClearableNonPiiType) == :pii

    put_clearances([
      %{type: ClearableNonPiiType, cleared_by: "alice", reviewed_by: "bob", reason: "cleared"}
    ])

    assert Classification.classify(ClearableNonPiiType) == :non_pii
  end
end
