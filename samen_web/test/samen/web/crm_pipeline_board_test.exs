defmodule Samen.Web.CRMPipelineBoardTest do
  @moduledoc """
  End-to-end proofs for the G1 KANBAN board (T51) — the CRM Pipeline as the FIRST client of
  the generic `Samen.Web.Reads.group_by!/3` (T50) rendered through `Samen.UI.board/1`. Each
  proof is anti-tautology (a positive control anchors every guard):

    * COLUMNS/CARDS/COUNTS — a seeded MULTI-STAGE pipeline renders one column per stage
      (label + exact count) with an opportunity card per row, through the real LiveView.
    * ORG-SCOPE (sabotage-refutable) — a 2-org seed: org B's opportunities NEVER appear as
      cards on org A's board (and DO appear on org B's own board — the refutation control).
    * BOUNDING + LOAD-MORE — a stage with MORE than the cap returns the cap + `has_more` +
      the exact `count`; the per-column "load more" reads the NEXT keyset page and appends,
      driven through the LiveView's `handle_event/3` (AC constraint (e)).
    * MASKING POSTURE — opportunities are NON-PII and the group facet `:pipeline_id` is
      non-vaulted, so NO card field masks and no per-plane proof is required (documented;
      the vaulted `Person.full_name` anchors the non-vacuity of the "non-vaulted" claim).
    * GOVERNED-MOVE SEAM — move is DEFERRED, but the governed path it must use when it lands
      (the org-scoped Opportunity `:update` action + `SameOrgFk[:pipeline]`) is real, not
      vapor — asserted present so the deferral is honest.
  """
  use Samen.WebTest.DataCase, async: false

  require Ash.Query

  alias Samen.Web.CRM.PipelineLive
  alias Samen.Web.CRM.Reads
  alias Samen.Web.Mount

  @opportunity Samen.WebTest.Crm.Opportunity
  @pipeline Samen.WebTest.Crm.Pipeline
  @person Samen.WebTest.Crm.Person

  # -- seed helpers ------------------------------------------------------------

  defp seed_stage(org_id, name, label, order) do
    @pipeline
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org_id, name: name, label: label, stage_order: order, stage_type: "open"},
      actor: %{org_id: org_id, role: :admin},
      authorize?: false
    )
    |> Ash.create!()
  end

  defp seed_opp(org_id, stage, name) do
    @opportunity
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org_id,
        name: name,
        value: Samen.Type.Money.from_cents(100_000, :USD),
        status: :open,
        pipeline_id: stage.id
      },
      actor: %{org_id: org_id, role: :member},
      authorize?: false
    )
    |> Ash.create!()
  end

  # A 2-stage org: `open` (n_open opps) + `won` (n_won opps). Returns handles.
  defp seed_pipeline_org(prefix, n_open, n_won) do
    org_id = Ash.UUID.generate()
    open = seed_stage(org_id, "#{prefix}-open", "#{prefix} Open", 0)
    won = seed_stage(org_id, "#{prefix}-won", "#{prefix} Won", 1)

    for i <- 1..n_open, do: seed_opp(org_id, open, "#{prefix}-OPEN-OPP-#{i}")
    if n_won > 0, do: for(i <- 1..n_won, do: seed_opp(org_id, won, "#{prefix}-WON-OPP-#{i}"))

    %{org_id: org_id, open: open, won: won}
  end

  # -- COLUMNS / CARDS / COUNTS ------------------------------------------------

  test "renders one column per stage with label + exact count and a card per opportunity" do
    mount = build_mount(:crm)
    %{org_id: org_id} = seed_pipeline_org("A", 3, 1)

    html = render_live(PipelineLive, mount, [org_id])

    # Both stage columns present with their labels …
    assert html =~ ~s(class="board")
    assert html =~ "A Open"
    assert html =~ "A Won"
    # … exact per-column counts (DB aggregate, not length(rows)) …
    assert html =~ ~s(class="bcol-n">3<)
    assert html =~ ~s(class="bcol-n">1<)
    # … and a card per opportunity (the :card slot).
    assert html =~ "A-OPEN-OPP-1"
    assert html =~ "A-OPEN-OPP-3"
    assert html =~ "A-WON-OPP-1"
    assert html =~ "opp-"
  end

  # -- ORG-SCOPE (sabotage-refutable) ------------------------------------------

  test "ORG-SCOPE: org B's opportunities NEVER appear as cards on org A's board" do
    mount = build_mount(:crm)
    %{org_id: org_a} = seed_pipeline_org("A", 2, 0)
    %{org_id: org_b} = seed_pipeline_org("B", 4, 0)

    a_html = render_live(PipelineLive, mount, [org_a])
    b_html = render_live(PipelineLive, mount, [org_b])

    # Org A's board shows ONLY org A cards; org B's cards are absent …
    assert a_html =~ "A-OPEN-OPP-1"
    refute a_html =~ "B-OPEN-OPP-1"
    refute a_html =~ "B-OPEN-OPP-4"
    refute a_html =~ "B Open"

    # … and the refutation control: org B's cards DO appear on org B's OWN board (so the
    # absence above is real org-scoping, not a seed that never rendered anywhere).
    assert b_html =~ "B-OPEN-OPP-1"
    refute b_html =~ "A-OPEN-OPP-1"

    # Reads-level cross-check: every card row on org A's board is org A's.
    scope_a = Mount.scope(mount, org_a)
    %{board: board} = Reads.pipeline_board(mount, scope_a)
    a_ids = board.groups |> Enum.flat_map(& &1.rows) |> MapSet.new(& &1.id)

    b_ids =
      @opportunity
      |> Ash.Query.filter(org_id == ^org_b)
      |> Ash.read!(scope: Mount.scope(mount, org_b))
      |> MapSet.new(& &1.id)

    assert MapSet.size(b_ids) == 4
    assert MapSet.disjoint?(a_ids, b_ids)
  end

  # -- BOUNDING + LOAD-MORE ----------------------------------------------------

  test "BOUNDING: a stage over the cap returns cap + has_more + exact count" do
    mount = build_mount(:crm)
    %{org_id: org_id, open: open} = seed_pipeline_org("A", 5, 0)
    scope = Mount.scope(mount, org_id)

    %{board: board} = Reads.pipeline_board(mount, scope, per_group_limit: 3)
    hot = Enum.find(board.groups, &(&1.key == open.id))

    assert length(hot.rows) == 3
    assert hot.has_more == true
    assert hot.count == 5
    refute is_nil(hot.next_cursor)
  end

  test "LOAD-MORE: the LiveView handle_event reads the next column page and appends" do
    mount = build_mount(:crm)
    %{org_id: org_id, open: open} = seed_pipeline_org("A", 5, 0)
    scope = Mount.scope(mount, org_id)

    # Start from a capped board (cap 3): the open column shows 3 of 5, has_more.
    %{board: board} = Reads.pipeline_board(mount, scope, per_group_limit: 3)

    socket =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(samen_mount: mount, org_id: org_id, board: board)

    {:noreply, socket} =
      PipelineLive.handle_event("board_load_more", %{"key" => to_string(open.id)}, socket)

    open_group = Enum.find(socket.assigns.board.groups, &(&1.key == open.id))
    # The next keyset page appended: all 5 now loaded, has_more cleared.
    assert length(open_group.rows) == 5
    assert open_group.has_more == false
    # No duplicates — keyset paging appended strictly after the cursor.
    assert length(Enum.uniq_by(open_group.rows, & &1.id)) == 5
  end

  test "LOAD-MORE is org-scoped: a forged cross-org stage key yields no rows" do
    mount = build_mount(:crm)
    %{org_id: org_a} = seed_pipeline_org("A", 1, 0)
    %{open: b_open} = seed_pipeline_org("B", 3, 0)
    scope_a = Mount.scope(mount, org_a)

    # Ask org A's scope for org B's stage column — OrgScope narrows to org A, whose opps
    # carry org A's pipeline_ids, so org B's stage id matches NOTHING (no cross-org bleed).
    page = Reads.pipeline_stage_page(mount, scope_a, to_string(b_open.id), nil)
    assert page.items == []
  end

  # -- MASKING POSTURE ---------------------------------------------------------

  test "MASKING POSTURE: no card field is vault-routed, so no per-plane proof is required" do
    # The group facet and every rendered card field are NON-vaulted …
    refute Samen.Pii.Info.vault_routed?(@opportunity, :pipeline_id)
    refute Samen.Pii.Info.vault_routed?(@opportunity, :name)
    refute Samen.Pii.Info.vault_routed?(@opportunity, :value)
    refute Samen.Pii.Info.vault_routed?(@opportunity, :status)
    # … anchored against a REAL vaulted field on a sibling CRM resource, so "non-vaulted"
    # is a live discriminator, not a predicate that returns false for everything.
    assert Samen.Pii.Info.vault_routed?(@person, :full_name)
  end

  # -- GOVERNED-MOVE SEAM (deferral is honest) ---------------------------------

  test "GOVERNED-MOVE SEAM: the governed stage-change path exists (move deferred, not vapor)" do
    # Move is deferred, but the path it MUST use — the Opportunity :update action, org-scoped,
    # with SameOrgFk refusing a cross-org target stage — is real. A raw update is never the
    # sanctioned path.
    assert Ash.Resource.Info.action(@opportunity, :update)

    same_org_fk? =
      @opportunity
      |> Ash.Resource.Info.changes()
      |> Enum.any?(fn c ->
        match?(%{change: {Samen.Policy.SameOrgFk, _}}, c) or
          inspect(c) =~ "SameOrgFk"
      end)

    assert same_org_fk?, "Opportunity must carry SameOrgFk so a moved card cannot cross orgs"
  end
end
