defmodule Samen.TagsScopeTest do
  @moduledoc """
  The Tags scope (F4, T46) — Tag + polymorphic Tagging, mounted via
  `test/support/tags_fixture.ex`. Every red-path pairs denial with a positive
  control (anti-tautology, the `Samen.RedPath` / masking-watch-list house style —
  CLAUDE.md):

    * c1 CRUD via governed actions + org-scoped reads (cross-org RED / own-org
      CONTROL, org-less fail-closed);
    * c2 org-scoped uniqueness: a duplicate Tag name within the SAME org is
      refused (RED); the SAME name in a DIFFERENT org succeeds (CONTROL); an
      ARCHIVED Tag's name is reusable (the ADR-040 §5.3 partial-index promise);
    * c3 palette enum validation: an out-of-palette color is refused (RED); every
      palette member is accepted (CONTROL);
    * c4 polymorphic tagging on ≥2 resource types: the SAME Tag attaches to two
      DIFFERENT subject_key kinds (done-criterion 1);
    * c5 archive/restore (ADR-040 §5.9) on Tag; Tagging has NO archive surface
      (a pure join — destroy is the only removal path);
    * c6 INV-1 — Tagging cannot leak the tagged object's vault fields (structural
      proof: no attribute exists to carry it) + Tag/Tagging carry no PII
      themselves (declaration proof, mirrors Work's PII-free proof);
    * c7 same-org Tagging FK guard: a Tagging can never reference another org's
      Tag (`Samen.Policy.SameOrgFk`, RED/CONTROL);
    * c8 catalog registration — `mix samen.verify.catalog_parity` is green.
  """
  use ExUnit.Case, async: false

  require Ash.Query

  alias Samen.Archival
  alias SamenCore.Support.TagsFixture.{Tag, Tagging}

  @repo SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    org = Ash.UUID.generate()
    {:ok, org: org, scope: tenant_scope(org)}
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp tenant_scope(org_id) do
    %Samen.Scope{
      actor: %{id: "u:#{org_id}", org_id: org_id, role: :member, kind: :tenant, plane: :tenant}
    }
  end

  defp new_tag(scope, org, attrs \\ %{}) do
    Tag
    |> Ash.Changeset.for_create(:create, Map.merge(%{org_id: org, name: "vip"}, attrs), scope: scope)
    |> Ash.create!()
  end

  defp new_tagging(scope, org, tag_id, attrs \\ %{}) do
    Tagging
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(%{org_id: org, tag_id: tag_id, subject_key: "crm.person", subject_id: Ash.UUID.generate()}, attrs),
      scope: scope
    )
    |> Ash.create!()
  end

  defp tag_ids(scope), do: Tag |> Ash.read!(scope: scope) |> Enum.map(& &1.id) |> MapSet.new()
  defp archived_tags(scope), do: Tag |> Ash.Query.for_read(:archived) |> Ash.read!(scope: scope)

  # ── c1: CRUD via governed actions; org-scoped reads ───────────────────────

  describe "c1 — CRUD via governed actions; org-scoped reads" do
    test "create/read/update/destroy(=archive) a Tag", %{org: org, scope: scope} do
      t = new_tag(scope, org, %{name: "urgent", color: :red})
      assert t.name == "urgent"
      assert t.color == :red

      [read] = Tag |> Ash.read!(scope: scope)
      assert read.id == t.id

      updated = t |> Ash.Changeset.for_update(:update, %{color: :orange}, scope: scope) |> Ash.update!()
      assert updated.color == :orange

      :ok = Ash.destroy!(t, scope: scope)
      assert Tag |> Ash.read!(scope: scope) == []
    end

    test "create/read/destroy a Tagging (the polymorphic join)", %{org: org, scope: scope} do
      tag = new_tag(scope, org)
      tg = new_tagging(scope, org, tag.id)
      assert tg.tag_id == tag.id

      [read] = Tagging |> Ash.read!(scope: scope)
      assert read.id == tg.id

      :ok = Ash.destroy!(tg, scope: scope)
      assert Tagging |> Ash.read!(scope: scope) == []
    end

    test "an actor never reads another org's Tags/Taggings (RED); reads its own org's (CONTROL)" do
      org_a = Ash.UUID.generate()
      org_b = Ash.UUID.generate()
      scope_a = tenant_scope(org_a)
      scope_b = tenant_scope(org_b)

      tag_a = new_tag(scope_a, org_a, %{name: "a-tag"})
      _tag_b = new_tag(scope_b, org_b, %{name: "b-tag"})
      tagging_a = new_tagging(scope_a, org_a, tag_a.id)
      _tagging_b = new_tagging(scope_b, org_b, new_tag(scope_b, org_b, %{name: "b-tag-2"}).id)

      seen_tags = Tag |> Ash.read!(scope: scope_a) |> Enum.map(& &1.id)
      seen_taggings = Tagging |> Ash.read!(scope: scope_a) |> Enum.map(& &1.id)

      assert tag_a.id in seen_tags and length(seen_tags) == 1
      assert tagging_a.id in seen_taggings and length(seen_taggings) == 1
    end

    test "an org-less actor sees zero Tags/Taggings (fail closed)", %{org: org, scope: scope} do
      tag = new_tag(scope, org)
      _tg = new_tagging(scope, org, tag.id)

      orgless = %Samen.Scope{actor: %{id: "nobody", org_id: nil, role: :member}}

      case Ash.read(Tag, scope: orgless) do
        {:ok, seen} -> assert seen == []
        {:error, %Ash.Error.Forbidden{}} -> assert true
      end

      case Ash.read(Tagging, scope: orgless) do
        {:ok, seen} -> assert seen == []
        {:error, %Ash.Error.Forbidden{}} -> assert true
      end
    end
  end

  # ── c2: org-scoped uniqueness (done-criterion 1) ──────────────────────────

  describe "c2 — org-scoped uniqueness" do
    test "RED: a duplicate Tag name within the SAME org is refused", %{org: org, scope: scope} do
      _t1 = new_tag(scope, org, %{name: "vip"})

      result =
        Tag
        |> Ash.Changeset.for_create(:create, %{org_id: org, name: "vip"}, scope: scope)
        |> Ash.create()

      assert {:error, _} = result
      assert Tag |> Ash.read!(scope: scope) |> length() == 1
    end

    test "CONTROL: the SAME Tag name in a DIFFERENT org succeeds (anti-tautology)" do
      org_a = Ash.UUID.generate()
      org_b = Ash.UUID.generate()

      t_a = new_tag(tenant_scope(org_a), org_a, %{name: "vip"})
      t_b = new_tag(tenant_scope(org_b), org_b, %{name: "vip"})

      assert t_a.name == "vip"
      assert t_b.name == "vip"
      assert t_a.id != t_b.id
    end

    test "an ARCHIVED Tag's name is reusable (ADR-040 §5.3 partial-index promise)",
         %{org: org, scope: scope} do
      t = new_tag(scope, org, %{name: "seasonal"})
      {:ok, _} = Archival.archive(t, scope: scope)

      # The live slot is free again — a NEW live Tag may claim the same name.
      reclaimed = new_tag(scope, org, %{name: "seasonal"})
      assert reclaimed.name == "seasonal"
      assert reclaimed.id != t.id
    end
  end

  # ── c3: palette enum validation (c7: bounded, not free hex) ───────────────

  describe "c3 — bounded color palette (spec-questions c7)" do
    test "RED: an out-of-palette color is refused", %{org: org, scope: scope} do
      result =
        Tag
        |> Ash.Changeset.for_create(:create, %{org_id: org, name: "x", color: :"#ff00ff"}, scope: scope)
        |> Ash.create()

      assert {:error, %Ash.Error.Invalid{}} = result
      assert Tag |> Ash.read!(scope: scope) == []
    end

    test "CONTROL: every palette member is accepted (anti-tautology — not a blanket refusal)",
         %{org: org, scope: scope} do
      for {color, idx} <- Enum.with_index([:gray, :red, :orange, :yellow, :green, :teal, :blue, :purple, :pink]) do
        t = new_tag(scope, org, %{name: "palette-#{idx}", color: color})
        assert t.color == color
      end
    end

    test "CONTROL: the default color is :gray (bounded default, not free)", %{org: org, scope: scope} do
      t = new_tag(scope, org)
      assert t.color == :gray
    end
  end

  # ── c4: polymorphic tagging on ≥2 resource types ──────────────────────────

  describe "c4 — polymorphic tagging on multiple resource types (done-criterion 1)" do
    test "the SAME Tag attaches to TWO different subject_key kinds", %{org: org, scope: scope} do
      tag = new_tag(scope, org, %{name: "vip"})

      ticket_id = Ash.UUID.generate()
      person_id = Ash.UUID.generate()

      on_ticket = new_tagging(scope, org, tag.id, %{subject_key: "support.ticket", subject_id: ticket_id})
      on_person = new_tagging(scope, org, tag.id, %{subject_key: "crm.person", subject_id: person_id})

      assert on_ticket.subject_key == "support.ticket"
      assert on_ticket.subject_id == ticket_id
      assert on_person.subject_key == "crm.person"
      assert on_person.subject_id == person_id

      all = Tagging |> Ash.Query.filter(tag_id == ^tag.id) |> Ash.read!(scope: scope)
      assert length(all) == 2
      assert Enum.map(all, & &1.subject_key) |> Enum.sort() == ["crm.person", "support.ticket"]
    end

    test "a Tag attaches to the SAME object at most once (unique per tag+subject)",
         %{org: org, scope: scope} do
      tag = new_tag(scope, org)
      subject_id = Ash.UUID.generate()

      _first = new_tagging(scope, org, tag.id, %{subject_key: "support.ticket", subject_id: subject_id})

      result =
        Tagging
        |> Ash.Changeset.for_create(
          :create,
          %{org_id: org, tag_id: tag.id, subject_key: "support.ticket", subject_id: subject_id},
          scope: scope
        )
        |> Ash.create()

      assert {:error, _} = result
    end
  end

  # ── c5: archive/restore (Tag only; Tagging has no archive surface) ───────

  describe "c5 — archive/restore (ADR-040 §5.9)" do
    test "Tag: archive hides it (RED), :archived shows it (CONTROL), restore returns it (ASSERT)",
         %{org: org, scope: scope} do
      t = new_tag(scope, org)
      {:ok, _} = Archival.archive(t, scope: scope)

      refute MapSet.member?(tag_ids(scope), t.id)
      assert Enum.any?(archived_tags(scope), &(&1.id == t.id))

      restored = archived_tags(scope) |> Enum.find(&(&1.id == t.id))
      {:ok, _} = Archival.restore(restored, scope: scope)
      assert MapSet.member?(tag_ids(scope), t.id)
    end

    test "double-archive is an idempotent no-op (archived_at does not move)", %{org: org, scope: scope} do
      t = new_tag(scope, org)
      {:ok, once} = Archival.archive(t, scope: scope)
      {:ok, twice} = Archival.archive(once, scope: scope)
      assert once.archived_at == twice.archived_at
    end

    test "Tagging is NOT archivable — it has no :archive action (a pure join row, destroy-only)" do
      refute Ash.Resource.Info.action(Tagging, :archive)
      refute Ash.Resource.Info.action(Tagging, :restore)
    end
  end

  # ── c6: INV-1 — a Tagging cannot leak the tagged object's vault fields ───

  describe "c6 — INV-1: Tagging structurally cannot leak the tagged object's PII" do
    test "Tagging carries no PII declaration (mirrors Work's PII-free proof)" do
      assert Samen.Pii.Info.fields(Tagging) == []
    end

    test "Tag carries no PII declaration (name/color are operator-authored labels)" do
      assert Samen.Pii.Info.fields(Tag) == []
    end

    test "Tagging's only attributes beyond the CoreAttributes id/org/timestamps are " <>
           "tag_id + subject_key + subject_id — no field exists to hold the subject's own data" do
      attr_names = Tagging |> Ash.Resource.Info.attributes() |> Enum.map(& &1.name) |> MapSet.new()

      # The full attribute set is closed — no snapshot/copy field of any kind.
      assert attr_names ==
               MapSet.new([:id, :org_id, :inserted_at, :updated_at, :tag_id, :subject_key, :subject_id])
    end
  end

  # ── c7: same-org Tagging FK guard ─────────────────────────────────────────

  describe "c7 — Samen.Policy.SameOrgFk: a Tagging can never reference another org's Tag" do
    test "RED: a cross-org tag_id is refused at create (DB unchanged)" do
      org_a = Ash.UUID.generate()
      org_b = Ash.UUID.generate()

      tag_b = new_tag(tenant_scope(org_b), org_b, %{name: "b-tag"})

      result =
        Tagging
        |> Ash.Changeset.for_create(
          :create,
          %{org_id: org_a, tag_id: tag_b.id, subject_key: "crm.person", subject_id: Ash.UUID.generate()},
          scope: tenant_scope(org_a)
        )
        |> Ash.create()

      assert {:error, _} = result
      assert Tagging |> Ash.read!(scope: tenant_scope(org_a)) == []
    end

    test "CONTROL: a same-org tag_id succeeds (anti-tautology)", %{org: org, scope: scope} do
      tag = new_tag(scope, org)
      tg = new_tagging(scope, org, tag.id)
      assert tg.tag_id == tag.id
    end
  end

  # ── c8: catalog registration ────────────────────────────────────────────────

  describe "c8 — catalog registration (mix samen.verify.catalog_parity is green)" do
    test "the Tags fixture's tables/columns are fully catalogued (no violations)" do
      violations =
        Mix.Tasks.Samen.Verify.CatalogParity.check(@repo)
        |> Enum.filter(&(&1 =~ "stt_tag" or &1 =~ "tst_tagging"))

      assert violations == [],
             "expected no catalog_parity violations for the Tags fixture tables, got: " <>
               inspect(violations)
    end
  end
end
