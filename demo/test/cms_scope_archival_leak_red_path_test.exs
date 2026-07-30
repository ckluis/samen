defmodule Demo.CmsScopeArchivalLeakRedPathTest do
  @moduledoc """
  E6 soft-delete adoption for the CMS scope (ADR-040 §5.9, T37b): `page`,
  `post`, `block`, `media`, `navigation`, `seo_meta` flip `archivable true`
  (T36's `use Samen.Resource, archivable: true` convention, backed by
  ash_archival). `content_version` stays excluded (L — ledger; also retired
  outright by T38, ADR-040 §6.5) and is left untouched.

  `page ▸cascade block` is the scope's one declared composition cascade
  (§5.4): archiving a Page cascades to archive its Blocks at the SAME
  INSTANT (`Samen.Scopes.Cms.CascadeArchive`); restoring a Page restores
  exactly the same-instant-archived Blocks
  (`Samen.Scopes.Cms.CascadeRestore`) — a Block archived independently (a
  different instant) stays archived. See those two modules' docs for why
  this scope does not use ash_archival's `archive_related` DSL option
  directly (timestamp-exactness + audit-completeness gaps in that mechanism).

  §5.3: no `unique_index` exists on any of the six adopted tables today (the
  whole `20260706040000_add_cms_scope` migration has zero `unique_index`
  calls) — the partial-index conversion has nothing to convert for this
  scope, and `:restore_conflict` is therefore not constructible here; T36's
  generic `{:error, :restore_conflict}` mapping (`soft_delete_test.exs`) is
  unmodified and covers the contract.

  §5.5's standing duty for every adopting scope: an archived record must not
  leak via relationship load or aggregate, bypassing the read preparation.
  Every RED here (archived does not surface) is paired with a distinct
  positive-control CONTROL (a live row DOES surface via the same path) so the
  RED assertion is provably falsifiable, not a tautology (house masking-watch-
  list discipline, CLAUDE.md).

  No CMS resource carries a vault-routed (🔒) field — INV-1 masking-on-archive
  is not applicable to this scope's adoption (the CMS scope has no 🔒 objects
  at all, per `Samen.Scopes.Cms` moduledoc).
  """
  use Demo.DataCase, async: false

  require Ash.Query

  alias Demo.CmsScope.{Page, Post, Block, Media, Navigation, SeoMeta}

  # ── helpers ──────────────────────────────────────────────────────────────

  defp mk_org, do: Ash.UUID.generate()

  defp mk_page(org_id, title \\ "Page") do
    {:ok, page} =
      Page
      |> Ash.Changeset.for_create(:create, %{
        title: "#{title}-#{:rand.uniform(999_999)}",
        slug: "page-#{:rand.uniform(999_999)}",
        body: "Page body.",
        org_id: org_id
      })
      |> Ash.create(authorize?: false)

    page
  end

  defp mk_post(org_id, title \\ "Post") do
    {:ok, post} =
      Post
      |> Ash.Changeset.for_create(:create, %{
        title: "#{title}-#{:rand.uniform(999_999)}",
        slug: "post-#{:rand.uniform(999_999)}",
        body: "Post body.",
        org_id: org_id
      })
      |> Ash.create(authorize?: false)

    post
  end

  defp mk_block(org_id, page_id \\ nil) do
    {:ok, block} =
      Block
      |> Ash.Changeset.for_create(:create, %{
        name: "Block-#{:rand.uniform(999_999)}",
        block_type: :generic,
        content: %{"text" => "hello"},
        org_id: org_id,
        page_id: page_id
      })
      |> Ash.create(authorize?: false)

    block
  end

  defp mk_media(org_id) do
    {:ok, media} =
      Media
      |> Ash.Changeset.for_create(:create, %{
        file_name: "asset-#{:rand.uniform(999_999)}.jpg",
        content_type: "image/jpeg",
        org_id: org_id
      })
      |> Ash.create(authorize?: false)

    media
  end

  defp mk_navigation(org_id) do
    {:ok, nav} =
      Navigation
      |> Ash.Changeset.for_create(:create, %{
        label: "Nav-#{:rand.uniform(999_999)}",
        url: "/",
        org_id: org_id
      })
      |> Ash.create(authorize?: false)

    nav
  end

  defp mk_seo_meta(org_id, opts) do
    {:ok, seo_meta} =
      SeoMeta
      |> Ash.Changeset.for_create(:create, %{
        meta_title: "SEO-#{:rand.uniform(999_999)}",
        description: "Authored marketing copy.",
        org_id: org_id,
        page_id: Keyword.get(opts, :page_id),
        post_id: Keyword.get(opts, :post_id)
      })
      |> Ash.create(authorize?: false)

    seo_meta
  end

  # T124 same-second regression helper. Archives an independent sibling
  # block, then IMMEDIATELY (no sleep) archives its parent Page — cascading
  # a DIFFERENT block — via the real production `Samen.Archival.archive/2`
  # path (real `DateTime.utc_now/0` reads, no forced timestamps), exactly
  # reproducing `_orch/verify/T37b-verdict.json` finding
  # `F1-same-second-mis-restore`'s live repro. Two back-to-back in-process
  # Ecto operations land in the same wall-clock SECOND the overwhelming
  # majority of the time, but not deterministically (a second-boundary
  # straddle is possible) — so this retries with fresh records, bounded,
  # until the two persisted `archived_at` values verifiably fall in the same
  # wall-clock second (`DateTime.truncate/2` to `:second` and compare).
  # Anti-tautology: this criterion is satisfiable/checkable identically
  # whether the T124 substrate fix is present or not — it does NOT assume
  # the bug's own truncated-equality behavior, so the retry loop cannot
  # rig the outcome.
  @same_second_max_attempts 40

  defp archive_independent_then_page_same_second!(org, attempt \\ 1) do
    page = mk_page(org, "Cascade Same-Second")
    cascaded_block = mk_block(org, page.id)
    independent_block = mk_block(org, page.id)

    {:ok, archived_independent} = Samen.Archival.archive(independent_block, authorize?: false)
    {:ok, archived_page} = Samen.Archival.archive(page, authorize?: false)

    if DateTime.truncate(archived_independent.archived_at, :second) ==
         DateTime.truncate(archived_page.archived_at, :second) do
      %{page: archived_page, cascaded_block: cascaded_block, independent: archived_independent}
    else
      if attempt >= @same_second_max_attempts do
        flunk(
          "could not reproduce a same-wall-clock-second archive collision after " <>
            "#{@same_second_max_attempts} attempts — environment too slow for this " <>
            "regression test to exercise the F1-same-second-mis-restore edge"
        )
      else
        archive_independent_then_page_same_second!(org, attempt + 1)
      end
    end
  end

  # Generic archive → hidden / :archived → shown / restore → shown-again round
  # trip, reused across all six adopted resources (c1, §5.2).
  defp assert_archive_restore_roundtrip!(resource, record) do
    live_ids = fn ->
      resource |> Ash.read!(authorize?: false) |> Enum.map(& &1.id) |> MapSet.new()
    end

    archived_ids = fn ->
      resource
      |> Ash.Query.for_read(:archived)
      |> Ash.read!(authorize?: false)
      |> Enum.map(& &1.id)
      |> MapSet.new()
    end

    archived_record = fn ->
      resource
      |> Ash.Query.for_read(:archived)
      |> Ash.read!(authorize?: false)
      |> Enum.find(&(&1.id == record.id))
    end

    assert MapSet.member?(live_ids.(), record.id)

    {:ok, _} = Samen.Archival.archive(record, authorize?: false)

    # RED: gone from the default read.
    refute MapSet.member?(live_ids.(), record.id)
    # CONTROL: the :archived include-read still sees it — hidden, not gone.
    assert MapSet.member?(archived_ids.(), record.id)

    # ASSERT: restore returns it to the default read.
    {:ok, _} = Samen.Archival.restore(archived_record.(), authorize?: false)
    assert MapSet.member?(live_ids.(), record.id)
    refute MapSet.member?(archived_ids.(), record.id)
  end

  # ── introspection: the adopt-me convention landed on the whole roster row ──

  describe "introspection — Samen.Info.archivable?/1 (T37h catalog-probe fixture)" do
    test "page/post/block/media/navigation/seo_meta report true; the E7 Version resources report false" do
      assert Samen.Info.archivable?(Page)
      assert Samen.Info.archivable?(Post)
      assert Samen.Info.archivable?(Block)
      assert Samen.Info.archivable?(Media)
      assert Samen.Info.archivable?(Navigation)
      assert Samen.Info.archivable?(SeoMeta)
      # The retired ContentVersion is gone; its replacement — the generated E7
      # <Resource>.Version resources — are NOT archivable (a version of history is
      # meaningless), and Page/Post/Block additionally report `versioned?`.
      refute Samen.Info.archivable?(Demo.CmsScope.Page.Version)
      refute Samen.Info.archivable?(Demo.CmsScope.Post.Version)
      refute Samen.Info.archivable?(Demo.CmsScope.Block.Version)
      assert Samen.Info.versioned?(Page)
      assert Samen.Info.versioned?(Post)
      assert Samen.Info.versioned?(Block)
    end
  end

  # ── c1: archive hides / :archived shows / restore returns — every resource ─

  describe "c1 — archive/restore round trip, every roster resource" do
    test "Page" do
      assert_archive_restore_roundtrip!(Page, mk_page(mk_org()))
    end

    test "Post" do
      assert_archive_restore_roundtrip!(Post, mk_post(mk_org()))
    end

    test "Block" do
      org = mk_org()
      assert_archive_restore_roundtrip!(Block, mk_block(org))
    end

    test "Media" do
      assert_archive_restore_roundtrip!(Media, mk_media(mk_org()))
    end

    test "Navigation" do
      assert_archive_restore_roundtrip!(Navigation, mk_navigation(mk_org()))
    end

    test "SeoMeta" do
      org = mk_org()
      page = mk_page(org)
      assert_archive_restore_roundtrip!(SeoMeta, mk_seo_meta(org, page_id: page.id))
    end
  end

  # ── §5.4 cascade: page ▸cascade block — same-instant archive ───────────────

  describe "§5.4 — archiving a Page cascades to archive its Blocks at the same instant" do
    test "both blocks land on the EXACT same archived_at as the page (RED: hidden; CONTROL: unrelated page untouched)" do
      org = mk_org()
      page = mk_page(org, "Cascade Archive")
      other_page = mk_page(org, "Untouched")

      block_a = mk_block(org, page.id)
      block_b = mk_block(org, page.id)
      unrelated_block = mk_block(org, other_page.id)

      {:ok, archived_page} = Samen.Archival.archive(page, authorize?: false)

      # RED: both cascaded blocks vanish from Block's default read.
      live_block_ids =
        Block |> Ash.read!(authorize?: false) |> Enum.map(& &1.id) |> MapSet.new()

      refute MapSet.member?(live_block_ids, block_a.id)
      refute MapSet.member?(live_block_ids, block_b.id)
      # CONTROL: an unrelated block (different page) is untouched.
      assert MapSet.member?(live_block_ids, unrelated_block.id)

      archived_blocks =
        Block |> Ash.Query.for_read(:archived) |> Ash.read!(authorize?: false)

      archived_a = Enum.find(archived_blocks, &(&1.id == block_a.id))
      archived_b = Enum.find(archived_blocks, &(&1.id == block_b.id))

      assert archived_a.archived_at == archived_page.archived_at
      assert archived_b.archived_at == archived_page.archived_at
    end
  end

  # ── §5.4 cascade: page ▸cascade block — same-instant restore match ─────────

  describe "§5.4 — restoring a Page restores exactly the same-instant-archived Blocks" do
    test "a block archived independently BEFORE the page's cascade stays archived after the page restores (RED); the cascaded block returns (CONTROL)" do
      org = mk_org()
      page = mk_page(org, "Cascade Restore")

      cascaded_block = mk_block(org, page.id)
      independently_archived_block = mk_block(org, page.id)

      # Archive the second block INDEPENDENTLY first, at its own instant.
      {:ok, _} = Samen.Archival.archive(independently_archived_block, authorize?: false)

      # Force a distinct instant with a >1s sleep — a belt-and-suspenders gap
      # that stays green regardless of substrate precision. HISTORICAL NOTE
      # (T37b → T124): until T124, `Samen.Transformers.ArchivableAttribute`
      # built the raw `archived_at` attribute with `constraints: []`, which
      # silently fell through to `Ash.Type.Datetime`'s OWN default
      # (`precision: :second`) and truncated every stamped instant to whole
      # seconds REGARDLESS of the column's `:utc_datetime_usec` storage
      # capacity — the exact defect `_orch/verify/T37b-verdict.json` finding
      # `F1-same-second-mis-restore` reproduced live. T124 fixed the
      # substrate (`constraints: [precision: :microsecond]`), restoring true
      # microsecond granularity; see the same-second regression test below
      # (`§5.4 — same wall-clock second`) for the direct, no-sleep
      # reproduction of that exact edge, now closed.
      Process.sleep(1_100)

      # Now archive the page — cascades ONLY the still-live `cascaded_block`
      # (the independently-archived one is already hidden from the default
      # read the cascade sweep queries, so it is left at its own instant).
      {:ok, archived_page} = Samen.Archival.archive(page, authorize?: false)

      archived_blocks_before_restore =
        Block |> Ash.Query.for_read(:archived) |> Ash.read!(authorize?: false)

      cascaded_before = Enum.find(archived_blocks_before_restore, &(&1.id == cascaded_block.id))
      independent_before =
        Enum.find(archived_blocks_before_restore, &(&1.id == independently_archived_block.id))

      assert cascaded_before.archived_at == archived_page.archived_at
      refute independent_before.archived_at == archived_page.archived_at

      # Restore the page.
      {:ok, _restored_page} = Samen.Archival.restore(archived_page, authorize?: false)

      live_block_ids =
        Block |> Ash.read!(authorize?: false) |> Enum.map(& &1.id) |> MapSet.new()

      # CONTROL: the cascade-archived block came back with the page.
      assert MapSet.member?(live_block_ids, cascaded_block.id)
      # RED: the independently-archived block did NOT — different instant,
      # not part of the cascade set (ADR-040 §5.4: "a child independently
      # archived earlier stays archived").
      refute MapSet.member?(live_block_ids, independently_archived_block.id)

      still_archived_ids =
        Block
        |> Ash.Query.for_read(:archived)
        |> Ash.read!(authorize?: false)
        |> Enum.map(& &1.id)
        |> MapSet.new()

      assert MapSet.member?(still_archived_ids, independently_archived_block.id)
    end
  end

  # ── §5.4 cascade: page ▸cascade block — same wall-clock second (T124) ──────

  describe "§5.4 — same wall-clock second (T124, F1-same-second-mis-restore)" do
    test "page restore does not mis-restore an independent same-second sibling (CONTROL: cascade block restores)" do
      org = mk_org()

      %{page: archived_page, cascaded_block: cascaded_block, independent: archived_independent} =
        archive_independent_then_page_same_second!(org)

      # Sanity: we really did land in the same wall-clock second (the
      # scenario T37b's >1s-gap test above deliberately steps over).
      assert DateTime.truncate(archived_independent.archived_at, :second) ==
               DateTime.truncate(archived_page.archived_at, :second)

      # Under the pre-T124 substrate (`archived_at` silently second-granular
      # regardless of column type), the two persisted instants would be
      # byte-IDENTICAL here, which is exactly what let the cascade restore's
      # `archived_at == ^instant` match sweep up the independent block too.
      # Post-T124 (true microsecond precision), they are practically
      # guaranteed to differ.
      independent_collided_with_page? =
        archived_independent.archived_at == archived_page.archived_at

      {:ok, _restored_page} = Samen.Archival.restore(archived_page, authorize?: false)

      live_block_ids =
        Block |> Ash.read!(authorize?: false) |> Enum.map(& &1.id) |> MapSet.new()

      # CONTROL (anti-tautology, positive control): the cascade-matched
      # block — same page, cascaded at the SAME instant as the page's own
      # archive — DOES come back. Proves the restore path itself works and
      # this test isn't vacuously green because nothing ever restores.
      assert MapSet.member?(live_block_ids, cascaded_block.id)

      # RED (the T37b-reproduced edge): the sibling block that was archived
      # INDEPENDENTLY — merely in the same wall-clock second as the page's
      # cascade, not part of the cascade set — must NOT be restored by the
      # page restore (ADR-040 §5.4: "a child independently archived earlier
      # stays archived"). This is the assertion that was FALSE
      # (`independent_collided_with_page?` was `true`, and the block came
      # back live) before the T124 substrate fix.
      refute independent_collided_with_page?,
             "pre-T124 defect reproduced: independent block's archived_at collided " <>
               "byte-exact with the page's cascade instant (second-granularity truncation)"

      refute MapSet.member?(live_block_ids, archived_independent.id)

      still_archived_ids =
        Block
        |> Ash.Query.for_read(:archived)
        |> Ash.read!(authorize?: false)
        |> Enum.map(& &1.id)
        |> MapSet.new()

      assert MapSet.member?(still_archived_ids, archived_independent.id)
    end
  end

  # ── §5.5 leak duty: relationship load — SeoMeta.page ────────────────────────

  describe "§5.5 — an archived Page does not leak via SeoMeta.page relationship load" do
    test "SeoMeta.page resolves to nil for an archived page (RED); a live page surfaces (CONTROL)" do
      org = mk_org()

      archived_page = mk_page(org, "Archived")
      live_page = mk_page(org, "Live")

      seo_on_archived = mk_seo_meta(org, page_id: archived_page.id)
      seo_on_live = mk_seo_meta(org, page_id: live_page.id)

      {:ok, _} = Samen.Archival.archive(archived_page, authorize?: false)

      # RED: the relationship load does NOT surface the archived page — the
      # default-read preparation (`is_nil(archived_at)`) applies to the
      # destination resource's read even when reached via a belongs_to load.
      loaded_on_archived = Ash.load!(seo_on_archived, :page, authorize?: false)
      assert loaded_on_archived.page == nil

      # CONTROL (anti-tautology): the identical relationship load path DOES
      # surface a live page.
      loaded_on_live = Ash.load!(seo_on_live, :page, authorize?: false)
      assert %Page{id: live_id} = loaded_on_live.page
      assert live_id == live_page.id
    end
  end

  # ── §5.5 leak duty: relationship load — SeoMeta.post ────────────────────────

  describe "§5.5 — an archived Post does not leak via SeoMeta.post relationship load" do
    test "SeoMeta.post resolves to nil for an archived post (RED); a live post surfaces (CONTROL)" do
      org = mk_org()

      archived_post = mk_post(org, "Archived")
      live_post = mk_post(org, "Live")

      seo_on_archived = mk_seo_meta(org, post_id: archived_post.id)
      seo_on_live = mk_seo_meta(org, post_id: live_post.id)

      {:ok, _} = Samen.Archival.archive(archived_post, authorize?: false)

      # RED: the second independent belongs_to consumer (SeoMeta → Post) is
      # ALSO filtered — proves the preparation is resource-level, not a
      # one-off wired only for the Page path above.
      loaded_on_archived = Ash.load!(seo_on_archived, :post, authorize?: false)
      assert loaded_on_archived.post == nil

      # CONTROL: a live post surfaces via the same path.
      loaded_on_live = Ash.load!(seo_on_live, :post, authorize?: false)
      assert %Post{id: live_id} = loaded_on_live.post
      assert live_id == live_post.id
    end
  end

  # ── §5.5 leak duty: aggregate — Page :exists on :blocks ─────────────────────

  describe "§5.5 — an archived Block does not leak via an :exists aggregate on Page.blocks" do
    test "the :exists aggregate over Page.blocks is false when its only block is archived independently (RED); true for a live block (CONTROL)" do
      org = mk_org()
      page_with_archived_block = mk_page(org, "Aggregate RED")
      page_with_live_block = mk_page(org, "Aggregate CONTROL")

      block_to_archive = mk_block(org, page_with_archived_block.id)
      _live_block = mk_block(org, page_with_live_block.id)

      {:ok, _} = Samen.Archival.archive(block_to_archive, authorize?: false)

      # RED: the ad-hoc :exists aggregate — a SEPARATE code path from
      # relationship loading, compiled to a correlated SQL subquery by
      # AshPostgres — also honors the default-read filter on the destination
      # resource (Block).
      archived_result =
        Page
        |> Ash.Query.filter(id == ^page_with_archived_block.id)
        |> Ash.Query.aggregate(:has_live_block?, :exists, :blocks)
        |> Ash.read_one!(authorize?: false)

      refute archived_result.aggregates.has_live_block?

      # CONTROL (anti-tautology): the identical aggregate over a page with a
      # LIVE block reports true — proves `false` above is the archival filter
      # firing, not the aggregate being vacuously false.
      live_result =
        Page
        |> Ash.Query.filter(id == ^page_with_live_block.id)
        |> Ash.Query.aggregate(:has_live_block?, :exists, :blocks)
        |> Ash.read_one!(authorize?: false)

      assert live_result.aggregates.has_live_block?
    end
  end

  # ── §5.4: no cascade — archiving Post/Media/Navigation leaves consumers live

  describe "§5.4 — no cascade declared for Post/Media/Navigation/SeoMeta (default no-cascade)" do
    test "archiving a Post does not touch an unrelated live SeoMeta row pointing at it" do
      org = mk_org()
      post = mk_post(org, "No Cascade")
      seo_meta = mk_seo_meta(org, post_id: post.id)

      {:ok, _} = Samen.Archival.archive(post, authorize?: false)

      # The SeoMeta row itself stays live (its own default read still surfaces
      # it) — only its :post RELATIONSHIP LOAD is filtered (proven above).
      live_seo_meta_ids =
        SeoMeta |> Ash.read!(authorize?: false) |> Enum.map(& &1.id) |> MapSet.new()

      assert MapSet.member?(live_seo_meta_ids, seo_meta.id)
    end
  end
end
