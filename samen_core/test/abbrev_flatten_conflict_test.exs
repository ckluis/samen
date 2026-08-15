defmodule Samen.AbbrevFlattenConflictTest do
  @moduledoc """
  ADR-025 F7 slice — the fail-closed **flatten-conflict tripwire** for the abbrev
  registry's flattened compat view (`Samen.AbbrevRegistry.load/0`).

  The flattened view is lossless ONLY while every abbrev resolves to exactly one owner
  across all namespaces. The day a real cross-host prefix reuse (or a host-vs-global owner
  disagreement) lands, flattening would silently drop/override an owner and the
  flattened-view verifier (`Samen.Verifiers.AbbrevRegistry`) would false-positive a
  collision on the shadowed resource. `flatten_conflicts/1` detects that condition and
  `load/0` raises (naming ADR-025) instead — turning the deferred partition's latent risk
  into a loud, self-enforcing gate. All fixtures are synthetic maps/paths — the committed
  `priv/abbrev_registry.json` is only ever READ, never written.
  """
  use ExUnit.Case, async: true

  alias Samen.AbbrevRegistry, as: Reg
  alias Samen.Abbrev.Allocator, as: Alloc

  # --- GREEN: the committed registry is lossless; load + allocator unaffected -----------

  describe "committed registry (zero conflicts)" do
    test "flatten_conflicts/1 reports NO conflict for the committed registry" do
      assert Reg.flatten_conflicts(Reg.load_namespaced()) == []
    end

    test "load/0 does not raise and returns the full lossless union (263 global + 176 host)" do
      flat = Reg.load()
      # + 3 T109 (ADR-038 §6.4) host reservations (dil/dol/wol — the durable
      # brute-force failure counter, allocator-proposed) = 355; +7 in T119 = 362;
      # +4 in T118 (driftwood's first Automation-scope mount: dwf/drm/des/dru) = 366.
      # +1 T58 (G10 saved views): samen_web test host's `wvs` (Views.SavedView) = 367.
      # +1 T67 (ADR-043 §7 D3): samen_core host's `emb` (EmbeddingsDomain.Article) = 368.
      # +1 T68 (ADR-043 §7.5 D3): samen_core host's `aip` (Samen.AI.Prompt) = 369.
      # +1 T70 (ADR-043 §6.3 D5): samen_core host's `sas` (Samen.AI.SupportReplyDraft) = 370.
      # +1 T71 (ADR-043 §6.4 D6/D7): samen_core host's `aac`
      # (SamenCore.Support.AnalyticsFixture.CleanAggregate, the D7 anti-tautology test
      # fixture) = 371.
      # +2 T74 (spec §I1): the samen_web test host's Mailbox scope mount — `mwc`
      # (Mailbox.Connection) and `wmm` (Mailbox.MailMessage) = 373.
      # +5 T75 (spec §I2): the samen_core host's Outreach scope fixture
      # (`sos`/`soe`/`sso`) plus a second samen_core Mailbox materialization
      # (`scm`/`smm`) = 378.
      # +1 T76 fix round 1 (LOW-1): the samen_web test host's `wcr`
      # (CRMReportingTest.RealAggregateFixture, the INV-2 anti-tautology positive
      # control) = 379.
      # +5 T82 (ADR-044 §4.1, WS-J J1): the samen_core host's fleet registry
      # fixture (`SamenCore.Support.FleetFixture`) — `sfa`/`sfc`/`sfe`/`sfr`/`sfd`
      # (App/Credential/EnrollmentToken/Report/Directive) = 384.
      # +5 T82: the samen_web host's fleet registry HTTP-layer test fixture
      # (`Samen.WebTest.Fleet`) — `wfa`/`wfc`/`wfe`/`wfr`/`wfd` = 389.
      # +6 T78 (spec §I5): the samen_web test host's first CMS scope mount
      # (`Samen.WebTest.Cms`) — `cwp`/`cpw`/`wcb`/`cwm`/`wcn`/`wcs`
      # (Page/Post/Block/Media/Navigation/SeoMeta) = 395. The KB article reuses
      # `Cms.Post` (no new article resource) — only the six base CMS resources
      # needed a first-ever reservation for the samen_web test host.
      # +3 T78: the E7 `versioned: :snapshot` generated Version resources —
      # `pcv`/`pvc`/`cvb` (Page.Version/Post.Version/Block.Version) = 398.
      # +6 T79 (spec §I6): the new `CsatSurveyToken` resource mounted on every
      # existing Support host — `dsc`/`dcs`/`dco`/`psc`/`scw`/`wco` (demo,
      # driftwood tenant+operator, pawchart, samen_web test tenant+operator) = 404.
      # +1 T84 (ADR-044 §16.5 #1): samen_web test host's `woa`
      # (Samen.WebTest.OperatorScope.Assignment) = 405.
      # +3 T85 (spec §I2 M5): the samen_web test host's Outreach scope mount
      # (`Samen.WebTest.Outreach`) — `wso`/`woe`/`ows`
      # (Sequence/Enrollment/StepSend), the reference web-plane adopter surfaced by
      # the CRM Sequences LiveView = 408.
      # +2 A1 (ADR-047 §4.1/§6): samen_core host's agent-loop cursor pair `arn`/`atn`
      # (Samen.AI.Agent.{Run,Turn}) = 410.
      assert map_size(flat) == 439
      # A global entry and a host entry both survive the (lossless) flatten.
      assert flat["com"] == "SamenCore.Support.Crm.Contact"
      assert flat["mce"] == "Demo.MarketingScope.ConsentEvent"
    end

    test "the allocator can still reserve a fresh non-conflicting abbrev (tripwire is flatten-only)" do
      path = Path.join(System.tmp_dir!(), "tripwire_scratch_#{System.unique_integer([:positive])}.json")
      File.cp!(Reg.path(), path)

      try do
        # propose/reserve read the NAMESPACED shape, never the flattened view — unaffected.
        assert {:ok, abbrev} = Alloc.propose("widgetco", "Widgetco.Vertical.Sprocket", Reg.load_namespaced(path))
        assert :ok = Alloc.reserve!("widgetco", abbrev, "Widgetco.Vertical.Sprocket", path)

        # The scratch now has a host entry but STILL zero flatten-conflicts (distinct abbrev),
        # so its flattened load also stays clean.
        assert Reg.flatten_conflicts(Reg.load_namespaced(path)) == []
        assert get_in(Reg.load_namespaced(path), [:hosts, "widgetco", abbrev]) == "Widgetco.Vertical.Sprocket"
        refute_raise(fn -> Reg.load(path) end)
      after
        File.rm(path)
      end
    end
  end

  # --- RED: the tripwire fires on a lossy flattening ------------------------------------

  describe "cross-host reuse (case a)" do
    @cross_host %{
      global: %{"com" => "MyApp.Crm.Contact"},
      hosts: %{
        "widgetco" => %{"wid" => "Widgetco.Vertical.Widget"},
        "acme" => %{"wid" => "Acme.Vertical.Gadget"}
      }
    }

    test "flatten_conflicts/1 reports the shadowed abbrev with its competing owners" do
      assert [%{abbrev: "wid", owners: owners}] = Reg.flatten_conflicts(@cross_host)

      assert owners == [
               {"acme", "Acme.Vertical.Gadget"},
               {"widgetco", "Widgetco.Vertical.Widget"}
             ]
    end

    test "load/1 RAISES fail-closed with a message naming ADR-025" do
      path = write!(@cross_host)

      try do
        err = assert_raise RuntimeError, fn -> Reg.load(path) end
        assert err.message =~ "LOSSY FLATTENING"
        assert err.message =~ "025-abbrev-verifier-host-partition-followon"
        assert err.message =~ "validate_host/4"
        assert err.message =~ "wid"
      after
        File.rm(path)
      end
    end
  end

  describe "host-vs-global owner mismatch (case b)" do
    @host_global_mismatch %{
      global: %{"com" => "MyApp.Crm.Contact"},
      hosts: %{"widgetco" => %{"com" => "Widgetco.Vertical.Impostor"}}
    }

    test "flatten_conflicts/1 reports the host owner disagreeing with the global net" do
      assert [%{abbrev: "com", owners: owners}] = Reg.flatten_conflicts(@host_global_mismatch)

      assert owners == [
               {:global, "MyApp.Crm.Contact"},
               {"widgetco", "Widgetco.Vertical.Impostor"}
             ]
    end

    test "load/1 RAISES fail-closed" do
      path = write!(@host_global_mismatch)

      try do
        assert_raise RuntimeError, ~r/LOSSY FLATTENING/, fn -> Reg.load(path) end
      after
        File.rm(path)
      end
    end
  end

  # --- Positive control / anti-tautology: remove the conflict, no raise -----------------

  describe "positive control (same registry minus the conflict)" do
    test "a same-abbrev reuse with the SAME owner is NOT a conflict (lossless)" do
      ns = %{
        global: %{},
        hosts: %{
          "widgetco" => %{"wid" => "Shared.Widget"},
          "acme" => %{"wid" => "Shared.Widget"}
        }
      }

      assert Reg.flatten_conflicts(ns) == []
    end

    test "distinct abbrevs per host flatten cleanly and load/1 does NOT raise" do
      ns = %{
        global: %{"com" => "MyApp.Crm.Contact"},
        hosts: %{
          "widgetco" => %{"wid" => "Widgetco.Vertical.Widget"},
          "acme" => %{"gad" => "Acme.Vertical.Gadget"}
        }
      }

      assert Reg.flatten_conflicts(ns) == []

      path = write!(ns)

      try do
        flat = Reg.load(path)
        assert flat["com"] == "MyApp.Crm.Contact"
        assert flat["wid"] == "Widgetco.Vertical.Widget"
        assert flat["gad"] == "Acme.Vertical.Gadget"
      after
        File.rm(path)
      end
    end
  end

  # --- helpers --------------------------------------------------------------------------

  defp write!(%{global: global, hosts: hosts}) do
    path = Path.join(System.tmp_dir!(), "flatten_conflict_#{System.unique_integer([:positive])}.json")
    File.write!(path, Jason.encode!(%{"abbrevs" => global, "hosts" => hosts}))
    path
  end

  defp refute_raise(fun) do
    fun.()
    :ok
  rescue
    e -> flunk("expected no raise, got: #{Exception.message(e)}")
  end
end
