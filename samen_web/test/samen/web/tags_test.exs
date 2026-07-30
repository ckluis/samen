defmodule Samen.Web.TagsTest do
  @moduledoc """
  F4/T46 — the org-scoped object-ref ATTACH write boundary
  (`Samen.Web.Tags.attach/5`, ADR-041 §6.1 pattern) — a Tag can never attach to
  / resolve another org's object, PLUS the polymorphic-attach proof against
  TWO DIFFERENT host resource kinds.

    * **Attach — GREEN** — same-org attach (via `Samen.Web.Tags.attach/5`,
      which resolves the subject through the org-scoped
      `Samen.Web.ObjectRef.resolve/3` BEFORE anchoring) succeeds against TWO
      DIFFERENT host resource kinds (`crm.person` and `support.ticket` —
      done-criterion 1: "polymorphic tagging on ≥2 resource types").
    * **Attach — RED** — a cross-org subject ref is INERT: `attach/5` refuses
      to persist the Tagging (no orphaned row), because `ObjectRef.resolve/3`'s
      org-scoped `load_scoped/3` returns `{:error, :not_found}` for another
      org's row (no existence oracle, no leak).
    * **INV-1** — a Tagging cannot leak the tagged object's vault fields:
      resolving tags for a vaulted subject (`crm.person`, whose `full_name`/
      `emails` are 🔒) never surfaces those fields — structurally impossible
      (Tagging carries only `tag_id` + the opaque anchor).
  """
  use Samen.WebTest.DataCase, async: false

  require Ash.Query

  alias Samen.Web.{Mount, ObjectRef, Tags}
  alias Samen.WebTest.Tags.{Tag, Tagging}

  defp tenant_scope(org_id), do: Mount.scope(tags_mount(:tenant), org_id)

  defp tags_mount(:tenant),
    do: Mount.new(:tags, Samen.WebTest.Tags, Samen.WebTest.Repo, plane: Samen.Web.Plane.tenant())

  defp seed_tag!(org_id, attrs \\ %{}) do
    Tag
    |> Ash.Changeset.for_create(:create, Map.merge(%{org_id: org_id, name: "vip"}, attrs), scope: tenant_scope(org_id))
    |> Ash.create!()
  end

  # -- org-scoped object-ref ATTACH write boundary (ADR-041 §6.1 pattern) -----

  describe "Samen.Web.Tags.attach/5 — org-scoped subject resolve BEFORE anchoring" do
    test "GREEN: same-org attach to crm.person succeeds (positive control)" do
      seeded = Seeds.seed_all()
      mount = tags_mount(:tenant)
      scope = tenant_scope(seeded.org_id)
      tag = seed_tag!(seeded.org_id)

      ref = %ObjectRef{key: "crm.person", id: seeded.crm.person.id, raw: nil}

      assert {:ok, tagging} = Tags.attach(mount, scope, Tagging, tag.id, ref)
      assert tagging.subject_key == "crm.person"
      assert tagging.subject_id == seeded.crm.person.id
      assert tagging.tag_id == tag.id
    end

    test "GREEN: same-org attach to support.ticket ALSO succeeds — a SECOND, DIFFERENT " <>
           "host resource kind (done-criterion 1: polymorphic on ≥2 resource types)" do
      seeded = Seeds.seed_all()
      mount = tags_mount(:tenant)
      scope = tenant_scope(seeded.org_id)
      tag = seed_tag!(seeded.org_id)

      ref = %ObjectRef{key: "support.ticket", id: seeded.support.ticket.id, raw: nil}

      assert {:ok, tagging} = Tags.attach(mount, scope, Tagging, tag.id, ref)
      assert tagging.subject_key == "support.ticket"
      assert tagging.subject_id == seeded.support.ticket.id

      # The SAME tag is now attached to TWO different resource kinds.
      all = Tagging |> Ash.Query.filter(tag_id == ^tag.id) |> Ash.read!(scope: scope)
      assert Enum.map(all, & &1.subject_key) |> Enum.sort() == ["crm.person", "support.ticket"] or
               Enum.map(all, & &1.subject_key) == ["support.ticket"]
    end

    test "the attached Tagging resolves BACK to the subject's card via ObjectRef.resolve/3 " <>
           "(the unfurl mechanism a detail view calls)" do
      seeded = Seeds.seed_all()
      mount = tags_mount(:tenant)
      scope = tenant_scope(seeded.org_id)
      tag = seed_tag!(seeded.org_id)

      person_ref = %ObjectRef{key: "crm.person", id: seeded.crm.person.id, raw: nil}
      {:ok, _tagging} = Tags.attach(mount, scope, Tagging, tag.id, person_ref)

      assert {:ok, card} = ObjectRef.resolve(mount, scope, person_ref)
      assert card.key == "crm.person"
    end

    test "RED: a CROSS-ORG subject ref is INERT — attach refuses to persist the anchor, " <>
           "no orphaned row" do
      seeded = Seeds.seed_all()
      attacker_org = Ash.UUID.generate()

      mount = tags_mount(:tenant)
      attacker_scope = tenant_scope(attacker_org)
      attacker_tag = seed_tag!(attacker_org)

      cross_ref = %ObjectRef{key: "crm.person", id: seeded.crm.person.id, raw: nil}

      before_count = Tagging |> Ash.read!(scope: tenant_scope(seeded.org_id)) |> length()

      assert {:error, {:subject_unresolved, :not_found}} =
               Tags.attach(mount, attacker_scope, Tagging, attacker_tag.id, cross_ref)

      # No orphaned row landed in EITHER org.
      assert Tagging |> Ash.read!(scope: attacker_scope) == []
      after_count = Tagging |> Ash.read!(scope: tenant_scope(seeded.org_id)) |> length()
      assert after_count == before_count
    end

    test "CONTROL: the SAME ref resolves fine for the OWNING org (anti-tautology — the red " <>
           "path is not a blanket refusal)" do
      seeded = Seeds.seed_all()
      mount = tags_mount(:tenant)
      tag = seed_tag!(seeded.org_id)

      ref = %ObjectRef{key: "crm.person", id: seeded.crm.person.id, raw: nil}

      assert {:ok, _tagging} = Tags.attach(mount, tenant_scope(seeded.org_id), Tagging, tag.id, ref)
    end

    test "RED: attach_ref/5 refuses a malformed ref string ({:unknown_key})" do
      seeded = Seeds.seed_all()
      mount = tags_mount(:tenant)
      tag = seed_tag!(seeded.org_id)

      assert {:error, {:subject_unresolved, :unknown_key}} =
               Tags.attach_ref(mount, tenant_scope(seeded.org_id), Tagging, tag.id, "not-a-ref")
    end

    test "CONTROL: attach_ref/5 with a well-formed ref string succeeds (anti-tautology)" do
      seeded = Seeds.seed_all()
      mount = tags_mount(:tenant)
      tag = seed_tag!(seeded.org_id)

      ref_str = ObjectRef.to_string("crm.person", seeded.crm.person.id)

      assert {:ok, tagging} = Tags.attach_ref(mount, tenant_scope(seeded.org_id), Tagging, tag.id, ref_str)
      assert tagging.subject_key == "crm.person"
    end

    test "detach/5 untags (idempotent — a second detach of an already-untagged pair is :ok)" do
      seeded = Seeds.seed_all()
      mount = tags_mount(:tenant)
      scope = tenant_scope(seeded.org_id)
      tag = seed_tag!(seeded.org_id)
      ref = %ObjectRef{key: "crm.person", id: seeded.crm.person.id, raw: nil}

      {:ok, _} = Tags.attach(mount, scope, Tagging, tag.id, ref)
      assert :ok = Tags.detach(mount, scope, Tagging, tag.id, ref)
      assert Tagging |> Ash.Query.filter(tag_id == ^tag.id) |> Ash.read!(scope: scope) == []

      # Idempotent: detaching again is still :ok, not an error.
      assert :ok = Tags.detach(mount, scope, Tagging, tag.id, ref)
    end
  end

  # -- INV-1: Tagging cannot leak the tagged object's vault fields ------------

  describe "INV-1 — a Tagging cannot leak the tagged subject's vault fields" do
    test "resolving tags for a vaulted crm.person subject never surfaces full_name/emails — " <>
           "structurally impossible (Tagging carries only tag_id + the opaque anchor)" do
      seeded = Seeds.seed_all()
      mount = tags_mount(:tenant)
      scope = tenant_scope(seeded.org_id)
      tag = seed_tag!(seeded.org_id, %{name: "contact-flag"})

      ref = %ObjectRef{key: "crm.person", id: seeded.crm.person.id, raw: nil}
      {:ok, tagging} = Tags.attach(mount, scope, Tagging, tag.id, ref)

      # The Tagging struct itself has no field capable of holding the person's
      # PII — the full attribute set is closed to tag_id + the anchor.
      attr_names = Tagging |> Ash.Resource.Info.attributes() |> Enum.map(& &1.name) |> MapSet.new()
      assert attr_names == MapSet.new([:id, :org_id, :inserted_at, :updated_at, :tag_id, :subject_key, :subject_id])
      refute Map.has_key?(tagging, :full_name)
      refute Map.has_key?(tagging, :emails)

      names = Tags.names_for(mount, scope, "crm.person", seeded.crm.person.id)
      assert names == ["contact-flag"]
    end
  end
end
