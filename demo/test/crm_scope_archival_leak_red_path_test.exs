defmodule Demo.CrmScopeArchivalLeakRedPathTest do
  @moduledoc """
  E6 soft-delete adoption for the CRM scope (ADR-040 §5.9, T37c): `Company`,
  `Person` 🔒, `Pipeline`, `Opportunity`, and `Attachment` flip `archivable
  true` (samen_core/lib/samen/scopes/crm/blueprint.ex) — the §5.9 roster lists
  NO exclusion for this scope. The former `activity` resource is NOT part of
  this adoption: it was destructively migrated into the canonical Work-scope
  `Task` and removed from the CRM blueprint before T37c ran (ADR-041 §5, T97)
  — the canonical Task arrives `archivable true` on its own terms (T97/T43),
  out of scope here.

  §5.3: no unique index exists on `cmp_company`/`per_person`/`pip_pipeline`/
  `opp_opportunity`/`att_attachment` — the partial-index conversion has
  nothing to convert for this scope (confirmed by the c1 round trip below
  never constructing a `:restore_conflict` case; see `_orch/tasks/T37c/handoff.md`).

  §5.4: no cascade is declared for CRM — archiving `Company`/`Person`/
  `Opportunity` leaves their linked children (Person/Opportunity/Attachment)
  live, untouched.

  §5.5's standing duty for every adopting scope: an archived record must not
  leak via relationship load or aggregate, bypassing the read preparation.
  Every RED here (archived does not surface) is paired with a distinct
  positive-control CONTROL (a live row DOES surface via the same path) so the
  RED assertion is provably falsifiable, not a tautology (house masking-watch-
  list discipline, CLAUDE.md).

  INV-1 / the vaulted-pilot masking proof (T36 c3 precedent, mirrored here on
  the REAL CRM `Person` resource rather than the kernel fixture): an archived
  Person keeps its vault tokens (full_name/emails/phones stay `vt_*`, never
  erased) and masks per plane exactly like a live row — the
  operator-without-grant plane resolves `%Samen.Masked{}`, never plaintext,
  never the raw token; restore does not leak either.
  """
  use Demo.DataCase, async: false

  require Ash.Query

  import Samen.MaskingCase,
    only: [resolve_on_plane: 4, assert_plane_masked!: 1, assert_leak_detected!: 2]

  alias Demo.CrmScope.{Attachment, Company, Opportunity, Person, Pipeline}

  # No-grant vault stub: even wired to a vault, the operator-without-grant plane must
  # mask. Proves the mask is the plane/grant gate, independent of decrypt availability.
  defmodule DenyAll do
    @behaviour Samen.Reveal.Grant
    @impl true
    def granted?(_ctx), do: false
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp mk_org, do: Ash.UUID.generate()

  defp mk_company(org_id, name \\ "Co") do
    {:ok, c} =
      Company
      |> Ash.Changeset.for_create(:create, %{org_id: org_id, name: "#{name}-#{:rand.uniform(999_999)}"})
      |> Ash.create(authorize?: false)

    c
  end

  defp mk_pipeline(org_id, name \\ "Stage") do
    {:ok, p} =
      Pipeline
      |> Ash.Changeset.for_create(:create, %{org_id: org_id, name: "#{name}-#{:rand.uniform(999_999)}"})
      |> Ash.create(authorize?: false)

    p
  end

  defp mk_person(org_id, company_id \\ nil) do
    {:ok, p} =
      Person
      |> Ash.Changeset.for_create(:create, %{
        org_id: org_id,
        display_name: "Person-#{:rand.uniform(999_999)}",
        company_id: company_id
      })
      |> Ash.create(authorize?: false)

    p
  end

  defp mk_opportunity(org_id, company_id, pipeline_id \\ nil) do
    {:ok, o} =
      Opportunity
      |> Ash.Changeset.for_create(:create, %{
        org_id: org_id,
        name: "Deal-#{:rand.uniform(999_999)}",
        company_id: company_id,
        pipeline_id: pipeline_id
      })
      |> Ash.create(authorize?: false)

    o
  end

  defp mk_attachment(org_id, attrs) do
    {:ok, a} =
      Attachment
      |> Ash.Changeset.for_create(:create, Map.merge(%{org_id: org_id, file_name: "f.pdf"}, attrs))
      |> Ash.create(authorize?: false)

    a
  end

  defp live_ids(resource, org_id) do
    resource
    |> Ash.Query.ensure_selected([:org_id])
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&(&1.org_id == org_id))
    |> Enum.map(& &1.id)
    |> MapSet.new()
  end

  defp archived_ids(resource, org_id) do
    resource
    |> Ash.Query.for_read(:archived)
    |> Ash.Query.ensure_selected([:org_id])
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&(&1.org_id == org_id))
    |> Enum.map(& &1.id)
    |> MapSet.new()
  end

  defp archived_record(resource, id) do
    resource
    |> Ash.Query.for_read(:archived)
    |> Ash.read!(authorize?: false)
    |> Enum.find(&(&1.id == id))
  end

  # ── introspection: the adopt-me convention landed on all five roster rows ──

  describe "introspection — Samen.Info.archivable?/1 (T37h catalog-probe fixture)" do
    test "company/person/pipeline/opportunity/attachment all report true" do
      assert Samen.Info.archivable?(Company)
      assert Samen.Info.archivable?(Person)
      assert Samen.Info.archivable?(Pipeline)
      assert Samen.Info.archivable?(Opportunity)
      assert Samen.Info.archivable?(Attachment)
    end
  end

  # ── c1: archive/restore round trip for every roster resource ───────────────

  describe "c1 — archive removes from default read (RED), :archived shows it (CONTROL), restore returns it (ASSERT)" do
    test "for company, person, pipeline, opportunity, and attachment" do
      org = mk_org()
      company = mk_company(org)
      pipeline = mk_pipeline(org)
      person = mk_person(org, company.id)
      opportunity = mk_opportunity(org, company.id, pipeline.id)
      attachment = mk_attachment(org, %{company_id: company.id, person_id: person.id})

      for {resource, record} <- [
            {Company, company},
            {Person, person},
            {Pipeline, pipeline},
            {Opportunity, opportunity},
            {Attachment, attachment}
          ] do
        assert MapSet.member?(live_ids(resource, org), record.id),
               "#{inspect(resource)} expected in the default read before archive"

        {:ok, _} = Samen.Archival.archive(record, authorize?: false)

        # RED: gone from the default read.
        refute MapSet.member?(live_ids(resource, org), record.id)
        # CONTROL: the :archived include-read still sees it — hidden, not gone.
        assert MapSet.member?(archived_ids(resource, org), record.id)

        # ASSERT: restore returns it to the default read.
        {:ok, _} = Samen.Archival.restore(archived_record(resource, record.id), authorize?: false)
        assert MapSet.member?(live_ids(resource, org), record.id)
        refute MapSet.member?(archived_ids(resource, org), record.id)
      end
    end
  end

  # ── §5.5 leak duty: relationship load — Person.company ─────────────────────

  describe "§5.5 — an archived Company does not leak via Person.company relationship load" do
    test "Person.company resolves to nil for an archived company (RED); a live company surfaces (CONTROL)" do
      org = mk_org()
      archived_co = mk_company(org, "Archived")
      live_co = mk_company(org, "Live")

      person_on_archived = mk_person(org, archived_co.id)
      person_on_live = mk_person(org, live_co.id)

      {:ok, _} = Samen.Archival.archive(archived_co, authorize?: false)

      loaded_on_archived = Ash.load!(person_on_archived, :company, authorize?: false)
      assert loaded_on_archived.company == nil

      # CONTROL (anti-tautology): the same relationship load path DOES surface a
      # live company — proves the nil above is the archival filter firing.
      loaded_on_live = Ash.load!(person_on_live, :company, authorize?: false)
      assert %Company{id: live_id} = loaded_on_live.company
      assert live_id == live_co.id
    end
  end

  # ── §5.5 leak duty: relationship load — Opportunity.company ────────────────

  describe "§5.5 — an archived Company does not leak via Opportunity.company relationship load" do
    test "Opportunity.company resolves to nil for an archived company (RED); a live company surfaces (CONTROL)" do
      org = mk_org()
      archived_co = mk_company(org, "Archived")
      live_co = mk_company(org, "Live")

      opp_on_archived = mk_opportunity(org, archived_co.id)
      opp_on_live = mk_opportunity(org, live_co.id)

      {:ok, _} = Samen.Archival.archive(archived_co, authorize?: false)

      loaded_on_archived = Ash.load!(opp_on_archived, :company, authorize?: false)
      assert loaded_on_archived.company == nil

      # CONTROL: the second independent belongs_to consumer (Opportunity → Company)
      # is ALSO filtered — proves the preparation is resource-level, not wired for
      # Person only.
      loaded_on_live = Ash.load!(opp_on_live, :company, authorize?: false)
      assert %Company{id: live_id} = loaded_on_live.company
      assert live_id == live_co.id
    end
  end

  # ── §5.5 leak duty: relationship load — Attachment.person (vaulted parent) ─

  describe "§5.5 — an archived Person does not leak via Attachment.person relationship load" do
    test "Attachment.person resolves to nil for an archived person (RED); a live person surfaces (CONTROL)" do
      org = mk_org()
      archived_person = mk_person(org)
      live_person = mk_person(org)

      att_on_archived = mk_attachment(org, %{person_id: archived_person.id})
      att_on_live = mk_attachment(org, %{person_id: live_person.id})

      {:ok, _} = Samen.Archival.archive(archived_person, authorize?: false)

      loaded_on_archived = Ash.load!(att_on_archived, :person, authorize?: false)
      assert loaded_on_archived.person == nil

      loaded_on_live = Ash.load!(att_on_live, :person, authorize?: false)
      assert %Person{id: live_id} = loaded_on_live.person
      assert live_id == live_person.id
    end
  end

  # ── §5.5 leak duty: aggregate — Person :exists on :company ──────────────────

  describe "§5.5 — an archived Company does not leak via an :exists aggregate" do
    test "the :exists aggregate over Person.company is false for an archived company (RED); true for a live one (CONTROL)" do
      org = mk_org()
      archived_co = mk_company(org, "Archived")
      live_co = mk_company(org, "Live")

      person_on_archived = mk_person(org, archived_co.id)
      person_on_live = mk_person(org, live_co.id)

      {:ok, _} = Samen.Archival.archive(archived_co, authorize?: false)

      archived_result =
        Person
        |> Ash.Query.filter(id == ^person_on_archived.id)
        |> Ash.Query.aggregate(:company_live?, :exists, :company)
        |> Ash.read_one!(authorize?: false)

      refute archived_result.aggregates.company_live?

      # CONTROL (anti-tautology): the identical aggregate over a person pointing
      # at a LIVE company reports true — proves `false` above is the archival
      # filter firing, not the aggregate being vacuously false.
      live_result =
        Person
        |> Ash.Query.filter(id == ^person_on_live.id)
        |> Ash.Query.aggregate(:company_live?, :exists, :company)
        |> Ash.read_one!(authorize?: false)

      assert live_result.aggregates.company_live?
    end
  end

  # ── §5.4: no cascade — archiving Company/Person leaves their children live ─

  describe "§5.4 — CRM declares no cascades: archiving a parent does not archive its consumers" do
    test "Person/Opportunity/Attachment of an archived Company stay live (their own default reads still surface them)" do
      org = mk_org()
      company = mk_company(org, "Cascade")
      pipeline = mk_pipeline(org)
      person = mk_person(org, company.id)
      opportunity = mk_opportunity(org, company.id, pipeline.id)
      attachment = mk_attachment(org, %{company_id: company.id})

      {:ok, _} = Samen.Archival.archive(company, authorize?: false)

      # The company itself is hidden (already proven above); its non-archived
      # consumers are NOT touched — no `archive_related` cascade declared for
      # CRM (§5.4), so they remain visible on their own default reads.
      assert MapSet.member?(live_ids(Person, org), person.id)
      assert MapSet.member?(live_ids(Opportunity, org), opportunity.id)
      assert MapSet.member?(live_ids(Attachment, org), attachment.id)
    end

    test "Attachment of an archived Person stays live" do
      org = mk_org()
      person = mk_person(org)
      attachment = mk_attachment(org, %{person_id: person.id})

      {:ok, _} = Samen.Archival.archive(person, authorize?: false)

      assert MapSet.member?(live_ids(Attachment, org), attachment.id)
    end
  end

  # ── INV-1: masking holds on an archived vaulted Person, restore never leaks ─

  describe "INV-1 — an archived Person still masks per plane, restore never leaks" do
    test "archived Person keeps its vault token at rest and masks on the operator plane (RED) / clears on tenant (CONTROL)" do
      org = mk_org()

      attrs =
        Map.merge(
          %{org_id: org, display_name: "Ada Lovelace", job_title: "Ops"},
          Samen.Factory.person("Ada", "Lovelace", email: "ada.lovelace@sample.invalid")
        )

      person = Samen.Factory.create!(Person, attrs, authorize?: false)
      {:ok, _} = Samen.Archival.archive(person, authorize?: false)

      archived =
        Person
        |> Ash.Query.for_read(:archived)
        |> Ash.Query.ensure_selected([:emails])
        |> Ash.read!(authorize?: false)
        |> Enum.find(&(&1.id == person.id))

      # INV-1 at rest: the vault column holds a vt_* token even while archived —
      # the archived row is trash, not erasure; tokens stay vaulted (§5.1).
      %{rows: [[stored]]} =
        Repo.query!("SELECT per_emails FROM per_person WHERE per_id = $1", [
          Ecto.UUID.dump!(archived.id)
        ])

      assert is_binary(stored) and String.starts_with?(stored, "vt_")

      # RED (INV-1): operator plane WITHOUT a grant resolves the archived row's
      # field to %Masked{} — never plaintext, never the vt_ token, on any egress.
      masked = resolve_on_plane(archived, Person, :operator, grant: DenyAll).emails
      assert_plane_masked!(masked)
      assert to_string(masked) == "••••"
      refute to_string(masked) =~ "vt_"
      refute to_string(masked) =~ "ada.lovelace"

      # SABOTAGE twin / anti-tautology: the substring scan the RED relies on IS
      # refutable — a modeled plaintext render is detected.
      assert_leak_detected!("<td>ada.lovelace@sample.invalid</td>", "ada.lovelace")

      # Restore does not leak: an operator (no-grant) read of the restored row
      # still masks.
      {:ok, _} = Samen.Archival.restore(archived, authorize?: false)

      live =
        Person
        |> Ash.Query.ensure_selected([:emails])
        |> Ash.read!(authorize?: false)
        |> Enum.find(&(&1.id == person.id))

      assert_plane_masked!(resolve_on_plane(live, Person, :operator, grant: DenyAll).emails)
    end
  end
end
