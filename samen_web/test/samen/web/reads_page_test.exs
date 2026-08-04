defmodule Samen.Web.ReadsPageTest do
  @moduledoc """
  The keyset PAGE primitives — `Samen.Web.Reads.page!/3` (org-scoped) and its sibling
  `Samen.Web.Reads.page_operator!/3` (the T127 DELIBERATE operator-plane cross-tenant read).

  ## The T127 boundary

  `page!/3` used to forward `authorize?: false` into the underlying read, and because these
  resources isolate via the `Samen.Policy.OrgScope` POLICY only (no attribute multitenancy),
  `authorize?: false` = the org boundary OFF. A future caller passing it WITHOUT an explicit
  narrowing would silently read across ALL orgs (a latent P0). This file proves the seam is now
  SAFE-BY-CONSTRUCTION or LOUD, each direction anti-tautology (a positive control paired with the
  guard so the assertion is refutable):

    * REFUSED — a bare `page!/3` `authorize?: false` (the latent-leak path) RAISES an
      `ArgumentError` at the call, never a silent all-orgs read. Sabotage-refutable: the
      sanctioned narrowed path returns rows, so the raise is a real guard, not a raise-on-
      everything no-op.
    * ORG-SCOPE — the default `page!/3` still scopes to ONE org in a 2-org seed.
    * PINNED CROSS-TENANT — `page_operator!/3` returns the named operator namespace ONLY (never
      all orgs); its `:account_scope` pin is REQUIRED (nil/absent refused), so the cross-tenant
      path is deliberate AND always narrowed by construction.
    * NO-LEAK — a would-be future caller doing `authorize?: false` without narrowing cannot read
      org B's rows: the raise fires BEFORE any read.
  """
  use Samen.WebTest.DataCase, async: false

  require Ash.Query

  alias Samen.Web.ListState
  alias Samen.Web.Mount
  alias Samen.Web.Page
  alias Samen.Web.Reads

  @person Samen.WebTest.Crm.Person

  defp create_person(org_id, name) do
    @person
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org_id,
        display_name: name,
        job_title: "Broker",
        full_name: %Samen.Type.FullName{first: name, last: "X"}
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  defp seed_org(mount, count) do
    org_id = Ash.UUID.generate()
    for i <- 1..count, do: create_person(org_id, "P-#{i}")
    {org_id, Mount.scope(mount, org_id)}
  end

  defp org_ids(_mount, org_id, scope) do
    @person
    |> Ash.Query.filter(org_id == ^org_id)
    |> Ash.read!(scope: scope)
    |> MapSet.new(& &1.id)
  end

  defp page_ids(%Page{items: items}), do: MapSet.new(items, & &1.id)

  # -- ORG-SCOPE (default page!/3 stays scoped) --------------------------------

  test "ORG-SCOPE: default page!/3 scopes to ONE org — org B never appears in org A's page" do
    mount = build_mount(:crm)
    {org_a, scope_a} = seed_org(mount, 3)
    {org_b, scope_b} = seed_org(mount, 5)

    # Refutation setup: org B genuinely holds 5 rows of the same shape.
    b_ids = org_ids(mount, org_b, scope_b)
    assert MapSet.size(b_ids) == 5

    page =
      Mount.resource(mount, Person)
      |> Ash.Query.ensure_selected([:org_id, :display_name])
      |> Reads.page!(%ListState{page_size: 100}, scope: scope_a)

    assert %Page{} = page
    # OrgScope narrows the page to org A only — none of org B's 5.
    assert length(page.items) == 3
    assert Enum.all?(page.items, &(&1.org_id == org_a))
    assert MapSet.disjoint?(page_ids(page), b_ids)
  end

  # -- REFUSED (the latent-leak path is now LOUD) — sabotage-refutable ---------

  test "REFUSED: a bare page!/3 authorize?: false RAISES — the latent all-orgs read is loud" do
    mount = build_mount(:crm)
    {_org_a, scope_a} = seed_org(mount, 3)
    {org_b, scope_b} = seed_org(mount, 5)

    # Under the OLD (defective) contract, authorize?: false dropped OrgScope and returned ALL 8
    # (3 + 5) rows across BOTH orgs. There is now NO page!/3 opt that can do this.
    b_ids = org_ids(mount, org_b, scope_b)
    assert MapSet.size(b_ids) == 5

    for opts <- [
          [scope: scope_a, authorize?: false],
          [scope: scope_a, authorize?: false, filter_fields: [:display_name]],
          [scope: scope_a, authorize?: true]
        ] do
      err =
        assert_raise ArgumentError, fn ->
          Mount.resource(mount, Person)
          |> Ash.Query.ensure_selected([:org_id])
          |> Reads.page!(%ListState{page_size: 100}, opts)
        end

      # The raise NAMES the sanctioned cross-tenant path, so a dev is routed, not just blocked.
      assert err.message =~ "authorize?"
      assert err.message =~ "page_operator!"
    end

    # GREEN control (anti-tautology): DROP authorize? and page!/3 works, scoped to org A. So the
    # raise above is a real guard on the authorize? key, not a raise-on-everything no-op.
    page =
      Mount.resource(mount, Person)
      |> Ash.Query.ensure_selected([:org_id])
      |> Reads.page!(%ListState{page_size: 100}, scope: scope_a)

    assert %Page{} = page
    assert length(page.items) == 3
  end

  # -- NO-LEAK (a would-be future caller) --------------------------------------

  test "NO-LEAK: a future authorize?: false caller cannot read org B's rows (raises FIRST)" do
    mount = build_mount(:crm)
    {_org_a, scope_a} = seed_org(mount, 2)
    {org_b, scope_b} = seed_org(mount, 4)

    b_ids = org_ids(mount, org_b, scope_b)
    assert MapSet.size(b_ids) == 4

    # The guard raises BEFORE any Ash.read!, so no cross-org rows are ever materialized — the
    # future unfiltered caller fails loudly in dev/test, it never leaks org B in prod.
    assert_raise ArgumentError, fn ->
      Mount.resource(mount, Person)
      |> Reads.page!(%ListState{page_size: 100}, scope: scope_a, authorize?: false)
    end
  end

  # -- PINNED CROSS-TENANT (page_operator!/3) ----------------------------------

  test "PINNED: page_operator!/3 returns the named operator namespace ONLY — never all orgs" do
    mount = build_mount(:crm)
    {org_a, scope_a} = seed_org(mount, 3)
    {org_b, _scope_b} = seed_org(mount, 5)

    # Refutation anchor: org A genuinely holds 3 rows the actor (org A) owns.
    a_ids = org_ids(mount, org_a, scope_a)
    assert MapSet.size(a_ids) == 3

    # DELIBERATE cross-tenant read pinned to org B: actor is org A, OrgScope disabled, but the
    # read is confined to org B by the account_scope pin — it returns ONLY org B's 5, never all 8.
    page =
      Mount.resource(mount, Person)
      |> Ash.Query.ensure_selected([:org_id])
      |> Reads.page_operator!(%ListState{page_size: 100}, scope: scope_a, account_scope: org_b)

    assert %Page{} = page
    assert length(page.items) == 5
    assert Enum.all?(page.items, &(&1.org_id == org_b))
    # PINNED, not all-orgs: org A's rows are absent even though OrgScope is off.
    assert MapSet.disjoint?(page_ids(page), a_ids)
  end

  test "PINNED: page_operator!/3 is BOUNDED — the limit holds, the page reports its clamped size" do
    mount = build_mount(:crm)
    {org_b, _scope_b} = seed_org(mount, 7)
    {_org_a, scope_a} = seed_org(mount, 1)

    page =
      Mount.resource(mount, Person)
      |> Ash.Query.ensure_selected([:org_id])
      |> Reads.page_operator!(%ListState{page_size: 3}, scope: scope_a, account_scope: org_b)

    assert %Page{} = page
    # Bounded: at most page_size rows (NOT all 7), has_more true, honored page_size 3.
    assert length(page.items) == 3
    assert page.has_more == true
    assert page.page_size == 3
    assert Enum.all?(page.items, &(&1.org_id == org_b))
  end

  test "PINNED: page_operator!/3 REQUIRES a narrowing pin — nil/absent :account_scope is refused" do
    mount = build_mount(:crm)
    {_org_a, scope_a} = seed_org(mount, 2)

    # Absent :account_scope → Keyword.fetch! raises (the pin is mandatory — no unpinned path).
    assert_raise KeyError, fn ->
      Mount.resource(mount, Person)
      |> Reads.page_operator!(%ListState{}, scope: scope_a)
    end

    # nil :account_scope → ArgumentError (a nil pin would narrow to nothing while implying scoping).
    err =
      assert_raise ArgumentError, fn ->
        Mount.resource(mount, Person)
        |> Reads.page_operator!(%ListState{}, scope: scope_a, account_scope: nil)
      end

    assert err.message =~ "account_scope"
  end
end
