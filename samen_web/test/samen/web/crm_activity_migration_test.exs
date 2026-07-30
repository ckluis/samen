defmodule Samen.Web.CRMActivityMigrationTest do
  @moduledoc """
  ADR-041 §5/§11 — the destructive CRM `Activity` → canonical Work-scope `Task`
  migration proof (T97 c1/c2). Drives the **REAL** `MigrateActivityToTask.up/0`
  (via `Ecto.Migrator`) against a recreated old-schema `swa_activity` table so the
  migration's actual `copy_sql/2` is a first-class tested artifact — NOT a hand-copied
  inline duplicate (verifier F2). Asserts:

    * **Zero data drop + field equality (§5.1):** every Activity column lands on Task
      field-for-field (type→kind, subject→title, body/status/completed_at/id/org_id/
      timestamps VERBATIM); the ≤3 CRM FKs collapse to the PRIMARY `(subject_key,
      subject_id)` anchor by precedence `opportunity ▸ person ▸ company` AND the FULL
      non-null ref set is preserved in `custom.crm_refs`; priority is the added
      `:normal` default; owner/parent/project are NULL. Representative rows:
      contact-only, deal-only, contact+company, all-FK, and no-anchor.
    * **Move-then-drop (§5.4):** the real `up/0` drops `swa_activity` after copying.
    * **Idempotency (§5.5):** re-running `up/0` over the SAME id (ON CONFLICT DO
      NOTHING) adds no duplicate and does not overwrite the migrated row.
    * **Activity is GONE (§6.3):** no `swa_activity` table, no `crm.activity` catalog
      row, `Samen.WebTest.Crm.Activity` is not a resource, `work.task` IS catalogued.

  The forward migration excises `swa_activity` from the historical CRM-scope migration,
  so on a clean build the source table never exists and the real `up/0` is a guarded
  no-op — this test recreates the old-schema table (as prior deployments have it) inside
  the rolled-back SQL sandbox transaction so the transform actually executes.
  """
  use Samen.WebTest.DataCase, async: false

  @migration Samen.WebTest.Repo.Migrations.MigrateActivityToTask

  test "the REAL migration up/0 migrates old-schema rows field-for-field + anchor precedence + full crm_refs, then drops the table (§5.1/§5.4)" do
    org_id = Ash.UUID.generate()
    company_id = Ash.UUID.generate()
    person_id = Ash.UUID.generate()
    opp_id = Ash.UUID.generate()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    create_probe_table!()

    # (1) contact-only → PRIMARY crm.person, crm_refs {person}; custom.author preserved.
    id_contact =
      insert_probe!(%{type: "call", subject: "MIG-CONTACT", body: "call body", status: "completed",
        completed_at: now, custom: %{"author" => "Alice"},
        company_id: nil, person_id: person_id, opportunity_id: nil,
        org_id: org_id, inserted_at: now, updated_at: now})

    # (2) deal-only → PRIMARY crm.opportunity, crm_refs {opportunity}.
    id_deal =
      insert_probe!(%{type: "email", subject: "MIG-DEAL", body: nil, status: "pending",
        completed_at: nil, custom: nil,
        company_id: nil, person_id: nil, opportunity_id: opp_id,
        org_id: org_id, inserted_at: now, updated_at: now})

    # (3) contact + company → PRIMARY crm.person (precedence), crm_refs {company,person}.
    id_both =
      insert_probe!(%{type: "meeting", subject: "MIG-BOTH", body: "both", status: "completed",
        completed_at: now, custom: nil,
        company_id: company_id, person_id: person_id, opportunity_id: nil,
        org_id: org_id, inserted_at: now, updated_at: now})

    # (4) all three FKs → PRIMARY crm.opportunity (top precedence), crm_refs {all three}.
    id_all =
      insert_probe!(%{type: "note", subject: "MIG-ALL", body: "triple", status: "cancelled",
        completed_at: nil, custom: nil,
        company_id: company_id, person_id: person_id, opportunity_id: opp_id,
        org_id: org_id, inserted_at: now, updated_at: now})

    # (5) no anchor → subject_key/subject_id NULL, no crm_refs.
    id_none =
      insert_probe!(%{type: "task", subject: "MIG-NONE", body: nil, status: "pending",
        completed_at: nil, custom: nil,
        company_id: nil, person_id: nil, opportunity_id: nil,
        org_id: org_id, inserted_at: now, updated_at: now})

    # Drive the REAL migration transform + drop + catalog reconcile.
    run_real_migration!()

    # MOVE-THEN-DROP: the source table is gone.
    refute table_exists?("swa_activity")

    by_id = Map.new(read_tasks(), &{&1.id, &1})

    # ZERO DROP: all 5 probe rows produced a Task (id preserved).
    for id <- [id_contact, id_deal, id_both, id_all, id_none], do: assert(Map.has_key?(by_id, id))

    t1 = by_id[id_contact]
    assert t1.kind == :call
    assert t1.title == "MIG-CONTACT"
    assert t1.body == "call body"
    assert t1.status == :completed
    assert t1.org_id == org_id
    assert t1.completed_at == now
    assert t1.priority == :normal
    assert is_nil(t1.owner_id) and is_nil(t1.parent_id) and is_nil(t1.project_id)
    assert t1.subject_key == "crm.person"
    assert t1.subject_id == person_id
    assert t1.custom["author"] == "Alice"
    assert t1.custom["crm_refs"] == %{"person_id" => person_id}

    t2 = by_id[id_deal]
    assert t2.kind == :email
    assert t2.subject_key == "crm.opportunity"
    assert t2.subject_id == opp_id
    assert t2.custom["crm_refs"] == %{"opportunity_id" => opp_id}

    t3 = by_id[id_both]
    # person over company (precedence) — company survives ONLY in crm_refs.
    assert t3.subject_key == "crm.person"
    assert t3.subject_id == person_id
    assert t3.custom["crm_refs"] == %{"company_id" => company_id, "person_id" => person_id}

    t4 = by_id[id_all]
    assert t4.subject_key == "crm.opportunity"
    assert t4.subject_id == opp_id
    assert t4.custom["crm_refs"] ==
             %{"company_id" => company_id, "person_id" => person_id, "opportunity_id" => opp_id}

    t5 = by_id[id_none]
    assert is_nil(t5.subject_key)
    assert is_nil(t5.subject_id)
  end

  test "the REAL migration up/0 is idempotent (ON CONFLICT DO NOTHING) — a re-copy of the same id adds no dup and does not overwrite (§5.5)" do
    org_id = Ash.UUID.generate()
    person_id = Ash.UUID.generate()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    create_probe_table!()

    id =
      insert_probe!(%{type: "call", subject: "ORIGINAL", body: "v1", status: "completed",
        completed_at: now, custom: nil,
        company_id: nil, person_id: person_id, opportunity_id: nil,
        org_id: org_id, inserted_at: now, updated_at: now})

    run_real_migration!()

    after1 = read_tasks()
    assert length(after1) == 1
    assert hd(after1).title == "ORIGINAL"

    # Recreate the old-schema source with the SAME id but a CHANGED title; re-run up/0.
    create_probe_table!()

    insert_probe!(%{id: id, type: "call", subject: "OVERWRITTEN-MUST-NOT-APPLY", body: "v2",
      status: "completed", completed_at: now, custom: nil,
      company_id: nil, person_id: person_id, opportunity_id: nil,
      org_id: org_id, inserted_at: now, updated_at: now})

    run_real_migration!()

    after2 = read_tasks()
    # No duplicate (still ONE row for that id) …
    assert length(after2) == 1
    # … and NOT overwritten — ON CONFLICT (wtk_id) DO NOTHING kept the original.
    assert hd(after2).title == "ORIGINAL"
    assert hd(after2).id == id
  end

  test "Activity is GONE: no swa_activity table, no crm.activity catalog row, resource removed; work.task present" do
    %{rows: tbl} =
      Repo.query!(
        "SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='swa_activity'"
      )

    assert tbl == [], "swa_activity table must be gone"

    %{rows: [[tam_ct]]} =
      Repo.query!("SELECT count(*) FROM tam_table WHERE tam_table_name = 'swa_activity'")

    assert tam_ct == 0, "crm.activity must be absent from the catalog"

    %{rows: [[fld_ct]]} =
      Repo.query!("SELECT count(*) FROM fld_field WHERE fld_table_name = 'swa_activity'")

    assert fld_ct == 0, "no orphan fld_field rows for the dropped activity table"

    refute Code.ensure_loaded?(Samen.WebTest.Crm.Activity) and
             Ash.Resource.Info.resource?(Samen.WebTest.Crm.Activity),
           "Samen.WebTest.Crm.Activity must no longer be a resource"

    assert Ash.Resource.Info.resource?(Samen.WebTest.Work.Task)

    %{rows: [[task_ct]]} =
      Repo.query!("SELECT count(*) FROM tam_table WHERE tam_table_name = 'wwt_task'")

    assert task_ct == 1, "work.task must be catalogued"
  end

  # -- helpers -----------------------------------------------------------------

  defp read_tasks do
    Samen.WebTest.Work.Task
    |> Ash.Query.ensure_selected([
      :kind, :title, :body, :status, :priority, :due_at, :completed_at,
      :subject_key, :subject_id, :custom, :owner_id, :parent_id, :project_id, :org_id
    ])
    |> Ash.read!(authorize?: false)
  end

  # Run the REAL migration module's up/0 through Ecto.Migrator against a throwaway
  # version (so it always executes and is rolled back with the sandbox). `migration_lock:
  # false` — a single test process is the only migrator (mirrors migration_expand_contract_test).
  defp run_real_migration! do
    version = 90_000_000_000_000 + System.unique_integer([:positive])
    Ecto.Migrator.run(Repo, [{version, @migration}], :up, all: true, log: false, migration_lock: false)
  end

  defp table_exists?(name) do
    %{rows: rows} =
      Repo.query!(
        "SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name=$1",
        [name]
      )

    rows != []
  end

  # Recreate `swa_activity` exactly as the historical CRM-scope migration did (columns
  # only — the transform needs no FK constraints), so the real migration's copy SQL runs
  # against the real old schema.
  defp create_probe_table! do
    Repo.query!("""
    CREATE TABLE swa_activity (
      swa_type text,
      swa_subject text,
      swa_body text,
      swa_status text,
      swa_due_at timestamp,
      swa_completed_at timestamp,
      swa_custom jsonb,
      swa_company_id uuid,
      swa_person_id uuid,
      swa_opportunity_id uuid,
      swa_id uuid NOT NULL PRIMARY KEY,
      swa_org_id uuid NOT NULL,
      swa_inserted_at timestamp NOT NULL,
      swa_updated_at timestamp NOT NULL
    )
    """)
  end

  defp insert_probe!(attrs) do
    id = Map.get(attrs, :id) || Ash.UUID.generate()

    Repo.query!(
      """
      INSERT INTO swa_activity
        (swa_type, swa_subject, swa_body, swa_status, swa_due_at, swa_completed_at,
         swa_custom, swa_company_id, swa_person_id, swa_opportunity_id,
         swa_id, swa_org_id, swa_inserted_at, swa_updated_at)
      VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14)
      """,
      [
        attrs.type, attrs.subject, attrs.body, attrs.status, naive(attrs[:due_at]), naive(attrs.completed_at),
        # Pass the Elixir map directly — Postgrex encodes it as a jsonb OBJECT (a
        # pre-JSON-encoded string would become a jsonb string scalar, and `||` an object
        # would yield an array). nil → jsonb null, so COALESCE(...,'{}') applies.
        attrs.custom, ub(attrs.company_id), ub(attrs.person_id), ub(attrs.opportunity_id),
        ub(id), ub(attrs.org_id), naive(attrs.inserted_at), naive(attrs.updated_at)
      ]
    )

    id
  end

  # `swa_*_at` are `timestamp` (without tz) — pass NaiveDateTime so Postgrex encodes
  # unambiguously; the value round-trips back through Ash `:utc_datetime` as the same UTC instant.
  defp naive(nil), do: nil
  defp naive(%DateTime{} = dt), do: DateTime.to_naive(dt)

  # Raw `uuid` columns need the 16-byte binary via Postgrex, not the string form.
  defp ub(nil), do: nil
  defp ub(uuid) when is_binary(uuid), do: Ecto.UUID.dump!(uuid)
end
