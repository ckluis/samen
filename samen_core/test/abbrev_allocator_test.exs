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

    test "SAME abbrev in a DIFFERENT host for a DIFFERENT owner is refused by default, allowed via explicit override (Option B namespacing, T123)" do
      path = scratch!()

      try do
        A.reserve!("widgetco", "wid", "Widgetco.Vertical.Widget", path)

        # T123: an accidental different-owner cross-host reservation is REFUSED by default
        # (it would persist the T47 orphan that trips flatten_conflicts/1 at compile).
        assert_raise ArgumentError, ~r/already owned by Widgetco.Vertical.Widget in host "widgetco".*DELIBERATE ADR-025 Option-B/s, fn ->
          A.reserve!("acme", "wid", "Acme.Vertical.Gadget", path)
        end

        # A DELIBERATE Option-B reuse is still possible behind the explicit override.
        A.reserve!("acme", "wid", "Acme.Vertical.Gadget", path, allow_cross_host_reuse: true)

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
      # compile fixtures, ADR-038 §3.5 B5) + 2 T36 samen_core host reservations
      # (`arv`/`avf` — the E6 soft-delete archivable pilots, ADR-040 §5) + 2 T39
      # samen_core host reservations (`awf`/`asj` — the E1 automation Workflow + the
      # Subject trigger-source fixture, ADR-039) + 10 T43 Work-scope host reservations
      # (F1, ADR-041 §3: demo wpj/wtk, samen_core spw/stw, driftwood dwp/dwt,
      # pawchart pwp/pwt, samen_web test-host wwp/wwt) + 2 T34 samen_core host
      # reservations (`apv`/`apd` — the E3 approve/reject engine's Approval state machine +
      # the Document Gate-client fixtures, ADR-040 §4) + 2 T35 §4.7 per-host Approval
      # materializations (demo `daa`, driftwood `fap` — reveal grants' engine client) +
      # 2 T41 samen_core host reservations (`arm`/`aes` — the E4 Reminder + E5
      # Escalation resources, ADR-039 §6/§7) + 1 T41 samen_web host reservation
      # (`wes` — the samen_web test host's direct Escalation-only mount,
      # `test/support/automation.ex`, needed for the SLA-breach client proof) +
      # 1 T40 samen_core host reservation (`sat` — the E2 action-library's
      # second trigger-source fixture, ADR-039 §5) + 3 T42 host reservations
      # (`sar` — the E1/E8 automation Run resource, samen_core; `wwa`/`war` —
      # the samen_web test host's direct Workflow + Run mount, ADR-039 §8) +
      # 5 T44 F2 Calendar-scope host reservations (`dce` demo; `fce` driftwood
      # — `dce` collided with demo's proposal since both host names start
      # with "d"; `pce` pawchart; `sce` samen_core; `wce` samen_web) +
      # 10 T45 F3 Docs-scope host reservations (`ddd`/`ddn` demo; `fdd`/`fdn`
      # driftwood — `ddd`/`ddn` collided with demo's proposal, same "d"-prefix
      # class as `dce`/`fce`; `pdd`/`pdn` pawchart; `sdd`/`sdn` samen_core;
      # `wdd`/`wdn` samen_web) + 10 T46 F4 Tags-scope host reservations
      # (`dtt`/`tdt` demo; `ftt`/`tft` driftwood — `dtt`/`tdt` collided with
      # demo's proposal, same "d"-prefix class as `dce`/`fce`/`ddd`/`fdd`;
      # `ptt`/`tpt` pawchart; `stt`/`tst` samen_core; `wtt`/`twt` samen_web) +
      # 4 T47 F5 Locations-scope host reservations (`dll` demo; `fll` driftwood
      # — `dll` collided with demo's proposal, same "d"-prefix class as
      # `dce`/`fdd`/`dtt`, caught only after the accidental `dll` write had
      # already persisted and repaired as a sanctioned incident-repair, see
      # _orch/tasks/T47/work/progress.md; `pll` pawchart; `sll` samen_core —
      # no samen_web mount) + 13 T48 F6+F7 SalesOps-scope host reservations
      # (`scc`/`scp`/`csp`/`sco`/`sca` samen_core — a real `Samen.Scopes.Crm`
      # mount for the samen_core kernel test fixture, the Lead-conversion
      # target; `ssv`/`sls` samen_core — the Vendor/Lead scope itself; `dsv`/
      # `dsl` demo; `dvs`/`dls` driftwood; `psv`/`psl` pawchart — no
      # cross-host collision this time, T123's hardened proposer union-checks
      # every host namespace before returning a candidate).
      # + 3 T109 (ADR-038 §6.4) host reservations (dil/dol/wol — the durable
      # brute-force failure counter, allocator-proposed) = 355 / grew the file
      # by 143 bytes.
      # +7 T119 (ADR-040 §6) host reservations: demo cpv/cvp/cbv (CMS Page/Post/Block
      # .Version) + samen_core svc/vcv/svs/vsv (the E7 versioned fixture pilots + their
      # .Version resources), allocator-proposed → 362, growing the file to 16_870 bytes.
      # +4 T118 (ADR-039 §12 done-criterion 4) host reservations: driftwood's first
      # Automation-scope mount (`dwf`/`drm`/`des`/`dru` — the scope's built-in
      # defaults were already claimed by samen_core's own AutomationFixture rows,
      # a global-net collision, so fresh abbrevs were reserved) → 366, growing the
      # file to 17_051 bytes.
      assert byte_size(committed) == 17_051
      assert map_size(R.load()) == 366
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
