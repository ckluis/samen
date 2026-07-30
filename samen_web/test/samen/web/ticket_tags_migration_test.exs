defmodule Samen.Web.TicketTagsMigrationTest do
  @moduledoc """
  F4/T46 (spec §F4) — the Support-scope `Ticket.tags` → generic `Tag`/`Tagging`
  migration proof. Drives the **REAL** `MigrateTicketTagsToTagScope.up/0` (via
  `Ecto.Migrator`) so the migration's actual copy SQL is a first-class tested
  artifact — NOT a hand-copied inline duplicate (mirrors
  `Samen.Web.CRMActivityMigrationTest`'s house pattern). Asserts:

    * **Zero data drop + set-equality (§F4 done-criterion 2):** every distinct
      tag name on every seeded ticket lands as a live `Tag` row (one per
      `(org, name)`), and every `(ticket, tag)` pair lands as exactly one
      `Tagging` row — proven by SET-EQUALITY between the original
      `wsk_tags` arrays and the post-migration Tagging-derived tag-name sets
      per ticket.
    * **Cross-org tag reuse:** the SAME tag name in TWO different orgs
      produces TWO distinct live `Tag` rows (never merged across orgs).
    * **Old array column dropped (schema probe):** `wsk_tags` no longer
      exists on `wsk_ticket`; no orphan `fld_field` row.
    * **Idempotency:** re-running `up/0` adds no duplicate Tag/Tagging rows.
    * **Ticket tag reads/filters equivalent post-migration:** the ticket's
      tags read via `Samen.Web.Support.Reads.ticket_tag_names/3` (the
      generic-Tag-backed read helper) match the ORIGINAL array set exactly;
      filtering "tickets with tag X" via a Tagging query returns the same
      ticket set the array `tags`-contains filter would have.
  """
  use Samen.WebTest.DataCase, async: false

  require Ash.Query

  alias Samen.Web.Mount
  alias Samen.Web.Support.Reads, as: SupportReads
  alias Samen.WebTest.Support.Ticket
  alias Samen.WebTest.Tags.{Tag, Tagging}

  @migration Samen.WebTest.Repo.Migrations.MigrateTicketTagsToTagScope

  defp support_mount, do: Mount.new(:support, Samen.WebTest.Support, Samen.WebTest.Repo)
  defp tenant_scope(org_id), do: Mount.scope(support_mount(), org_id)

  test "the REAL migration up/0 converts seeded ticket tag arrays to Tag+Tagging rows " <>
         "with SET-EQUALITY, drops the old array column, and stays idempotent" do
    # By the time this test runs, the samen_web test host's OWN app migrations
    # (including the REAL MigrateTicketTagsToTagScope, applied during DB
    # setup) have ALREADY dropped wsk_tags — the Ash Ticket resource no longer
    # declares the attribute at all. Re-add the OLD-SCHEMA column inside this
    # test's own sandboxed (rolled-back) transaction — mirroring
    # `Samen.Web.CRMActivityMigrationTest`'s "recreate the old schema" pattern,
    # scoped to ONE column instead of a whole table — so the migration's REAL
    # `up/0` (via `column_exists?/2`) finds real "deployment still has the
    # column" data to transform, exactly like a real un-migrated deployment.
    ensure_tags_column!()

    org_a = Ash.UUID.generate()
    org_b = Ash.UUID.generate()

    # Two tickets in org_a sharing a tag ("urgent") + one tag unique to each;
    # one ticket in org_b reusing the SAME tag name "urgent" (must NOT merge
    # across orgs); one ticket with NO tags (empty array).
    ticket_a1 = insert_ticket!(org_a, "Payment failed", ["urgent", "billing"])
    ticket_a2 = insert_ticket!(org_a, "Login broken", ["urgent", "vip"])
    ticket_a3 = insert_ticket!(org_a, "General question", [])
    ticket_b1 = insert_ticket!(org_b, "Different org, same tag name", ["urgent"])

    run_real_migration!()

    # -- old array column is GONE (schema probe) --------------------------
    refute column_exists?("wsk_ticket", "wsk_tags")

    %{rows: [[fld_ct]]} =
      Repo.query!(
        "SELECT count(*) FROM fld_field WHERE fld_table_name = 'wsk_ticket' AND fld_column_name = 'wsk_tags'"
      )

    assert fld_ct == 0, "no orphan fld_field row for the dropped wsk_tags column"

    # -- ZERO DROP + SET-EQUALITY: every original tag survives per ticket ---
    assert tag_names_for(org_a, ticket_a1.id) == MapSet.new(["urgent", "billing"])
    assert tag_names_for(org_a, ticket_a2.id) == MapSet.new(["urgent", "vip"])
    assert tag_names_for(org_a, ticket_a3.id) == MapSet.new([])
    assert tag_names_for(org_b, ticket_b1.id) == MapSet.new(["urgent"])

    # -- CROSS-ORG tag reuse: "urgent" is TWO distinct live Tag rows --------
    urgent_a = live_tag!(org_a, "urgent")
    urgent_b = live_tag!(org_b, "urgent")
    assert urgent_a.id != urgent_b.id
    assert urgent_a.org_id == org_a
    assert urgent_b.org_id == org_b

    # -- the SHARED tag within org_a is ONE Tag row, referenced by BOTH tickets --
    taggings_for_urgent_a =
      Tagging |> Ash.Query.filter(tag_id == ^urgent_a.id) |> Ash.read!(scope: tenant_scope(org_a))

    assert Enum.map(taggings_for_urgent_a, & &1.subject_id) |> Enum.sort() ==
             Enum.sort([ticket_a1.id, ticket_a2.id])

    # -- Ticket tag READS equivalent post-migration (the production helper) --
    assert SupportReads.ticket_tag_names(support_mount(), tenant_scope(org_a), ticket_a1.id) |> Enum.sort() ==
             ["billing", "urgent"]

    assert SupportReads.ticket_tag_names(support_mount(), tenant_scope(org_a), ticket_a3.id) == []

    # -- Ticket tag FILTER equivalent post-migration: "tickets with tag urgent" --
    ticket_ids_with_urgent_in_org_a =
      Tagging
      |> Ash.Query.filter(tag_id == ^urgent_a.id)
      |> Ash.read!(scope: tenant_scope(org_a))
      |> Enum.map(& &1.subject_id)
      |> Enum.sort()

    assert ticket_ids_with_urgent_in_org_a == Enum.sort([ticket_a1.id, ticket_a2.id])

    # -- IDEMPOTENCY: a second run adds no duplicate rows --------------------
    tag_count_before = Tag |> Ash.read!(scope: tenant_scope(org_a)) |> length()
    tagging_count_before = Tagging |> Ash.read!(scope: tenant_scope(org_a)) |> length()

    run_real_migration!()

    assert Tag |> Ash.read!(scope: tenant_scope(org_a)) |> length() == tag_count_before
    assert Tagging |> Ash.read!(scope: tenant_scope(org_a)) |> length() == tagging_count_before
  end

  # -- helpers -----------------------------------------------------------------

  defp tag_names_for(org_id, ticket_id) do
    SupportReads.ticket_tag_names(support_mount(), tenant_scope(org_id), ticket_id) |> MapSet.new()
  end

  defp live_tag!(org_id, name) do
    Tag
    |> Ash.Query.ensure_selected([:name, :color, :org_id])
    |> Ash.Query.filter(name == ^name)
    |> Ash.read!(scope: tenant_scope(org_id))
    |> hd()
  end

  defp ensure_tags_column! do
    unless column_exists?("wsk_ticket", "wsk_tags") do
      Repo.query!("ALTER TABLE wsk_ticket ADD COLUMN wsk_tags text[] DEFAULT '{}'")
    end
  end

  defp column_exists?(table, column) do
    %{rows: rows} =
      Repo.query!(
        "SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = $1 AND column_name = $2",
        [table, column]
      )

    rows != []
  end

  # Insert a ticket DIRECTLY via Ash (wsk_tags still exists pre-migration —
  # the fixture host has not run MigrateTicketTagsToTagScope yet at this
  # point in the sandboxed test transaction).
  defp insert_ticket!(org_id, subject, tags) do
    scope = tenant_scope(org_id)

    Ticket
    |> Ash.Changeset.for_create(:create, %{org_id: org_id, subject: subject, status: :open}, scope: scope)
    |> Ash.create!()
    |> then(fn ticket ->
      Repo.query!("UPDATE wsk_ticket SET wsk_tags = $1 WHERE wsk_id = $2", [
        tags,
        Ecto.UUID.dump!(ticket.id)
      ])

      ticket
    end)
  end

  # Run the REAL migration module's up/0 through Ecto.Migrator (mirrors
  # Samen.Web.CRMActivityMigrationTest's run_real_migration!/0). `migration_lock:
  # false` — a single test process is the only migrator.
  defp run_real_migration! do
    version = 90_000_000_000_000 + System.unique_integer([:positive])
    Ecto.Migrator.run(Repo, [{version, @migration}], :up, all: true, log: false, migration_lock: false)
  end
end
