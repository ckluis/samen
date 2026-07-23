defmodule Samen.Abbrev.AllocatorTest do
  @moduledoc """
  WS-D D8 (ADR-023): the abbrev ALLOCATOR (`mix samen.abbrev.reserve` engine). Proves the
  load-bearing guarantees + red-paths:

    * idempotent (same host+abbrev+owner = byte no-op);
    * fail-closed on cross-owner collision WITHIN a host namespace (ADR-006 one-owner-forever,
      made host-scoped);
    * fail-closed on the GLOBAL cross-host collision net (two hosts on shared infra can't clash);
    * SAME abbrev in a DIFFERENT host is allowed (Option B namespacing);
    * `propose/3` is deterministic + collision-free;
    * the COMMITTED registry is never touched — every write targets a scratch copy.

  Hermetic: a temp scratch registry copy per test; the committed
  `samen_core/priv/abbrev_registry.json` is byte-untouched (asserted).
  """
  use ExUnit.Case, async: true

  alias Samen.Abbrev.Allocator, as: A
  alias Samen.AbbrevRegistry, as: R

  # A scratch COPY of the committed registry — never the committed file itself.
  defp scratch! do
    path = Path.join(System.tmp_dir!(), "alloc_scratch_#{System.unique_integer([:positive])}.json")
    File.cp!(R.path(), path)
    path
  end

  # A minimal hermetic scratch registry (no committed data) for pure namespacing tests.
  defp mini_scratch!(json) do
    path = Path.join(System.tmp_dir!(), "alloc_mini_#{System.unique_integer([:positive])}.json")
    File.write!(path, json)
    path
  end

  describe "reserve!/4 — permanence + namespacing" do
    test "reserves into the HOST namespace, leaving the global net byte-untouched" do
      path = scratch!()

      try do
        A.reserve!("widgetco", "wid", "Widgetco.Vertical.Widget", path)
        %{global: g, hosts: h} = R.load_namespaced(path)

        assert get_in(h, ["widgetco", "wid"]) == "Widgetco.Vertical.Widget"
        # global net unchanged (still the committed 263 rows).
        assert map_size(g) == 263
      after
        File.rm(path)
      end
    end

    test "is idempotent: same host+abbrev+owner is a byte no-op" do
      path = scratch!()

      try do
        A.reserve!("widgetco", "wid", "Widgetco.Vertical.Widget", path)
        bytes1 = File.read!(path)
        A.reserve!("widgetco", "wid", "Widgetco.Vertical.Widget", path)
        bytes2 = File.read!(path)
        assert bytes1 == bytes2
      after
        File.rm(path)
      end
    end

    test "refuses a cross-owner collision WITHIN a host (per-host permanence)" do
      path = scratch!()

      try do
        A.reserve!("widgetco", "wid", "Widgetco.Vertical.Widget", path)

        assert_raise ArgumentError, ~r/already owned by Widgetco.Vertical.Widget in host/, fn ->
          A.reserve!("widgetco", "wid", "Widgetco.Other.Thing", path)
        end
      after
        File.rm(path)
      end
    end

    test "allows the SAME abbrev in a DIFFERENT host (Option B namespacing)" do
      path = scratch!()

      try do
        A.reserve!("widgetco", "wid", "Widgetco.Vertical.Widget", path)
        A.reserve!("acme", "wid", "Acme.Vertical.Gadget", path)

        %{hosts: h} = R.load_namespaced(path)
        assert get_in(h, ["widgetco", "wid"]) == "Widgetco.Vertical.Widget"
        assert get_in(h, ["acme", "wid"]) == "Acme.Vertical.Gadget"
      after
        File.rm(path)
      end
    end

    test "refuses a clash on the GLOBAL cross-host net (shared-infra safety)" do
      # "com" is owned in the committed global map (SamenCore.Support.Crm.Contact).
      path = scratch!()

      try do
        assert_raise ArgumentError, ~r/GLOBAL cross-host net/, fn ->
          A.reserve!("newhost", "com", "NewHost.Foo", path)
        end
      after
        File.rm(path)
      end
    end

    test "refuses a malformed abbrev (shape) before writing" do
      path = mini_scratch!(~s({"abbrevs": {}}))

      try do
        assert_raise ArgumentError, ~r/not 3 lowercase letters/, fn ->
          A.reserve!("widgetco", "WID", "Widgetco.X", path)
        end
      after
        File.rm(path)
      end
    end

    test "the COMMITTED registry is byte-untouched after all scratch reservations" do
      committed = File.read!(R.path())
      # 263 flat entries + the 5 F3 host-namespaced ConsentEvent reservations (ADR-023) +
      # the 6 ADR-035 T02 Identity.Credential/AuthToken host reservations + the 3 ADR-035
      # T03 Identity.Session host reservations + the 3 ADR-035 T06
      # Identity.UserIdentity host reservations + 3 concurrent, unrelated in-flight
      # rich-types fixture reservations (2 samen_core, not authored by T02/T03/T06; 1
      # samen_web — T15's own `rti` round-trip matrix fixture, ADR-036 H7) + 2 T23
      # samen_core host reservations (`spc`/`spd` — the no-PAN verifier's red-path
      # compile fixtures, ADR-038 §3.5 B5).
      assert byte_size(committed) == 13_293
      assert map_size(R.load()) == 285
    end
  end

  describe "propose/3 — deterministic, collision-free" do
    test "proposes the same abbrev on repeated calls (deterministic)" do
      ns = %{global: %{}, hosts: %{}}
      assert {:ok, a} = A.propose("widgetco", "Widgetco.Vertical.Sprocket", ns)
      assert {:ok, ^a} = A.propose("widgetco", "Widgetco.Vertical.Sprocket", ns)
      assert R.valid_shape?(a)
    end

    test "avoids an abbrev already owned in the host namespace" do
      # Seed the deterministic pick for this owner, then prove propose walks past it.
      seed_ns = %{global: %{}, hosts: %{}}
      {:ok, first} = A.propose("widgetco", "Widgetco.Vertical.Widget", seed_ns)

      taken_ns = %{global: %{}, hosts: %{"widgetco" => %{first => "Widgetco.Other.Owner"}}}
      assert {:ok, second} = A.propose("widgetco", "Widgetco.Vertical.Widget", taken_ns)
      refute second == first
      assert R.valid_shape?(second)
    end

    test "avoids an abbrev owned in the GLOBAL net even if the host slot is free" do
      {:ok, first} = A.propose("widgetco", "Widgetco.Vertical.Widget", %{global: %{}, hosts: %{}})

      taken_ns = %{global: %{first => "SomeOther.Global.Owner"}, hosts: %{}}
      assert {:ok, second} = A.propose("widgetco", "Widgetco.Vertical.Widget", taken_ns)
      refute second == first
    end

    test "an owner already holding an abbrev in the host is proposed that same abbrev (idempotent)" do
      {:ok, first} = A.propose("widgetco", "Widgetco.Vertical.Widget", %{global: %{}, hosts: %{}})

      owns_ns = %{global: %{}, hosts: %{"widgetco" => %{first => "Widgetco.Vertical.Widget"}}}
      assert {:ok, ^first} = A.propose("widgetco", "Widgetco.Vertical.Widget", owns_ns)
    end
  end
end
