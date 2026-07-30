defmodule Samen.Abbrev.AllocatorCrossHostTest do
  @moduledoc """
  T123 (ADR-023 forward-looking auto-picker hardening; ADR-025 tripwire it defends) —
  the RED-PATH that `Samen.Abbrev.Allocator.propose/3` can never auto-propose a
  **cross-host collision**: an abbrev already owned by a DIFFERENT host for a DIFFERENT
  module.

  ## The incident this pins (why this file exists)

  `propose/3` was host-*blind* through T47: its `free?` closure inspected only the
  *calling* host's own namespace + the legacy flat global map, never any OTHER host's
  namespace. So `propose(host, owner)` could hand back an abbrev already reserved by a
  different host for an unrelated resource. It bit four tasks this Phase-3 run:

    * **T44/T45/T46** — caught *pre-write* by the builder eyeballing the registry (luck,
      not a mechanism): `dce`/`fce`, `ddd`/`ddn`→`fdd`/`fdn`, `ddd`/`ddn`.
    * **T47** — caught *post-write*: `propose` handed back `dll` for
      `driftwood`/`Driftwood.Locations.Location` while `demo` already owned
      `hosts.demo.dll → Demo.LocationsScope.Location`. `reserve!/4` persisted it (its
      `validate_host/4` guard is host-scoped by design — the deliberate Option B door),
      and the orphan `hosts.driftwood.dll` tripped
      `Samen.AbbrevRegistry.flatten_conflicts/1`'s fail-closed **"LOSSY FLATTENING"**
      raise — which fires inside `Samen.Resource.validate_registry!/2`, i.e. at EVERY
      `use Samen.Resource` call site — breaking the whole `samen_core` compile, not just
      Location.

  T123 closes BOTH paths:

    * **auto-picker (attempt 1):** `propose/3`'s `free?` walks the UNION of every host
      namespace + the global net (`owners_of/2`), rejecting any candidate owned by a
      different module ANYWHERE and falling through to the next deterministic candidate.
    * **persistence (attempt 2):** `reserve!/5` → `AbbrevRegistry.validate_host/5` now runs
      the SAME all-host different-owner check (`cross_host_conflict/4`) so an EXPLICIT
      abbrev that bypasses `propose/3` (e.g. `mix samen.abbrev.reserve --abbrev`) can no
      longer PERSIST an accidental cross-host collision either — it is refused at WRITE
      time. A *deliberate* ADR-025 Option-B reuse stays possible, but ONLY behind the
      explicit `allow_cross_host_reuse: true` override (which then trips
      `flatten_conflicts/1` at load — the ADR-025 signal to build the verifier
      host-partition, NOT this task).

  This task does NOT retroactively rewrite any registry row. All fixtures are synthetic
  maps / scratch files fully cleaned up — the committed `priv/abbrev_registry.json` is
  never read or written here.

  Sabotages:
    * `scripts/sabotages/38-t123-abbrev-propose-cross-host-collision.patch` — reverts
      `propose/3`'s `free?` to the host-blind shape (the auto-picker red-paths flip).
    * `scripts/sabotages/39-t123-abbrev-validate-host-cross-host-collision.patch` — neuters
      `validate_host/5`'s `cross_host_conflict/4` (the persistence red-paths flip).
  """
  use ExUnit.Case, async: true

  alias Samen.Abbrev.Allocator, as: Alloc
  alias Samen.AbbrevRegistry, as: Reg

  # `Xeno.Yaml.Zeta`'s deterministic seed (first letters of the last three name
  # segments) is exactly "xyz" — so "xyz" is the FIRST candidate propose/3 tries for it.
  # `Bravo.Widget.Gizmo` is an unrelated module (seed "bwg") that pre-owns "xyz" in a
  # DIFFERENT host, standing in for the T47 `demo`-owns-`dll` state.
  @owner_a "Xeno.Yaml.Zeta"
  @owner_b "Bravo.Widget.Gizmo"

  # Host B already owns "xyz" for a DIFFERENT module. Host A's own namespace is empty.
  @cross_host %{global: %{}, hosts: %{"B" => %{"xyz" => @owner_b}}}

  describe "propose/3 never auto-proposes a cross-host collision (T123)" do
    test "GREEN (post-fix): propose for host A skips host B's \"xyz\" and picks a fresh abbrev" do
      assert {:ok, abbrev} = Alloc.propose("A", @owner_a, @cross_host)

      refute abbrev == "xyz",
             "propose auto-handed back \"xyz\" — already owned by host B for #{@owner_b}. " <>
               "This is the T47 cross-host collision; the all-host union check must skip it."

      assert Reg.valid_shape?(abbrev)
      # The abbrev it DID pick is genuinely free everywhere (not owned by any other module).
      assert Alloc.propose("A", @owner_a, @cross_host) == {:ok, abbrev}, "still deterministic"
    end

    test "ANTI-TAUTOLOGY: the pre-T123 host-blind check WOULD have returned the colliding \"xyz\"" do
      owner = @owner_a

      # (1) "xyz" really is @owner_a's deterministic FIRST candidate: in an empty
      # registry propose picks exactly it. So whatever the free? check ACCEPTS first,
      # if it accepts "xyz", "xyz" is what propose returns.
      assert {:ok, "xyz"} = Alloc.propose("A", owner, %{global: %{}, hosts: %{}}),
             "expected \"xyz\" to be #{owner}'s deterministic seed / first candidate"

      # (2) The EXACT pre-T123 host-blind free? logic (calling host's own namespace +
      # global ONLY — byte-for-byte the shape that shipped through T47; see
      # old_host_blind_free?/5 below). It never looked at host B, which owns "xyz".
      # Prove it ACCEPTS the colliding candidate:
      assert old_host_blind_free?(@cross_host.hosts, "A", @cross_host.global, owner, "xyz"),
             "the pre-T123 check must ACCEPT the cross-host-owned \"xyz\" (that is the bug) — " <>
               "combined with (1), the old propose WOULD have returned {:ok, \"xyz\"}, the collision"

      # (3) The REAL, fixed propose/3 REJECTS it — proving the new all-host union check is
      # a genuine discriminator, not a vacuous assertion.
      assert {:ok, fixed} = Alloc.propose("A", owner, @cross_host)
      refute fixed == "xyz"
    end
  end

  describe "same-owner is never rejected by the union check (idempotency preserved)" do
    test "own-host SAME-owner re-propose returns the existing abbrev unchanged" do
      owner = @owner_a
      ns = %{global: %{}, hosts: %{"A" => %{"xyz" => owner}}}
      # Host A already owns "xyz" for this exact module → idempotent re-propose returns it.
      assert {:ok, "xyz"} = Alloc.propose("A", owner, ns)
    end

    test "cross-host SAME-owner is NOT a collision: propose returns the shared abbrev (pinned)" do
      owner = @owner_a
      # Host B holds "xyz" for the SAME module we're proposing for in host A. The union
      # check rejects only DIFFERENT-owner holders, so "xyz" is still free for this owner
      # — propose returns it (this is the deliberate, pinned semantics; a different owner
      # in host B would instead be skipped, per the GREEN test above).
      ns = %{global: %{}, hosts: %{"B" => %{"xyz" => owner}}}
      assert {:ok, "xyz"} = Alloc.propose("A", owner, ns)
    end
  end

  describe "the union covers all three sources (host-self, other-host, global)" do
    test "a different owner in ANOTHER host is skipped" do
      assert {:ok, a} = Alloc.propose("A", @owner_a, %{global: %{}, hosts: %{"B" => %{"xyz" => @owner_b}}})
      refute a == "xyz"
    end

    test "a different owner in the CALLING host is skipped (unchanged legacy behavior)" do
      assert {:ok, a} = Alloc.propose("A", @owner_a, %{global: %{}, hosts: %{"A" => %{"xyz" => @owner_b}}})
      refute a == "xyz"
    end

    test "a different owner in the GLOBAL net is skipped (unchanged legacy behavior)" do
      assert {:ok, a} = Alloc.propose("A", @owner_a, %{global: %{"xyz" => @owner_b}, hosts: %{}})
      refute a == "xyz"
    end
  end

  # === Persistence path (attempt 2): reserve!/validate_host refuse an ACCIDENTAL =========
  # === cross-host collision by DEFAULT; deliberate Option-B only behind the override. ====

  describe "reserve!/validate_host: cross-host collision refused by default (T123)" do
    test "reserve! for host A of host B's abbrev for a DIFFERENT module is REFUSED, nothing persisted" do
      # Scratch registry where host B owns "xyz" for a DIFFERENT module (the T47 setup).
      path = scratch_ns!(%{"B" => %{"xyz" => @owner_b}})

      try do
        before = File.read!(path)

        assert_raise ArgumentError, ~r/already owned by #{@owner_b} in host "B".*allow_cross_host_reuse/s, fn ->
          Alloc.reserve!("A", "xyz", @owner_a, path)
        end

        # NOTHING persisted — byte-exact, so the T47 orphan (hosts.A.xyz vs hosts.B.xyz)
        # never exists …
        assert File.read!(path) == before
        # … and load/0 therefore stays clean: the LOSSY FLATTENING build-break is
        # PREVENTED at write time, not merely detected later at compile.
        assert Reg.flatten_conflicts(Reg.load_namespaced(path)) == []
        assert Reg.load(path)
      after
        File.rm(path)
      end
    end

    test "override allow_cross_host_reuse persists the same reserve! and load/0 then raises (anti-tautology)" do
      path = scratch_ns!(%{"B" => %{"xyz" => @owner_b}})

      try do
        # The override flips refusal into a persisted write — proving the default refusal
        # is load-bearing (not vacuous): same call, one flag, opposite outcome.
        assert :ok = Alloc.reserve!("A", "xyz", @owner_a, path, allow_cross_host_reuse: true)

        %{hosts: h} = Reg.load_namespaced(path)
        assert get_in(h, ["A", "xyz"]) == @owner_a
        assert get_in(h, ["B", "xyz"]) == @owner_b

        # A DELIBERATE different-owner cross-host reuse IS a lossy flatten — this is exactly
        # the T47 build-break, now reachable ONLY via the explicit human opt-in, which is
        # the ADR-025 trigger to implement the verifier host-partition.
        assert [%{abbrev: "xyz"}] = Reg.flatten_conflicts(Reg.load_namespaced(path))
        assert_raise RuntimeError, ~r/LOSSY FLATTENING/, fn -> Reg.load(path) end
      after
        File.rm(path)
      end
    end

    test "same-owner reserve preserved: own-host no-op, cross-host ok without override" do
      # (a) own-host same-owner re-reserve is a byte no-op.
      path = scratch_ns!(%{})

      try do
        Alloc.reserve!("A", "abc", @owner_a, path)
        bytes1 = File.read!(path)
        Alloc.reserve!("A", "abc", @owner_a, path)
        assert File.read!(path) == bytes1

        # (b) cross-host SAME-owner reserve is NOT a collision → succeeds WITHOUT override,
        # and stays lossless (same owner across two hosts is not a flatten-conflict).
        path2 = scratch_ns!(%{"B" => %{"xyz" => @owner_a}})

        try do
          assert :ok = Alloc.reserve!("A", "xyz", @owner_a, path2)
          assert Reg.flatten_conflicts(Reg.load_namespaced(path2)) == []
          assert Reg.load(path2)
        after
          File.rm(path2)
        end
      after
        File.rm(path)
      end
    end

    test "validate_host/5: default REFUSES other-host different owner; override + same-owner ok" do
      ns = %{global: %{}, hosts: %{"B" => %{"xyz" => @owner_b}}}

      assert {:error, reason} = Reg.validate_host(ns, "A", "xyz", @owner_a)
      assert reason =~ ~s(in host "B")
      assert Reg.validate_host(ns, "A", "xyz", @owner_a, allow_cross_host_reuse: true) == :ok

      same = %{global: %{}, hosts: %{"B" => %{"xyz" => @owner_a}}}
      assert Reg.validate_host(same, "A", "xyz", @owner_a) == :ok
    end
  end

  # A hermetic scratch registry file with the given `hosts` map (and an empty global),
  # fully cleaned up by each test. The committed registry is never touched.
  defp scratch_ns!(hosts) when is_map(hosts) do
    path = Path.join(System.tmp_dir!(), "alloc_xh_#{System.unique_integer([:positive])}.json")
    File.write!(path, Jason.encode!(%{"abbrevs" => %{}, "hosts" => hosts}))
    path
  end

  # The EXACT pre-T123 host-blind `free?` logic, extracted as a named helper (taking the
  # namespaces as PARAMETERS, so the type checker sees generic maps rather than the
  # narrowed empty-map literals) so the anti-tautology proof reproduces the real bug
  # faithfully: it consults ONLY the calling host's own namespace + the legacy global
  # map, never any OTHER host's namespace.
  defp old_host_blind_free?(hosts, host, global, owner, abbrev) do
    host_ns = Map.get(hosts, host, %{})

    case {Map.get(host_ns, abbrev), Map.get(global, abbrev)} do
      {nil, nil} -> true
      {^owner, _} -> true
      {nil, ^owner} -> true
      _ -> false
    end
  end
end
