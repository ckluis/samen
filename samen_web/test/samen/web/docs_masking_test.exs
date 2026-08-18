defmodule Samen.Web.DocsMaskingTest do
  @moduledoc """
  F3 / INV-1 (NON-NEGOTIABLE): the Docs scope's `secure_body` masking three-proof,
  AND the org-scoped object-ref ATTACH write boundary (`Samen.Web.Docs.attach/5`,
  ADR-041 §6.1 pattern) — a Note/Doc can never attach to / resolve another org's
  object.

    * **GREEN** — tenant own-org resolves `secure_body` in the clear.
    * **RED** — operator (impersonation, no grant) resolves `secure_body` to
      `%Samen.Masked{}` — never plaintext, never a `vt_*` token.
    * **SABOTAGE twins** — plane flip (same row, tenant clear / operator masked);
      leak-scan refutability.
    * **Attach — GREEN** — same-org attach (via `Samen.Web.Docs.attach/5`, which
      resolves the subject through the org-scoped `Samen.Web.ObjectRef.resolve/3`
      BEFORE anchoring) succeeds against TWO DIFFERENT host resource kinds
      (`crm.person` and `crm.company` — done-criterion 3: "attached to two
      different host resources via object-ref").
    * **Attach — RED** — a cross-org subject ref is INERT: `attach/5` refuses to
      persist the anchor (no orphaned row), because `ObjectRef.resolve/3`'s
      org-scoped `load_scoped/3` returns `{:error, :not_found}` for another org's
      row (no existence oracle, no leak).
  """
  use Samen.WebTest.DataCase, async: false
  use Samen.MaskingCase

  require Ash.Query

  alias Samen.Web.{Docs, Mount, ObjectRef}
  alias Samen.WebTest.Docs.{Doc, Note}

  @secret_body "docs.vaulted.subject@sample.invalid"

  defp tenant_scope(org_id), do: Mount.scope(docs_mount(:tenant), org_id)

  defp docs_mount(:tenant), do: Mount.new(:docs, Samen.WebTest.Docs, Samen.WebTest.Repo, plane: Samen.Web.Plane.tenant())

  defp seed_doc!(org_id, attrs \\ %{}) do
    Doc
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(%{org_id: org_id, title: "Runbook", secure_body: @secret_body}, attrs),
      scope: tenant_scope(org_id)
    )
    |> Ash.create!()
  end

  defp with_secure_body_loaded(%{id: id}, resource, scope) do
    resource
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.ensure_selected([:secure_body])
    |> Ash.read_one!(scope: scope)
  end

  # -- masking three-proof (INV-1) --------------------------------------------

  describe "secure_body masking per plane (INV-1)" do
    test "GREEN: tenant own-org resolves secure_body in the CLEAR" do
      org_id = Ash.UUID.generate()
      d = seed_doc!(org_id) |> with_secure_body_loaded(Doc, tenant_scope(org_id))

      resolved = d |> resolve_on_plane(Doc, :tenant, repo: Samen.WebTest.Repo) |> Map.get(:secure_body)

      refute match?(%Samen.Masked{}, resolved)
      assert resolved == @secret_body
    end

    test "RED: operator (impersonation, no grant) resolves secure_body to %Masked{} — never " <>
           "plaintext, never a vt_ token" do
      org_id = Ash.UUID.generate()
      d = seed_doc!(org_id) |> with_secure_body_loaded(Doc, tenant_scope(org_id))

      masked = resolve_on_plane(d, Doc, :operator, repo: Samen.WebTest.Repo).secure_body
      assert_plane_masked!(masked)
      refute to_string(masked) =~ @secret_body
      refute to_string(masked) =~ "vt_"
    end

    test "ANTI-TAUTOLOGY: plane flip — the SAME row resolves clear on tenant, masked on operator" do
      org_id = Ash.UUID.generate()
      d = seed_doc!(org_id) |> with_secure_body_loaded(Doc, tenant_scope(org_id))

      tenant_val = resolve_on_plane(d, Doc, :tenant, repo: Samen.WebTest.Repo).secure_body
      operator_val = resolve_on_plane(d, Doc, :operator, repo: Samen.WebTest.Repo).secure_body

      refute match?(%Samen.Masked{}, tenant_val)
      assert match?(%Samen.Masked{}, operator_val)
      assert to_string(operator_val) == mask()
    end

    test "ANTI-TAUTOLOGY: the leak scan is refutable — a modeled plaintext render IS caught" do
      org_id = Ash.UUID.generate()
      d = seed_doc!(org_id) |> with_secure_body_loaded(Doc, tenant_scope(org_id))

      leaked = "<div>secure_body: #{@secret_body}</div>"
      assert_leak_detected!(leaked, @secret_body)

      masked = resolve_on_plane(d, Doc, :operator, repo: Samen.WebTest.Repo).secure_body
      assert_plane_masked!(masked)
    end
  end

  # -- org-scoped object-ref ATTACH write boundary (ADR-041 §6.1 pattern) -----

  describe "Samen.Web.Docs.attach/5 — org-scoped subject resolve BEFORE anchoring" do
    test "GREEN: same-org attach to crm.person succeeds (positive control)" do
      seeded = Seeds.seed_all()
      mount = docs_mount(:tenant)
      scope = tenant_scope(seeded.org_id)

      ref = %ObjectRef{key: "crm.person", id: seeded.crm.person.id, raw: nil}

      assert {:ok, doc} = Docs.attach(mount, scope, Doc, %{title: "Contact notes"}, ref)
      assert doc.subject_key == "crm.person"
      assert doc.subject_id == seeded.crm.person.id
    end

    test "GREEN: same-org attach to crm.company ALSO succeeds — a SECOND, DIFFERENT host " <>
           "resource kind (done-criterion 3: attachable to any object)" do
      seeded = Seeds.seed_all()
      mount = docs_mount(:tenant)
      scope = tenant_scope(seeded.org_id)

      ref = %ObjectRef{key: "crm.company", id: seeded.crm.company.id, raw: nil}

      assert {:ok, note} = Docs.attach(mount, scope, Note, %{body: "Follow up next quarter"}, ref)
      assert note.subject_key == "crm.company"
      assert note.subject_id == seeded.crm.company.id
    end

    test "the attached Doc/Note resolves BACK to the subject's card via ObjectRef.resolve/3 " <>
           "(the unfurl mechanism a detail view calls)" do
      seeded = Seeds.seed_all()
      mount = docs_mount(:tenant)
      scope = tenant_scope(seeded.org_id)

      person_ref = %ObjectRef{key: "crm.person", id: seeded.crm.person.id, raw: nil}
      {:ok, _doc} = Docs.attach(mount, scope, Doc, %{title: "Contact notes"}, person_ref)

      assert {:ok, card} = ObjectRef.resolve(mount, scope, person_ref)
      assert card.key == "crm.person"
    end

    test "RED: a CROSS-ORG subject ref is INERT — attach refuses to persist the anchor, " <>
           "no orphaned row" do
      seeded = Seeds.seed_all()
      attacker_org = Ash.UUID.generate()

      mount = docs_mount(:tenant)
      attacker_scope = tenant_scope(attacker_org)

      cross_ref = %ObjectRef{key: "crm.person", id: seeded.crm.person.id, raw: nil}

      before_count = Doc |> Ash.read!(scope: tenant_scope(seeded.org_id)) |> length()

      assert {:error, {:subject_unresolved, :not_found}} =
               Docs.attach(mount, attacker_scope, Doc, %{title: "leak attempt"}, cross_ref)

      # No orphaned row landed in EITHER org.
      assert Doc |> Ash.read!(scope: attacker_scope) == []
      after_count = Doc |> Ash.read!(scope: tenant_scope(seeded.org_id)) |> length()
      assert after_count == before_count
    end

    test "CONTROL: the SAME ref resolves fine for the OWNING org (anti-tautology — the red " <>
           "path is not a blanket refusal)" do
      seeded = Seeds.seed_all()
      mount = docs_mount(:tenant)

      ref = %ObjectRef{key: "crm.person", id: seeded.crm.person.id, raw: nil}

      assert {:ok, _doc} =
               Docs.attach(mount, tenant_scope(seeded.org_id), Doc, %{title: "owner attach"}, ref)
    end

    test "RED: attach_ref/5 refuses a malformed ref string ({:unknown_key})" do
      seeded = Seeds.seed_all()
      mount = docs_mount(:tenant)

      assert {:error, {:subject_unresolved, :unknown_key}} =
               Docs.attach_ref(mount, tenant_scope(seeded.org_id), Doc, %{title: "x"}, "not-a-ref")
    end

    test "CONTROL: attach_ref/5 with a well-formed ref string succeeds (anti-tautology)" do
      seeded = Seeds.seed_all()
      mount = docs_mount(:tenant)

      ref_str = ObjectRef.to_string("crm.person", seeded.crm.person.id)

      assert {:ok, doc} = Docs.attach_ref(mount, tenant_scope(seeded.org_id), Doc, %{title: "x"}, ref_str)
      assert doc.subject_key == "crm.person"
    end
  end
end
