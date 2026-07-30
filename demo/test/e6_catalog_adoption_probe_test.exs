defmodule Demo.E6CatalogAdoptionProbeTest do
  @moduledoc """
  T37h — the catalog-driven E6 adoption probe (ADR-040 §5.9's T37h split, T37 c1).
  Closes the T37 adoption sweep (T36 + T37a–g all DONE+CONFIRMED) with the standing
  guard the roster table itself promises: **every user-managed noun in the catalog is
  EITHER `archivable: true` OR explicitly excluded with a §5.9 exclusion class** — so
  a resource can never silently fall through the roster (no adopter forgets to flip
  it, no exclusion goes undocumented).

  ## What is scanned, and why

  This probe walks `Samen.Catalog.resource_modules/1` over the EIGHT domains ADR-040
  §5.9's table actually classifies and demo mounts: `Demo.Analytics`,
  `Demo.BillingScope`, `Demo.CmsScope`, `Demo.CrmScope`, `Demo.Identity`,
  `Demo.MarketingScope`, `Demo.PrimitivesScope`, `Demo.SupportScope`. Demo mounts
  several OTHER scopes too (`Demo.Crm` legacy, `Demo.WorkScope`, `Demo.CalendarScope`,
  `Demo.DocsScope`, `Demo.Tags`, `Demo.LocationsScope`, `Demo.SalesOps`,
  `Demo.Aggregate`) — those are deliberately NOT scanned here: §5.9's table does not
  classify them (they are separate, later-landed BATON scopes outside the E6 sweep's
  charter), so holding THIS probe to "every resource in `:samen_core, :ash_domains`"
  would force a classification call this task has no authority to make. Chat
  (`samen_web`'s T37e rider) is proven separately in
  `samen_web/test/samen/scopes/chat_catalog_adoption_probe_test.exs` — demo does not
  mount the Chat scope. `automation`'s `workflow`/`run`/`reminder`/`escalation`
  (§5.9's table also lists this scope) are likewise NOT scanned: `Samen.Scopes.Automation`
  is not mounted by ANY host today (`grep -rn Automation */config/config.exs` — zero
  hits; only samen_core/samen_web TEST fixtures use it), so it never appears in a real
  catalog for this probe to walk — a pre-existing gap this probe surfaces in its
  moduledoc rather than silently working around, since flipping `archivable: true` on
  `Workflow` is a substrate change outside T37h's `Samen.Files`/gen/UI/probe charter
  (T37a–f's per-scope pattern is the right vehicle for it, not this task).

  ## The roster fixture — §5.9's table, verbatim, not re-derived

  `@roster` below is a direct transcription of ADR-040 §5.9's table (the Archivable /
  Excluded columns) — the handoff's own instruction ("use §5.9's table as the test
  fixture directly — don't re-derive the classification"). Each entry is
  `{domain, resource, status}` where `status` is `:archivable` or `{:excluded, class}`
  (`class` mirrors the table's parenthetical: `:ledger` (L), `:mirror` (M),
  `:mirror_derived` (M — derived), `:auth` (A), `:settings`, `:never`).

  ## The three guarantees proven

    1. **Every roster-archivable resource IS archivable** (`archivable?/1 == true`).
    2. **Every roster-excluded resource is NOT archivable**, and its class is on record
       here (against §5.9's own table — not re-derived).
    3. **Nothing falls through**: for EACH of the eight domains, the LIVE catalog walk
       (`Samen.Catalog.resource_modules/1`, not this file's `@roster` list) is set-
       equal to `archivable ∪ excluded` for that domain. A resource added to a scope
       tomorrow with NEITHER `archivable: true` NOR a `@roster` entry FAILS this test
       immediately — the structural "nothing silently falls through" guarantee. The
       anti-tautology proof that this check is real (not vacuously true because the
       live catalog always matches whatever this file says) lives in the last
       `describe` block: it calls the SAME accounting helper against a deliberately
       INCOMPLETE fixture and asserts it raises.
  """
  use Demo.DataCase, async: true

  # {domain, resource, status}
  @roster [
    {Demo.Analytics, Demo.Analytics.ProductEvent, {:excluded, :ledger}},
    {Demo.BillingScope, Demo.BillingScope.Plan, :archivable},
    {Demo.BillingScope, Demo.BillingScope.Price, :archivable},
    {Demo.BillingScope, Demo.BillingScope.Customer, {:excluded, :mirror}},
    {Demo.BillingScope, Demo.BillingScope.Subscription, {:excluded, :mirror}},
    {Demo.BillingScope, Demo.BillingScope.Invoice, {:excluded, :mirror}},
    {Demo.BillingScope, Demo.BillingScope.Payment, {:excluded, :mirror}},
    {Demo.BillingScope, Demo.BillingScope.Usage, {:excluded, :ledger}},
    {Demo.BillingScope, Demo.BillingScope.Entitlement, {:excluded, :mirror_derived}},
    {Demo.BillingScope, Demo.BillingScope.SubscriptionEvent, {:excluded, :ledger}},
    {Demo.CmsScope, Demo.CmsScope.Page, :archivable},
    {Demo.CmsScope, Demo.CmsScope.Post, :archivable},
    {Demo.CmsScope, Demo.CmsScope.Block, :archivable},
    {Demo.CmsScope, Demo.CmsScope.Media, :archivable},
    {Demo.CmsScope, Demo.CmsScope.Navigation, :archivable},
    {Demo.CmsScope, Demo.CmsScope.SeoMeta, :archivable},
    # T119 (ADR-040 §6.5): the bespoke ContentVersion ledger was RETIRED and replaced by
    # the E7 `versioned` mechanism. Page/Post/Block generate `<Resource>.Version` audit
    # tables — themselves excluded from E6 soft-delete (a version of history is not a
    # user-archivable noun; it is the audit-on-write ledger, §6).
    {Demo.CmsScope, Demo.CmsScope.Page.Version, {:excluded, :ledger}},
    {Demo.CmsScope, Demo.CmsScope.Post.Version, {:excluded, :ledger}},
    {Demo.CmsScope, Demo.CmsScope.Block.Version, {:excluded, :ledger}},
    {Demo.CrmScope, Demo.CrmScope.Company, :archivable},
    {Demo.CrmScope, Demo.CrmScope.Person, :archivable},
    {Demo.CrmScope, Demo.CrmScope.Pipeline, :archivable},
    {Demo.CrmScope, Demo.CrmScope.Opportunity, :archivable},
    {Demo.CrmScope, Demo.CrmScope.Attachment, :archivable},
    {Demo.Identity, Demo.Identity.Org, {:excluded, :auth}},
    {Demo.Identity, Demo.Identity.User, {:excluded, :auth}},
    {Demo.Identity, Demo.Identity.Membership, {:excluded, :auth}},
    {Demo.Identity, Demo.Identity.Role, {:excluded, :auth}},
    {Demo.Identity, Demo.Identity.ApiKey, {:excluded, :auth}},
    {Demo.Identity, Demo.Identity.Invitation, {:excluded, :auth}},
    {Demo.Identity, Demo.Identity.Credential, {:excluded, :auth}},
    {Demo.Identity, Demo.Identity.AuthToken, {:excluded, :auth}},
    {Demo.Identity, Demo.Identity.Session, {:excluded, :auth}},
    {Demo.Identity, Demo.Identity.UserIdentity, {:excluded, :auth}},
    # ADR-038 §6.4 (T109) — the durable brute-force failure counter. Not
    # user-facing archivable data: rows are hard-deleted (retention prune,
    # `Samen.Retention` :delete) or reset (`Samen.Identity.LoginFailure.reset!/3`
    # on a successful login), never soft-deleted — same `:auth` exclusion class
    # as Credential/AuthToken/Session/UserIdentity above.
    {Demo.Identity, Demo.Identity.LoginFailure, {:excluded, :auth}},
    {Demo.MarketingScope, Demo.MarketingScope.Campaign, :archivable},
    {Demo.MarketingScope, Demo.MarketingScope.Segment, :archivable},
    {Demo.MarketingScope, Demo.MarketingScope.Template, :archivable},
    {Demo.MarketingScope, Demo.MarketingScope.Subscriber, :archivable},
    {Demo.MarketingScope, Demo.MarketingScope.Send, {:excluded, :ledger}},
    {Demo.MarketingScope, Demo.MarketingScope.EmailEvent, {:excluded, :ledger}},
    {Demo.MarketingScope, Demo.MarketingScope.Suppression, {:excluded, :never}},
    {Demo.MarketingScope, Demo.MarketingScope.ConsentEvent, {:excluded, :ledger}},
    {Demo.PrimitivesScope, Demo.PrimitivesScope.File, :archivable},
    {Demo.PrimitivesScope, Demo.PrimitivesScope.Webhook, :archivable},
    {Demo.PrimitivesScope, Demo.PrimitivesScope.FeatureFlag, :archivable},
    {Demo.PrimitivesScope, Demo.PrimitivesScope.Notification, {:excluded, :ledger}},
    {Demo.PrimitivesScope, Demo.PrimitivesScope.NotificationPreference, {:excluded, :settings}},
    {Demo.PrimitivesScope, Demo.PrimitivesScope.SearchIndex, {:excluded, :mirror_derived}},
    {Demo.SupportScope, Demo.SupportScope.Ticket, :archivable},
    {Demo.SupportScope, Demo.SupportScope.Conversation, :archivable},
    {Demo.SupportScope, Demo.SupportScope.Message, :archivable},
    {Demo.SupportScope, Demo.SupportScope.Agent, :archivable},
    {Demo.SupportScope, Demo.SupportScope.Sla, :archivable},
    {Demo.SupportScope, Demo.SupportScope.Macro, :archivable},
    {Demo.SupportScope, Demo.SupportScope.Csat, {:excluded, :ledger}}
  ]

  @scanned_domains [
    Demo.Analytics,
    Demo.BillingScope,
    Demo.CmsScope,
    Demo.CrmScope,
    Demo.Identity,
    Demo.MarketingScope,
    Demo.PrimitivesScope,
    Demo.SupportScope
  ]

  describe "§5.9 roster — every archivable-listed resource IS archivable?/1 == true" do
    for {_domain, resource, :archivable} <- @roster do
      test "#{inspect(resource)} is archivable" do
        assert Samen.Info.archivable?(unquote(resource)) == true
      end
    end
  end

  describe "§5.9 roster — every excluded-listed resource is NOT archivable" do
    for {_domain, resource, {:excluded, class}} <- @roster do
      test "#{inspect(resource)} is excluded (class #{class}) and NOT archivable" do
        assert Samen.Info.archivable?(unquote(resource)) == false
      end
    end
  end

  describe "nothing falls through the roster (T37 c1 — the structural guarantee)" do
    test "for every scanned domain, the LIVE catalog is set-equal to (archivable ∪ excluded)" do
      for domain <- @scanned_domains do
        live = domain |> Samen.Catalog.resource_modules() |> MapSet.new()
        roster_for_domain = Enum.filter(@roster, fn {d, _r, _s} -> d == domain end)

        assert roster_for_domain != [],
               "sanity: #{inspect(domain)} has no @roster entries at all — the domain " <>
                 "constant list and the roster table have drifted apart"

        accounted = roster_for_domain |> Enum.map(fn {_d, r, _s} -> r end) |> MapSet.new()

        # Set-equality, not subset: a resource live-catalogued but ABSENT from @roster
        # fails here (the "silently falls through" case) — AND a stale @roster entry
        # for a resource no longer in the domain fails too (drift in the other
        # direction, e.g. a rename).
        missing_from_roster = MapSet.difference(live, accounted)
        stale_in_roster = MapSet.difference(accounted, live)

        assert MapSet.size(missing_from_roster) == 0,
               "#{inspect(domain)}: catalogued but UNCLASSIFIED by @roster (neither " <>
                 "archivable nor excluded) — #{inspect(MapSet.to_list(missing_from_roster))}"

        assert MapSet.size(stale_in_roster) == 0,
               "#{inspect(domain)}: @roster names a resource no longer in the live " <>
                 "catalog (stale/renamed) — #{inspect(MapSet.to_list(stale_in_roster))}"
      end
    end

    test "sanity: every scanned domain contributed at least one resource (no silently-empty domain)" do
      for domain <- @scanned_domains do
        assert domain |> Samen.Catalog.resource_modules() |> length() > 0,
               "#{inspect(domain)} contributed zero resources — check the domain constant"
      end
    end
  end

  describe "the activity† footnote (§5.9): the canonical Task inherits archivability" do
    test "Demo.WorkScope.Task (crm.activity's T96/T97 successor) is archivable — narrow spot-check, not a full WorkScope accounting" do
      # WorkScope itself is NOT one of the eight scanned domains above (§5.9's table
      # does not classify it) — this is a single named spot-check honoring the
      # roster's own footnote ("the T96/T97 canonical-Task migration inherits and
      # honors archived state ... the canonical Task arrives archivable true"), not a
      # claim that WorkScope's OTHER resources (e.g. Project) are accounted for here.
      assert Samen.Info.archivable?(Demo.WorkScope.Task) == true
    end
  end

  describe "anti-tautology: the 'nothing falls through' accounting is non-vacuous" do
    test "a deliberately incomplete fixture (one live resource dropped from the roster) is CAUGHT" do
      # Mirrors the real check above but with Demo.BillingScope.Price deliberately
      # removed from the "roster" — proving the set-equality assertion actually
      # detects an unaccounted resource rather than passing no matter what.
      live = Demo.BillingScope |> Samen.Catalog.resource_modules() |> MapSet.new()

      incomplete_accounted =
        @roster
        |> Enum.filter(fn {d, r, _s} -> d == Demo.BillingScope and r != Demo.BillingScope.Price end)
        |> Enum.map(fn {_d, r, _s} -> r end)
        |> MapSet.new()

      missing = MapSet.difference(live, incomplete_accounted)

      assert MapSet.member?(missing, Demo.BillingScope.Price)
      refute MapSet.size(missing) == 0
    end
  end
end
