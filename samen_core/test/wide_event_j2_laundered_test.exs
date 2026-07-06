defmodule Samen.WideEventJ2LaunderedTest do
  @moduledoc """
  T2.7 (b) — prove J2 catches the laundered leak C3 documents as an expected miss.

  The layered privacy design (plan C3 + J2; doc §runs 4a/4b):

    * **Direct leak → C3 AST.** `Logger.info(patient.full_name)` is a syntactic
      flow of a pii field into a sink — caught by `Samen.PiiReads`.
    * **Laundered leak → J2 sink schema.** A pii value passed THROUGH a helper
      first (`log_it(patient.full_name)`) is an opaque local at the sink call —
      a pure AST match MISSES it (the `Corpus.Laundered` LA1–LA3 fixture set,
      already an expected-miss in the pii_reads corpus). J2 closes that path at
      the SINK: every wide-event/span field must be a bounded ID/token/enum/number,
      so a laundered name has NOWHERE TO LAND.

  This test proves both halves against the SAME fixture:

    1. C3 misses the laundered corpus (only a `:laundered_hint` advisory) — the
       documented expected miss.
    2. J2 (the schema check + the runtime WideEvent validation) rejects a laundered
       plaintext name trying to occupy a wide-event field. There is no `:string`
       field, and the runtime rejects a name-shaped value in every bounded field —
       so the laundered name that got past C3 cannot reach the sink typed.
  """
  use ExUnit.Case, async: false

  alias Samen.PiiReads
  alias Samen.WideEvent
  alias Samen.WideEvent.Schema
  alias SamenCore.Support.PiiReadsCorpusLabels, as: Labels

  @laundered_dir Labels.path("laundered")
  @reg Labels.registry()

  test "STEP 1 — C3 MISSES the laundered corpus (documented expected miss)" do
    {:ok, findings} = PiiReads.scan_dir(@laundered_dir, @reg)

    direct = Enum.filter(findings, &(&1.kind == :direct_leak))
    hints = Enum.filter(findings, &(&1.kind == :laundered_hint))

    assert direct == [],
           "C3 must NOT flag laundered flows as direct leaks (they are the expected miss)"

    assert length(hints) >= 1,
           "C3 should emit a :laundered_hint advisory citing J2 for the laundered flow"
  end

  test "STEP 2 — J2 schema has NO string field for a laundered name to land in" do
    # The whole backstop: there is no free-string/binary/map field in the schema.
    for {name, type, _opts} <- Schema.canonical_fields() do
      assert Schema.bounded_type?(type),
             "field #{name} is #{type} — a laundered name could occupy a non-bounded field"
    end

    # And the check fails the build if someone adds one (the smuggle attempt).
    smuggle = Schema.canonical_fields() ++ [{:debug_actor, :string, []}]
    assert Schema.violations(smuggle) != [], "J2 must fail a string field added to smuggle a name"
  end

  test "STEP 3 — the laundered plaintext name is REJECTED at every wide-event field" do
    # The exact plaintext the laundered corpus leaks (a full name with a space).
    laundered_name = "Alice Anders"

    # It cannot occupy any bounded field:
    #   * an :opaque_id / :token field — rejected (has a space; not opaque).
    assert {:error, _} = WideEvent.new(action: :req, tenant_id: laundered_name)
    assert {:error, _} = WideEvent.new(action: :req, actor_id: laundered_name)
    #   * a :number field — rejected (not a number).
    assert {:error, _} = WideEvent.new(action: :req, row_count: laundered_name)
    #   * an unknown field named to look benign — rejected (not in the schema).
    assert {:error, _} = WideEvent.new(action: :req, subject_display_name: laundered_name)

    # There is literally no field it fits. The only free-shape entry is :action,
    # which requires an ATOM (a bounded label), never a free binary:
    assert {:error, _} = WideEvent.new(action: laundered_name)
  end

  test "STEP 4 — emit path re-validates: a struct-smuggled name is rejected at emit" do
    # Bypass new/1 by building the struct directly with a laundered name in a
    # bounded field (simulating a caller who dodged validation). emit/1
    # re-validates and refuses.
    ev = %WideEvent{action: :req, tenant_id: "Alice Anders"}
    assert {:error, reasons} = WideEvent.emit(ev)
    assert Enum.any?(reasons, &String.contains?(&1, "tenant_id"))
  end
end
