defmodule Samen.Web.ChatUnfurlMaskingTest do
  @moduledoc """
  THE CROWN-JEWEL GATE (ADR-012 §7 red paths 1 + 2, test-plan §8.2).

  Resolve the SAME `samen:crm.person:<id>` ref as a TENANT (plane :tenant) and as an OPERATOR
  (plane :operator) and assert:

    * red path 1 — the tenant card shows the REAL name/email/phone; the operator card shows
      `••••` for the SAME object, with the plaintext ABSENT and no `vt_`/`pii_` token; and
    * red path 2 — a `samen:crm.person:<id>` for a DIFFERENT org's row resolves to
      `{:error, :not_found}` (an inert "not available" chip), no existence oracle, no leak.

  The resolver is a COMPOSITION of two kernel gates (OrgScope + PiiResolution) over the host's
  own resource — so this test proves masking BY CONSTRUCTION, not a chat trick. The SAME
  capability is reusable anywhere (chat is the first consumer, not the owner).
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Mount
  alias Samen.Web.ObjectRef
  alias Samen.Web.ObjectRef.Card

  setup do
    seeded = Seeds.seed_all()

    ref = %ObjectRef{
      key: "crm.person",
      id: seeded.crm.person.id,
      raw: "samen:crm.person:#{seeded.crm.person.id}"
    }

    %{org_id: seeded.org_id, person_id: seeded.crm.person.id, ref: ref}
  end

  # ==========================================================================
  # RED PATH 1 — the SAME object ref, per-viewer masking (the crown jewel)
  # ==========================================================================

  test "TENANT viewer: the person card shows REAL PII (clear, own plane)", %{org_id: org_id, ref: ref} do
    mount = build_mount(:crm, plane: :tenant)
    scope = Mount.scope(mount, org_id)

    assert {:ok, %Card{} = card} = ObjectRef.resolve(mount, scope, ref)

    # The title is the real, clear name.
    assert card.title == Seeds.contact_full_name()
    refute match?(%Samen.Masked{}, card.title)

    # Rendered HTML shows the real name/email; no mask sentinel where PII would be.
    html = render_card(card)
    assert html =~ Seeds.contact_full_name()
    assert html =~ Seeds.contact_email()
  end

  test "OPERATOR viewer: the SAME person card shows •••• (masked), no plaintext, no vault token", %{
    org_id: org_id,
    ref: ref
  } do
    mount = build_mount(:crm, plane: :operator, target_org_id: org_id)
    scope = Mount.scope(mount, org_id)

    assert {:ok, %Card{} = card} = ObjectRef.resolve(mount, scope, ref)

    # Non-vacuous: the SAME seeded person was loaded (the operator opened the tenant) —
    # same id as the tenant resolve.
    assert card.id == ref.id
    # The title is masked (the vaulted full_name resolved to %Masked{} on the operator plane).
    assert match?(%Samen.Masked{}, card.title)

    html = render_card(card)
    # The mask sentinel is present …
    assert html =~ "••••"
    # … and the tenant plaintext PII is ABSENT.
    refute html =~ Seeds.contact_full_name()
    refute html =~ Seeds.contact_email()
    refute html =~ Seeds.contact_phone()
    # No vault token / pii_ column string leaks (ADR-009/010 red-path convention).
    refute html =~ "vt_"
    refute html =~ "pii_"
  end

  test "the SAME ref resolves to the SAME id on both planes — the ONLY difference is masking", %{
    org_id: org_id,
    ref: ref
  } do
    tenant_mount = build_mount(:crm, plane: :tenant)
    operator_mount = build_mount(:crm, plane: :operator, target_org_id: org_id)

    {:ok, tenant_card} = ObjectRef.resolve(tenant_mount, Mount.scope(tenant_mount, org_id), ref)
    {:ok, operator_card} = ObjectRef.resolve(operator_mount, Mount.scope(operator_mount, org_id), ref)

    # SAME object.
    assert tenant_card.id == operator_card.id
    assert tenant_card.key == operator_card.key
    # DIFFERENT masking: clear title vs %Masked{} title.
    assert is_binary(tenant_card.title)
    assert match?(%Samen.Masked{}, operator_card.title)
  end

  # ==========================================================================
  # RED PATH 2 — cross-org ref does NOT leak (org-scope the resolve)
  # ==========================================================================

  test "a cross-org person ref resolves to :not_found (no leak, no existence oracle)", %{org_id: org_id} do
    # Seed a person in a DIFFERENT org.
    other_org = Ash.UUID.generate()

    foreign_person =
      Samen.WebTest.Crm.Person
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: other_org,
          display_name: "Foreign Person",
          full_name: %Samen.Type.FullName{first: "Foreign", last: "Secret"},
          emails: [%{label: "work", address: "foreign.secret@example.test"}]
        },
        authorize?: false
      )
      |> Ash.create!()

    # The viewer is in `org_id`; the ref points at a row in `other_org`.
    mount = build_mount(:crm, plane: :tenant)
    scope = Mount.scope(mount, org_id)

    cross_org_ref = %ObjectRef{
      key: "crm.person",
      id: foreign_person.id,
      raw: "samen:crm.person:#{foreign_person.id}"
    }

    # OrgScope narrows the read to the viewer's org → zero rows → :not_found (SAME as a
    # nonexistent id: no way to tell "wrong org" from "doesn't exist").
    assert {:error, :not_found} = ObjectRef.resolve(mount, scope, cross_org_ref)

    # An operator opened on the viewer's org also cannot reach the foreign row.
    op_mount = build_mount(:crm, plane: :operator, target_org_id: org_id)
    assert {:error, :not_found} = ObjectRef.resolve(op_mount, Mount.scope(op_mount, org_id), cross_org_ref)

    # And the "not available" chip carries NO plaintext from the foreign row.
    html = render_card({:error, :not_found})
    refute html =~ "Foreign"
    refute html =~ "foreign.secret@example.test"
    assert html =~ "not available"
  end

  test "a nonexistent id resolves to :not_found (indistinguishable from cross-org)", %{org_id: org_id} do
    mount = build_mount(:crm, plane: :tenant)
    scope = Mount.scope(mount, org_id)

    ref = %ObjectRef{key: "crm.person", id: Ash.UUID.generate(), raw: "samen:crm.person:x"}
    assert {:error, :not_found} = ObjectRef.resolve(mount, scope, ref)
  end

  test "an unknown resource key resolves to :unknown_key (inert chip, never a raise)", %{org_id: org_id} do
    mount = build_mount(:crm, plane: :tenant)
    scope = Mount.scope(mount, org_id)

    ref = %ObjectRef{key: "crm.bogus", id: Ash.UUID.generate(), raw: "samen:crm.bogus:x"}
    assert {:error, :unknown_key} = ObjectRef.resolve(mount, scope, ref)
  end

  # -- helpers -----------------------------------------------------------------

  # Render the <.object_card> component to an HTML string (the DOM the viewer sees).
  defp render_card(card_or_error) do
    %{card: card_or_error, __changed__: %{}}
    |> Samen.UI.object_card()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end
end
