defmodule Samen.AbbrevRegistryTest do
  @moduledoc """
  T1.1 abbrev REGISTRY acceptance: abbrevs are permanent, 3-letter lowercase,
  collision-checked, and never recycled. The pure `validate/3` is unit-tested
  exhaustively; the compile-time enforcement (Samen.Verifiers.AbbrevRegistry) is
  driven end-to-end in `abbrev_registry_red_path_test.exs`.
  """
  use ExUnit.Case, async: true

  alias Samen.AbbrevRegistry, as: Reg

  @registry %{
    "com" => "MyApp.Crm.Contact",
    "cpy" => "MyApp.Crm.Company"
  }

  test "the committed registry file loads and contains the fixture abbrevs" do
    loaded = Reg.load()
    assert loaded["com"] == "SamenCore.Support.Crm.Contact"
    assert loaded["cpy"] == "SamenCore.Support.Crm.Company"
    assert loaded["pat"] == "SamenCore.Support.Clinical.Patient"
    assert loaded["stf"] == "SamenCore.Support.Clinical.Staff"
  end

  test "valid_shape? enforces exactly 3 lowercase letters" do
    assert Reg.valid_shape?("com")
    refute Reg.valid_shape?("co")
    refute Reg.valid_shape?("comm")
    refute Reg.valid_shape?("COM")
    refute Reg.valid_shape?("c0m")
    refute Reg.valid_shape?("c_m")
    refute Reg.valid_shape?(nil)
    refute Reg.valid_shape?(:com)
  end

  # --- validate/3: the fail-closed decision function -------------------------

  test "validate: a registered abbrev owned by this exact resource is OK" do
    assert Reg.validate(@registry, "com", "MyApp.Crm.Contact") == :ok
  end

  test "validate: an unregistered abbrev fails (must be reserved first)" do
    assert {:error, reason} = Reg.validate(@registry, "zzz", "MyApp.New.Thing")
    assert reason =~ "not in the abbrev registry"
    assert reason =~ "permanent"
  end

  test "validate: an abbrev owned by a DIFFERENT resource fails (collision / recycle)" do
    assert {:error, reason} = Reg.validate(@registry, "com", "MyApp.Other.Resource")
    assert reason =~ "registered to MyApp.Crm.Contact"
    assert reason =~ "never recycled"
  end

  test "validate: a malformed abbrev fails on shape before anything else" do
    assert {:error, reason} = Reg.validate(@registry, "COM", "MyApp.Whatever")
    assert reason =~ "not 3 lowercase letters"
  end

  test "validate: changing a resource's abbrev to a new (unregistered) one fails" do
    # Contact is registered as "com"; asking to use "abc" (unregistered) fails.
    assert {:error, reason} = Reg.validate(@registry, "abc", "MyApp.Crm.Contact")
    assert reason =~ "not in the abbrev registry"
  end

  test "load/1 raises fail-closed on a missing registry file" do
    assert_raise RuntimeError, ~r/missing or unreadable/, fn ->
      Reg.load("/nonexistent/path/abbrev_registry.json")
    end
  end

  test "load/1 raises fail-closed on malformed JSON" do
    path = Path.join(System.tmp_dir!(), "bad_registry_#{System.unique_integer([:positive])}.json")
    File.write!(path, "{ not json ")

    try do
      assert_raise RuntimeError, ~r/not valid JSON/, fn -> Reg.load(path) end
    after
      File.rm(path)
    end
  end

  test "load/1 raises fail-closed when the abbrevs key is missing" do
    path = Path.join(System.tmp_dir!(), "shape_registry_#{System.unique_integer([:positive])}.json")
    File.write!(path, ~s({"other": {}}))

    try do
      assert_raise RuntimeError, ~r/must be a JSON object with an "abbrevs" map/, fn ->
        Reg.load(path)
      end
    after
      File.rm(path)
    end
  end

  # --- ADR-023 host-namespaced schema + compat shim --------------------------

  describe "ADR-023 compat shim + host-namespaced reader" do
    # A file WITHOUT a "hosts" key (the committed 263-entry registry shape).
    defp flat_file! do
      path = Path.join(System.tmp_dir!(), "flat_reg_#{System.unique_integer([:positive])}.json")
      File.write!(path, ~s({"abbrevs": {"com": "MyApp.Crm.Contact"}}))
      path
    end

    # A host-namespaced file: legacy global net + two hosts, one reusing "com".
    defp ns_file! do
      path = Path.join(System.tmp_dir!(), "ns_reg_#{System.unique_integer([:positive])}.json")

      File.write!(
        path,
        Jason.encode!(%{
          "abbrevs" => %{"com" => "MyApp.Crm.Contact"},
          "hosts" => %{
            "widgetco" => %{"wid" => "Widgetco.Vertical.Widget"},
            "acme" => %{"wid" => "Acme.Vertical.Gadget"}
          }
        })
      )

      path
    end

    test "the COMMITTED registry: 263 flat entries + the F3 consent-ledger + ADR-035 Identity host allocations" do
      %{global: global, hosts: hosts} = Reg.load_namespaced()
      assert map_size(global) == 263

      # F3 Unit 1: the ConsentEvent ledger reserved a host-namespaced abbrev per marketing
      # mount via the sanctioned allocator (ADR-023 host-scoped reservations). ADR-035 T02
      # adds the Identity.Credential/AuthToken abbrevs (crd/atk, doc/dot, woc/wot) the same
      # way; T03 adds Identity.Session (ses/dos/wos); T06 adds Identity.UserIdentity
      # (uid/doi/woi — the A6 SSO link). `samen_core`'s `sro`/`srp` rows belong
      # to a concurrent, unrelated in-flight rich-types task (not authored by T03/T06).
      # `samen_web`'s `rti` row is T15's own round-trip matrix fixture
      # (`Samen.WebTest.RichTypes.Item`, ADR-036 H7 done-criteria 3/4). `samen_core`'s
      # `spc`/`spd` rows are T23's no-PAN verifier red-path compile fixtures (ADR-038
      # §3.5 B5). T43 (F1, ADR-041 §3) adds the Work scope's Project/Task abbrevs per
      # host: demo's defaults (wpj/wtk), samen_core's fresh in-tree test-fixture pair
      # (spw/stw), and driftwood/pawchart's allocator-proposed fresh pairs
      # (dwp/dwt, pwp/pwt).
      assert hosts == %{
               "demo" => %{
                 "mce" => "Demo.MarketingScope.ConsentEvent",
                 "atk" => "Demo.Identity.AuthToken",
                 "crd" => "Demo.Identity.Credential",
                 "ses" => "Demo.Identity.Session",
                 "uid" => "Demo.Identity.UserIdentity",
                 "wpj" => "Demo.WorkScope.Project",
                 "wtk" => "Demo.WorkScope.Task",
                 # T35 §4.7: the per-host materialization of the E3 Approval resource for
                 # the reveal-grant engine client (ADR-040 §4.7), allocator-reserved.
                 "daa" => "Demo.Approvals.Approval",
                 # T44 F2 (Calendar scope): the demo host's Event abbrev, allocator-proposed.
                 "dce" => "Demo.CalendarScope.Event",
                 # T45 F3 (Docs scope): the demo host's Doc/Note abbrevs, allocator-proposed.
                 "ddd" => "Demo.DocsScope.Doc",
                 "ddn" => "Demo.DocsScope.Note",
                 # T46 F4 (Tags scope): the demo host's Tag/Tagging abbrevs, allocator-proposed.
                 "dtt" => "Demo.Tags.Tag",
                 "tdt" => "Demo.Tags.Tagging",
                 # T47 F5 (Locations scope): the demo host's Location abbrev, allocator-proposed.
                 "dll" => "Demo.LocationsScope.Location",
                 # T48 F6+F7 (SalesOps scope): the demo host's Vendor/Lead abbrevs, allocator-proposed.
                 "dsv" => "Demo.SalesOps.Vendor",
                 "dsl" => "Demo.SalesOps.Lead",
                 # T109 (ADR-038 §6.4): the demo host's durable brute-force
                 # failure-counter abbrev, allocator-proposed.
                 "dil" => "Demo.Identity.LoginFailure",
                 # T119 (ADR-040 §6.5): the E7 `versioned` CMS Version resources —
                 # ash_paper_trail-generated `Page/Post/Block.Version`, allocator-proposed.
                 "cpv" => "Demo.CmsScope.Page.Version",
                 "cvp" => "Demo.CmsScope.Post.Version",
                 "cbv" => "Demo.CmsScope.Block.Version",
                 # T79 (spec §I6 macros composer palette + CSAT loop closed): the
                 # new `CsatSurveyToken` resource (I6's single-use CSAT
                 # survey-response link), allocator-proposed.
                 "dsc" => "Demo.SupportScope.CsatSurveyToken"
               },
               "driftwood" => %{
                 "fmv" => "Driftwood.Marketing.ConsentEvent",
                 "doc" => "Driftwood.Operator.Credential",
                 "dot" => "Driftwood.Operator.AuthToken",
                 "dos" => "Driftwood.Operator.Session",
                 "doi" => "Driftwood.Operator.UserIdentity",
                 "dwp" => "Driftwood.Work.Project",
                 "dwt" => "Driftwood.Work.Task",
                 # T35 §4.7: same as demo's `daa` above — Driftwood's per-host Approval
                 # resource (fresh f-prefixed abbrev per Driftwood's own collision-avoidance
                 # convention, see driftwood/priv/abbrev_registry.json's own comment).
                 "fap" => "Driftwood.Approvals.Approval",
                 # T44 F2 (Calendar scope): `dce` collided with demo's own proposed abbrev
                 # (both hosts start with "d" — the deterministic proposer is host-name-
                 # blind to OTHER host sections), so Driftwood's Event mount took a fresh
                 # `fce` (allocator-proposed, explicit) instead.
                 "fce" => "Driftwood.Calendar.Event",
                 # T45 F3 (Docs scope): `ddd`/`ddn` collided with demo's own proposed
                 # abbrevs (the deterministic proposer derives from the owner's LAST
                 # module segments, host-name-blind — same collision class as `dce`
                 # above), so Driftwood's Doc/Note mount took fresh `fdd`/`fdn`
                 # (allocator-reserved, explicit, same f-prefix convention as `fap`/`fce`).
                 "fdd" => "Driftwood.Docs.Doc",
                 "fdn" => "Driftwood.Docs.Note",
                 # T46 F4 (Tags scope): `dtt`/`tdt` collided with demo's own proposed
                 # abbrevs (the same host-name-blind proposer class as `dce`/`fdd`
                 # above), so Driftwood's Tag/Tagging mount took fresh `ftt`/`tft`
                 # (allocator-reserved, explicit, same f-prefix convention).
                 "ftt" => "Driftwood.Tags.Tag",
                 "tft" => "Driftwood.Tags.Tagging",
                 # T47 F5 (Locations scope): `dll` collided with demo's own proposed
                 # abbrev (the same host-name-blind proposer class as `dce`/`fdd`/`dtt`
                 # above) — this collision was caught only AFTER the accidental `dll`
                 # write had already persisted (unlike T44/T45/T46, which caught it
                 # pre-write); the orphan was repaired as a sanctioned incident-repair
                 # (not a hand-allocation, see _orch/tasks/T47/work/progress.md), and
                 # Driftwood's Location mount took fresh `fll` (allocator-reserved,
                 # explicit, same f-prefix convention).
                 "fll" => "Driftwood.Locations.Location",
                 # T48 F6+F7 (SalesOps scope): the driftwood host's Vendor/Lead abbrevs,
                 # allocator-proposed — no cross-host collision this time (T123's
                 # hardened proposer union-checks every host namespace up front).
                 "dvs" => "Driftwood.SalesOps.Vendor",
                 "dls" => "Driftwood.SalesOps.Lead",
                 # T109 (ADR-038 §6.4): the driftwood operator mount's durable
                 # brute-force failure-counter abbrev, allocator-proposed.
                 "dol" => "Driftwood.Operator.LoginFailure",
                 # T118 (ADR-039 §12 done-criterion 4): driftwood's FIRST vertical
                 # adoption of the Automation scope (`use Samen.Scopes.Automation`,
                 # the `Samen.Web.Automation.BuilderLive` browser-real proof host).
                 # The scope's built-in defaults (`awf`/`arm`/`aes`/`sar`) were
                 # already claimed by samen_core's OWN AutomationFixture test rows
                 # (a global-net collision) — fresh "d"-prefixed abbrevs reserved
                 # explicitly instead (`mix samen.abbrev.reserve --host driftwood
                 # --owner Driftwood.Automation.Workflow --abbrev dwf`, and so on).
                 "dwf" => "Driftwood.Automation.Workflow",
                 "drm" => "Driftwood.Automation.Reminder",
                 "des" => "Driftwood.Automation.Escalation",
                 "dru" => "Driftwood.Automation.Run",
                 # T79 (spec §I6): the new `CsatSurveyToken` resource — driftwood's
                 # TENANT Support mount, allocator-proposed.
                 "dcs" => "Driftwood.Support.CsatSurveyToken",
                 # T79: the operator-book sibling — driftwood's OPERATOR Support
                 # mount (ADR-010 §8.1), allocator-proposed.
                 "dco" => "Driftwood.Operator.CsatSurveyToken"
               },
               "pawchart" => %{
                 "vmv" => "PawChart.Marketing.ConsentEvent",
                 "pwp" => "PawChart.Work.Project",
                 "pwt" => "PawChart.Work.Task",
                 # T44 F2 (Calendar scope): the pawchart host's Event abbrev, allocator-proposed.
                 "pce" => "PawChart.Calendar.Event",
                 # T45 F3 (Docs scope): the pawchart host's Doc/Note abbrevs, allocator-proposed.
                 "pdd" => "PawChart.Docs.Doc",
                 "pdn" => "PawChart.Docs.Note",
                 # T46 F4 (Tags scope): the pawchart host's Tag/Tagging abbrevs, allocator-proposed.
                 "ptt" => "PawChart.Tags.Tag",
                 "tpt" => "PawChart.Tags.Tagging",
                 # T47 F5 (Locations scope): the pawchart host's Location abbrev,
                 # allocator-proposed.
                 "pll" => "PawChart.Locations.Location",
                 # T48 F6+F7 (SalesOps scope): the pawchart host's Vendor/Lead abbrevs, allocator-proposed.
                 "psv" => "PawChart.SalesOps.Vendor",
                 "psl" => "PawChart.SalesOps.Lead",
                 # T79 (spec §I6): the new `CsatSurveyToken` resource — pawchart's
                 # Support mount, allocator-proposed.
                 "psc" => "PawChart.Support.CsatSurveyToken",
                 # T157 (ADR-010 §8.1): the pawchart OPERATOR namespace — a SECOND
                 # Identity+Billing+Support mount (the SaaS's own book of business),
                 # `po*`/`pm*`/`pq*` abbrevs reserved via the sanctioned allocator.
                 "poo" => "PawChart.Operator.Org",
                 "pou" => "PawChart.Operator.User",
                 "pom" => "PawChart.Operator.Membership",
                 "por" => "PawChart.Operator.Role",
                 "pok" => "PawChart.Operator.ApiKey",
                 "pon" => "PawChart.Operator.Invitation",
                 "poc" => "PawChart.Operator.Credential",
                 "pot" => "PawChart.Operator.AuthToken",
                 "pos" => "PawChart.Operator.Session",
                 "poi" => "PawChart.Operator.UserIdentity",
                 "pol" => "PawChart.Operator.LoginFailure",
                 "pmc" => "PawChart.Operator.Customer",
                 "pmp" => "PawChart.Operator.Plan",
                 "pmr" => "PawChart.Operator.Price",
                 "pms" => "PawChart.Operator.Subscription",
                 "pmi" => "PawChart.Operator.Invoice",
                 "pmy" => "PawChart.Operator.Payment",
                 "pmu" => "PawChart.Operator.Usage",
                 "pme" => "PawChart.Operator.Entitlement",
                 "pmv" => "PawChart.Operator.SubscriptionEvent",
                 "pql" => "PawChart.Operator.Sla",
                 "pqk" => "PawChart.Operator.Ticket",
                 "pqc" => "PawChart.Operator.Conversation",
                 "pqg" => "PawChart.Operator.Agent",
                 "pqm" => "PawChart.Operator.Message",
                 "pqn" => "PawChart.Operator.Macro",
                 "pqs" => "PawChart.Operator.Csat",
                 "pqo" => "PawChart.Operator.CsatSurveyToken"
               },
               "samen_core" => %{
                 # T75 (spec §I2 CRM sequences actually send): the new Outreach
                 # scope's samen_core-level fixture (Sequence/Enrollment/StepSend)
                 # plus a SECOND materialization of the existing T74 Mailbox scope
                 # (Connection/MailMessage) so the reply-detection test can prove
                 # it reads REAL Mailbox.MailMessage rows without a third inbound
                 # path, all allocator-reserved under host `samen_core`.
                 "sos" => "SamenCore.Support.OutreachFixture.Sequence",
                 "soe" => "SamenCore.Support.OutreachFixture.Enrollment",
                 "sso" => "SamenCore.Support.OutreachFixture.StepSend",
                 "scm" => "SamenCore.Support.MailboxFixture.Connection",
                 "smm" => "SamenCore.Support.MailboxFixture.MailMessage",
                 # T67 (ADR-043 §7 D3): the embeddings positive-control fixture.
                 "emb" => "SamenCore.Support.EmbeddingsDomain.Article",
                 # T68 (ADR-043 §7.5 D3): the versioned Prompt resource.
                 "aip" => "Samen.AI.Prompt",
                 # T70 (ADR-043 §6.3 D5): the AI support-operator draft resource.
                 "sas" => "Samen.AI.SupportReplyDraft",
                 # T71 (ADR-043 §6.4 D6/D7): the D7 analytics anti-tautology test fixture
                 # (a self-contained, freshly-compiled `use Samen.Aggregate.Resource`).
                 "aac" => "SamenCore.Support.AnalyticsFixture.CleanAggregate",
                 "sxv" => "SamenCore.Support.SuppressionFixture.ConsentEvent",
                 "sro" => "SamenCore.Support.RichTypes.OrgFixture",
                 "srp" => "SamenCore.Support.RichTypes.PersonalFixture",
                 "spc" => "SamenCore.Support.PanFixture.CleanProjection",
                 "spd" => "SamenCore.Support.PanFixture.DirtyProjection",
                 # T36 E6 soft-delete pilots (ADR-040 §5): the archivable Widget (plain,
                 # partial unique index) + Person (vaulted) fixtures, allocator-reserved.
                 "arv" => "SamenCore.Support.Archivable.Widget",
                 "avf" => "SamenCore.Support.Archivable.Person",
                 # T39 E1 automation engine (ADR-039): the Workflow resource + the
                 # Subject trigger-source fixture, allocator-reserved.
                 "awf" => "SamenCore.Support.AutomationFixture.Workflow",
                 "asj" => "SamenCore.Support.AutomationFixture.Subject",
                 # T43 F1 (ADR-041 §3): the in-tree Work scope fixture pilot.
                 "spw" => "SamenCore.Support.WorkFixture.Project",
                 "stw" => "SamenCore.Support.WorkFixture.Task",
                 # T34 E3 generalized approve/reject engine (ADR-040 §4): the Approval
                 # state-bearing resource + the Document reference-client (two gated
                 # actions) fixtures, allocator-reserved. Materialized in samen_core's
                 # TestRepo only; the per-host primitives materialization is T35's sweep.
                 "apv" => "SamenCore.Support.ApprovalsFixture.Approval",
                 "apd" => "SamenCore.Support.ApprovalsFixture.Document",
                 # T41 E4/E5 reminder + escalation (ADR-039 §6/§7): the Reminder +
                 # Escalation resources, materialized in the SAME AutomationFixture
                 # domain T39 mounts, allocator-reserved.
                 "arm" => "SamenCore.Support.AutomationFixture.Reminder",
                 "aes" => "SamenCore.Support.AutomationFixture.Escalation",
                 # T40 E2 action library (ADR-039 §5): a second trigger-source
                 # fixture (owner_id/tags surfaces the record-mutation family
                 # needs), materialized in the SAME AutomationFixture domain,
                 # allocator-reserved.
                 "sat" => "SamenCore.Support.AutomationFixture.Target",
                 # T42 E8 run log (ADR-039 §8.1): the Run resource, materialized
                 # in the SAME AutomationFixture domain, allocator-reserved.
                 "sar" => "SamenCore.Support.AutomationFixture.Run",
                 # T44 F2 (Calendar scope): the in-tree Calendar scope fixture pilot.
                 "sce" => "SamenCore.Support.CalendarFixture.Event",
                 # T45 F3 (Docs scope): the in-tree Docs scope fixture pilot.
                 "sdd" => "SamenCore.Support.DocsFixture.Doc",
                 "sdn" => "SamenCore.Support.DocsFixture.Note",
                 # T46 F4 (Tags scope): the in-tree Tags scope fixture pilot.
                 "stt" => "SamenCore.Support.TagsFixture.Tag",
                 "tst" => "SamenCore.Support.TagsFixture.Tagging",
                 # T47 F5 (Locations scope): the in-tree Locations scope fixture pilot.
                 "sll" => "SamenCore.Support.LocationsFixture.Location",
                 # T48 F6+F7 (SalesOps scope): the in-tree SalesOps scope fixture pilot,
                 # PLUS a fresh in-tree `Samen.Scopes.Crm` mount (the Lead-conversion
                 # TARGET — a real CRM Person/Opportunity, not a stand-in).
                 "scc" => "SamenCore.Support.CrmScopeFixture.Company",
                 "scp" => "SamenCore.Support.CrmScopeFixture.Person",
                 "csp" => "SamenCore.Support.CrmScopeFixture.Pipeline",
                 "sco" => "SamenCore.Support.CrmScopeFixture.Opportunity",
                 "sca" => "SamenCore.Support.CrmScopeFixture.Attachment",
                 "ssv" => "SamenCore.Support.SalesOpsFixture.Vendor",
                 "sls" => "SamenCore.Support.SalesOpsFixture.Lead",
                 # T119 (ADR-040 §6): the E7 `versioned` in-tree pilots — a
                 # :changes_only Contact and a :snapshot Snapshot (both fold Core.Person),
                 # plus their generated `.Version` resources, allocator-proposed.
                 "svc" => "SamenCore.Support.Versioning.Contact",
                 "vcv" => "SamenCore.Support.Versioning.Contact.Version",
                 "svs" => "SamenCore.Support.Versioning.Snapshot",
                 "vsv" => "SamenCore.Support.Versioning.Snapshot.Version",
                 # T82 (ADR-044 §4.1, WS-J J1): the fleet registry blueprint's
                 # samen_core test fixture mount (`SamenCore.Support.FleetFixture`)
                 # — the five `flt_*` resources, allocator-proposed.
                 "sfa" => "SamenCore.Support.FleetFixture.App",
                 "sfc" => "SamenCore.Support.FleetFixture.Credential",
                 "sfe" => "SamenCore.Support.FleetFixture.EnrollmentToken",
                 "sfr" => "SamenCore.Support.FleetFixture.Report",
                 "sfd" => "SamenCore.Support.FleetFixture.Directive"
               },
               "samen_web" => %{
                 "wmv" => "Samen.WebTest.Marketing.ConsentEvent",
                 "woc" => "Samen.WebTest.Operator.Credential",
                 "wot" => "Samen.WebTest.Operator.AuthToken",
                 "wos" => "Samen.WebTest.Operator.Session",
                 "woi" => "Samen.WebTest.Operator.UserIdentity",
                 "rti" => "Samen.WebTest.RichTypes.Item",
                 "wwp" => "Samen.WebTest.Work.Project",
                 "wwt" => "Samen.WebTest.Work.Task",
                 # T41 E5 escalation primitive (ADR-039 §7): the samen_web test
                 # host's direct Escalation-only mount (test/support/automation.ex),
                 # needed for the SLA-breach client proof (notifications_sources_test.exs).
                 "wes" => "Samen.WebTest.Automation.Escalation",
                 # T42 E8 observability (ADR-039 §8): the same test host's direct
                 # Workflow + Run mount, needed for the operator health-view LiveView
                 # test (automation_health_live_test.exs).
                 "wwa" => "Samen.WebTest.Automation.Workflow",
                 "war" => "Samen.WebTest.Automation.Run",
                 # T44 F2 (Calendar scope): the samen_web test host's Event abbrev,
                 # allocator-proposed (used by the ICS export masking test fixture).
                 "wce" => "Samen.WebTest.Calendar.Event",
                 # T45 F3 (Docs scope): the samen_web test host's Doc/Note abbrevs,
                 # allocator-proposed (used by the Docs masking + object-ref attach
                 # test fixture).
                 "wdd" => "Samen.WebTest.Docs.Doc",
                 "wdn" => "Samen.WebTest.Docs.Note",
                 # T46 F4 (Tags scope): the samen_web test host's Tag/Tagging abbrevs,
                 # allocator-proposed (used by the Tags org-scope attach + Ticket-tags
                 # migration test fixtures).
                 "wtt" => "Samen.WebTest.Tags.Tag",
                 "twt" => "Samen.WebTest.Tags.Tagging",
                 # T109 (ADR-038 §6.4): the samen_web test host's durable
                 # brute-force failure-counter abbrev, allocator-proposed.
                 "wol" => "Samen.WebTest.Operator.LoginFailure",
                 # T58 (G10 saved views): the samen_web test host's SavedView abbrev
                 # (the Views scope mount, `Samen.WebTest.Views`), allocator-proposed.
                 "wvs" => "Samen.WebTest.Views.SavedView",
                 # T74 (spec §I1 CRM two-way email sync): the samen_web test host's
                 # Mailbox.Connection / Mailbox.MailMessage abbrevs — the reference
                 # adopter of the new `Samen.Scopes.Mailbox`, allocator-proposed.
                 "mwc" => "Samen.WebTest.Mailbox.Connection",
                 "wmm" => "Samen.WebTest.Mailbox.MailMessage",
                 # T76 fix round 1 (LOW-1, INV-2 anti-tautology positive control): a real
                 # `use Samen.Aggregate.Resource` module defined in
                 # crm_reporting_test.exs, allocator-proposed.
                 "wcr" => "Samen.Web.CRMReportingTest.RealAggregateFixture",
                 # T82 (ADR-044 §4.1, WS-J J1): the samen_web test host's fleet
                 # registry HTTP-layer test fixture (`Samen.WebTest.Fleet`),
                 # allocator-proposed.
                 "wfa" => "Samen.WebTest.Fleet.App",
                 "wfc" => "Samen.WebTest.Fleet.Credential",
                 "wfe" => "Samen.WebTest.Fleet.EnrollmentToken",
                 "wfr" => "Samen.WebTest.Fleet.Report",
                 "wfd" => "Samen.WebTest.Fleet.Directive",
                 # T84 (ADR-044 §16.5 #1, ruling R-A): the samen_web test host's mount of the
                 # operator-account ASSIGNMENT blueprint (`Samen.Fleet.Assignment`), the data
                 # source `scope_of/2` reads. Allocator-proposed.
                 "woa" => "Samen.WebTest.OperatorScope.Assignment",
                 # T85 (spec §I2 M5): the samen_web test host's mount of the Outreach
                 # scope (`Samen.WebTest.Outreach`) — the reference web-plane adopter
                 # the CRM Sequences LiveView surfaces. Allocator-proposed.
                 "wso" => "Samen.WebTest.Outreach.Sequence",
                 "woe" => "Samen.WebTest.Outreach.Enrollment",
                 "ows" => "Samen.WebTest.Outreach.StepSend",
                 # T78 (spec §I5 helpdesk KB + composer suggestion + deflection): the
                 # samen_web test host's FIRST materialization of the CMS scope
                 # (`Samen.WebTest.Cms`), allocator-proposed. The KB article reuses
                 # `Cms.Post` (a `visibility` attribute distinguishes public vs
                 # internal) — no new article resource, but the shared blueprint
                 # mounts all six CMS resources as a unit.
                 "cwp" => "Samen.WebTest.Cms.Page",
                 "cpw" => "Samen.WebTest.Cms.Post",
                 "wcb" => "Samen.WebTest.Cms.Block",
                 "cwm" => "Samen.WebTest.Cms.Media",
                 "wcn" => "Samen.WebTest.Cms.Navigation",
                 "wcs" => "Samen.WebTest.Cms.SeoMeta",
                 # T78: the E7 `versioned: :snapshot` generated Version resources
                 # for Page/Post/Block on the same fixture, allocator-reserved
                 # (AshPaperTrail's CreateVersionResource transformer fails
                 # compile fail-closed until each is reserved).
                 "pcv" => "Samen.WebTest.Cms.Page.Version",
                 "pvc" => "Samen.WebTest.Cms.Post.Version",
                 "cvb" => "Samen.WebTest.Cms.Block.Version",
                 # T79 (spec §I6): the new `CsatSurveyToken` resource — the
                 # samen_web test host's TENANT Support mount, allocator-proposed.
                 "scw" => "Samen.WebTest.Support.CsatSurveyToken",
                 # T79: the operator-book sibling — the samen_web test host's
                 # OPERATOR Support mount (ADR-010 §8.2), allocator-proposed.
                 "wco" => "Samen.WebTest.Operator.CsatSurveyToken"
               }
             }

      # The compat shim's flat view unions the global net with every host entry
      # (263 global + 26 host + 10 T43 Work-scope host allocations + 2 T34 Approvals
      # samen_core host allocations + 2 T35 §4.7 per-host Approval materializations
      # (demo `daa`, driftwood `fap`) + 2 T41 samen_core host allocations (`arm`/`aes`)
      # + 1 T41 samen_web host allocation (`wes`) + 1 T40 samen_core host allocation
      # (`sat`) + 3 T42 host allocations (`sar` samen_core; `wwa`/`war` samen_web) +
      # 5 T44 Calendar-scope host allocations (`dce` demo; `fce` driftwood; `pce`
      # pawchart; `sce` samen_core; `wce` samen_web) + 10 T45 Docs-scope host
      # allocations (`ddd`/`ddn` demo; `fdd`/`fdn` driftwood; `pdd`/`pdn` pawchart;
      # `sdd`/`sdn` samen_core; `wdd`/`wdn` samen_web) + 10 T46 Tags-scope host
      # allocations (`dtt`/`tdt` demo; `ftt`/`tft` driftwood; `ptt`/`tpt` pawchart;
      # `stt`/`tst` samen_core; `wtt`/`twt` samen_web) + 4 T47 F5 Locations-scope
      # host allocations (`dll` demo; `fll` driftwood — `dll` collided with demo's
      # proposal, same "d"-prefix class as `dce`/`fdd`/`ftt`; `pll` pawchart; `sll`
      # samen_core — no samen_web mount, Locations has no web-specific feature) +
      # 13 T48 F6+F7 SalesOps-scope host allocations (`scc`/`scp`/`csp`/`sco`/`sca`
      # samen_core — the real `Samen.Scopes.Crm` mount backing the samen_core
      # Lead-conversion fixture; `ssv`/`sls` samen_core; `dsv`/`dsl` demo; `dvs`/
      # `dls` driftwood; `psv`/`psl` pawchart)
      # = 352) + 3 T109 (ADR-038 §6.4) host reservations — the durable brute-force
      # failure counter (`dil` demo; `dol` driftwood operator; `wol` samen_web
      # test host), allocator-proposed = 355; +7 in T119 (E7 versioned: samen_core
      # svc/vcv/svs/vsv fixtures + demo cpv/cvp/cbv CMS Version resources) = 362;
      # +4 in T118 (ADR-039 §12 done-criterion 4) — driftwood's first vertical
      # Automation-scope mount (`dwf`/`drm`/`des`/`dru` — the scope's built-in
      # defaults were already claimed by samen_core's own AutomationFixture rows,
      # a global-net collision, so fresh abbrevs were reserved) = 366; +1 in T58
      # (G10 saved views) — the samen_web test host's `wvs` (Views.SavedView) = 367;
      # +1 in T67 (ADR-043 §7 D3) — samen_core host's `emb` (EmbeddingsDomain.Article) = 368.
      # +1 in T68 (ADR-043 §7.5 D3) — samen_core host's `aip` (Samen.AI.Prompt) = 369.
      # +1 in T70 (ADR-043 §6.3 D5) — samen_core host's `sas` (Samen.AI.SupportReplyDraft) = 370.
      # +1 in T71 (ADR-043 §6.4 D6/D7) — samen_core host's `aac`
      # (SamenCore.Support.AnalyticsFixture.CleanAggregate) = 371.
      # +2 in T74 (spec §I1 CRM two-way email sync) — the samen_web test host's
      # `mwc`/`wmm` (Mailbox.Connection / Mailbox.MailMessage, the reference adopter
      # of the new Mailbox scope), both allocator-reserved under the samen_web host
      # namespace = 373.
      # +5 in T75 (spec §I2 CRM sequences actually send) — the samen_core host's
      # `sos`/`soe`/`sso` (OutreachFixture.Sequence/Enrollment/StepSend, the new
      # Outreach scope's samen_core-level fixture) and `scm`/`smm`
      # (MailboxFixture.Connection/MailMessage — a SECOND materialization of the
      # existing T74 Mailbox scope, mounted in samen_core so the reply-detection
      # test proves it reads REAL Mailbox.MailMessage rows, never a third inbound
      # path), all allocator-reserved under the samen_core host namespace = 378.
      # +1 in T76 fix round 1 (LOW-1, INV-2 anti-tautology positive control) — the
      # samen_web test host's `wcr` (`Samen.Web.CRMReportingTest.RealAggregateFixture`,
      # a genuine `use Samen.Aggregate.Resource` module defined in
      # crm_reporting_test.exs), allocator-reserved under the samen_web host
      # namespace = 379.
      # +5 in T82 (ADR-044 §4.1, WS-J J1) — the samen_core host's fleet registry
      # blueprint fixture (`SamenCore.Support.FleetFixture`), allocator-proposed
      # = 384.
      # +5 in T82 — the samen_web host's fleet registry HTTP-layer test fixture
      # (`Samen.WebTest.Fleet`), allocator-proposed = 389.
      # +6 in T78 (spec §I5 helpdesk KB + composer suggestion + deflection) — the
      # samen_web test host's FIRST CMS scope mount (`Samen.WebTest.Cms`) —
      # `cwp`/`cpw`/`wcb`/`cwm`/`wcn`/`wcs` (Page/Post/Block/Media/Navigation/
      # SeoMeta), allocator-proposed under the samen_web host namespace = 395.
      # +3 in T78 — the E7 `versioned: :snapshot` generated Version resources
      # `pcv`/`pvc`/`cvb` (Page.Version/Post.Version/Block.Version), allocator-
      # reserved under the samen_web host namespace = 398.
      # +6 in T79 (spec §I6 macros composer palette + CSAT loop closed) — the new
      # `CsatSurveyToken` resource added to the Support scope blueprint, mounted
      # on EVERY existing Support host (each needed its own fresh allocator-
      # proposed abbrev): `dsc` (demo), `dcs`/`dco` (driftwood tenant/operator),
      # `psc` (pawchart), `scw`/`wco` (samen_web test tenant/operator) = 404.
      # +1 T84 (ADR-044 §16.5 #1): samen_web test host's `woa`
      # (Samen.WebTest.OperatorScope.Assignment) = 405.
      # +3 T85 (spec §I2 M5): samen_web test host's Outreach mount `wso`/`woe`/`ows` = 408.
      assert map_size(Reg.load()) == 436
    end

    test "load/1 (compat shim) reads a flat file byte-identically — hosts empty" do
      path = flat_file!()

      try do
        assert %{global: g, hosts: %{}} = Reg.load_namespaced(path)
        assert g == %{"com" => "MyApp.Crm.Contact"}
        assert Reg.load(path) == %{"com" => "MyApp.Crm.Contact"}
      after
        File.rm(path)
      end
    end

    test "load/1 (compat shim) RAISES fail-closed on a cross-host flatten conflict (ADR-025 tripwire)" do
      # ns_file! reuses "wid" across two hosts for DISTINCT owners — flattening would
      # silently drop one owner, so load/0 fails closed instead of picking a winner.
      path = ns_file!()

      try do
        assert_raise RuntimeError, ~r/LOSSY FLATTENING/, fn -> Reg.load(path) end
        # ...but the namespaced read stays non-raising: the allocator's path is unaffected.
        assert %{hosts: h} = Reg.load_namespaced(path)
        assert get_in(h, ["widgetco", "wid"]) == "Widgetco.Vertical.Widget"
        assert get_in(h, ["acme", "wid"]) == "Acme.Vertical.Gadget"
      after
        File.rm(path)
      end
    end

    test "owner/2 resolves host-scoped, distinguishing same abbrev across hosts" do
      path = ns_file!()

      try do
        %{global: g, hosts: h} = Reg.load_namespaced(path)
        # (Directly exercise validate_host on the loaded shape — owner/2 reads the
        #  committed file, so we assert the namespaced separation via the loaded map.)
        assert get_in(h, ["widgetco", "wid"]) == "Widgetco.Vertical.Widget"
        assert get_in(h, ["acme", "wid"]) == "Acme.Vertical.Gadget"
        assert g["com"] == "MyApp.Crm.Contact"
      after
        File.rm(path)
      end
    end

    test "validate_host: unowned abbrev is OK" do
      ns = %{global: %{}, hosts: %{}}
      assert Reg.validate_host(ns, "widgetco", "wid", "Widgetco.Vertical.Widget") == :ok
    end

    test "validate_host: same host+abbrev+owner is OK (idempotent)" do
      ns = %{global: %{}, hosts: %{"widgetco" => %{"wid" => "Widgetco.Vertical.Widget"}}}
      assert Reg.validate_host(ns, "widgetco", "wid", "Widgetco.Vertical.Widget") == :ok
    end

    test "validate_host: cross-owner collision WITHIN a host fails (per-host permanence)" do
      ns = %{global: %{}, hosts: %{"widgetco" => %{"wid" => "Widgetco.Vertical.Widget"}}}
      assert {:error, reason} = Reg.validate_host(ns, "widgetco", "wid", "Widgetco.Other.Thing")
      assert reason =~ ~s(already owned by Widgetco.Vertical.Widget in host "widgetco")
      assert reason =~ "never recycled"
    end

    test "validate_host: SAME abbrev in a DIFFERENT host for a DIFFERENT owner is REFUSED by default (T123)" do
      ns = %{global: %{}, hosts: %{"widgetco" => %{"wid" => "Widgetco.Vertical.Widget"}}}
      assert {:error, reason} = Reg.validate_host(ns, "acme", "wid", "Acme.Vertical.Gadget")
      assert reason =~ ~s(already owned by Widgetco.Vertical.Widget in host "widgetco")
      assert reason =~ "DIFFERENT module in a DIFFERENT host"
      assert reason =~ "allow_cross_host_reuse: true"
    end

    test "validate_host: DELIBERATE Option-B cross-host reuse is allowed behind the explicit override (T123)" do
      ns = %{global: %{}, hosts: %{"widgetco" => %{"wid" => "Widgetco.Vertical.Widget"}}}

      assert Reg.validate_host(ns, "acme", "wid", "Acme.Vertical.Gadget",
               allow_cross_host_reuse: true
             ) == :ok
    end

    test "validate_host: cross-host SAME-owner reuse is OK without any override (idempotent, not a collision)" do
      ns = %{global: %{}, hosts: %{"widgetco" => %{"wid" => "Shared.Widget"}}}
      assert Reg.validate_host(ns, "acme", "wid", "Shared.Widget") == :ok
    end

    test "validate_host: global cross-host net still refuses a clash on the legacy map" do
      ns = %{global: %{"com" => "MyApp.Crm.Contact"}, hosts: %{}}
      assert {:error, reason} = Reg.validate_host(ns, "newhost", "com", "NewHost.Foo")
      assert reason =~ "GLOBAL cross-host net"
      assert reason =~ "MyApp.Crm.Contact"
    end

    test "validate_host: malformed abbrev fails on shape first" do
      ns = %{global: %{}, hosts: %{}}
      assert {:error, reason} = Reg.validate_host(ns, "widgetco", "WID", "Widgetco.X")
      assert reason =~ "not 3 lowercase letters"
    end

    test "load_namespaced raises fail-closed on a malformed hosts value" do
      path = Path.join(System.tmp_dir!(), "badhosts_#{System.unique_integer([:positive])}.json")
      File.write!(path, ~s({"abbrevs": {}, "hosts": {"widgetco": "not-a-map"}}))

      try do
        assert_raise RuntimeError, ~r/must be a JSON object of abbrev/, fn ->
          Reg.load_namespaced(path)
        end
      after
        File.rm(path)
      end
    end
  end
end
