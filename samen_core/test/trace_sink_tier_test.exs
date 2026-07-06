defmodule Samen.NoPlaintextPii.Tiers.TraceSinkTest do
  @moduledoc """
  T2.7 — the TraceSink tier folds the J2 wide-event/span schema check into the
  `no_plaintext_pii` oracle roster (doc §runs oracle block: "the trace/event sink
  schema … exposes ONLY … columns"). One schema, two entry points (the dedicated
  `mix samen.verify.sink_schema` task AND this oracle tier).
  """
  use ExUnit.Case, async: true

  alias Samen.NoPlaintextPii
  alias Samen.NoPlaintextPii.Context
  alias Samen.NoPlaintextPii.Tiers.TraceSink

  test "tier is registered in the default oracle roster" do
    assert TraceSink in NoPlaintextPii.default_tiers()
  end

  test "tier is CI-mode (a static schema assertion valid in every run, incl. post-shred)" do
    assert TraceSink.mode() == :ci
  end

  test "GREEN: the real declared schema produces no violation" do
    ctx = Context.build(resources: [], repo: nil)
    assert TraceSink.check(ctx) == []
  end

  test "the tier delegates to the SAME schema check the J2 mix task uses" do
    # If the schema is clean, both are empty; the tier is a thin fold over
    # Samen.WideEvent.Schema.violations/0 (proven clean elsewhere).
    assert Samen.WideEvent.Schema.violations() == []
    assert TraceSink.check(Context.build(resources: [], repo: nil)) == []
  end
end
