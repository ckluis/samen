defmodule Samen.Web.CRMContactDetailCrudTest do
  @moduledoc """
  A3 WIRING (crm batch) — the WRITE side of `Samen.Web.CRM.ContactLive` (🔒 the PII
  detail surface): the edit modal, delete, and the kit-form log-activity composer.

    * **Edit (AC-G1-1) + MC-2** — "Edit contact" opens the `AshPhoenix.Form.for_update`
      modal over the PLANE-RESOLVED record; a tenant save round-trips the composite
      `full_name` through the vault write path (no plaintext at rest).
    * **THE PER-PLANE FORM-MASKING GUARANTEE on the REAL surface (AC-G1-7 / MC-1
      render half)** — the SAME edit modal renders the vaulted `full_name` editable-
      CLEAR on the tenant plane and read-only `••••` with NO `name` attribute on the
      operator plane; plaintext AND vault token absent from the DOM; the non-vaulted
      `job_title` stays editable (no over-block).
    * **RP-L1 (MC-1 write half)** — an operator-plane `save_edit` carrying plaintext
      `full_name` is REJECTED at the Ash write path; DB unchanged. The pairing green:
      an operator editing ONLY the non-vaulted `job_title` succeeds (the guard fires
      on exactly the vaulted set — not a plane-wide write block).
    * **Log-activity (AC-G1-2)** — the composer is the kit `simple_form` now: an
      invalid submit (blank required `type`) renders inline errors and persists
      NOTHING; the green path lives in `crm_detail_render_test.exs`.
    * **Delete** — `delete_confirm/1` interlock + destroy + navigate back to the
      list. ADR-040 §5.9/T37c: `Person` is `archivable true`, so the default
      destroy now soft-archives (T36); CRM declares no cascade (§5.4), so a
      contact with linked attachment rows archives cleanly too — its children
      stay live, untouched. The archived row still masks its vault fields per
      plane (INV-1), proven separately in `crm_scope_archival_leak_red_path_test.exs`.
  """
  use Samen.WebTest.DataCase, async: false

  require Ash.Query

  alias Samen.Web.CRM.ContactLive

  setup do
    seeded = Seeds.seed_all()
    %{org_id: seeded.org_id, contact_id: seeded.crm.person.id}
  end

  # -- harness -------------------------------------------------------------------

  defp mount_socket(org_id, contact_id, plane_opts \\ []) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, build_mount(:crm, plane_opts))
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> Phoenix.Component.assign(:return_to, nil)
    |> ContactLive.load(org_id, contact_id)
  end

  defp html(socket), do: render_html(ContactLive, socket.assigns)

  defp event(socket, name, params) do
    {:noreply, socket} = ContactLive.handle_event(name, params, socket)
    socket
  end

  defp raw_person(id), do: Ash.get!(Samen.WebTest.Crm.Person, id, authorize?: false)

  defp archived_person(id) do
    Samen.WebTest.Crm.Person
    |> Ash.Query.for_read(:archived)
    |> Ash.read!(authorize?: false)
    |> Enum.find(&(&1.id == id))
  end

  # ADR-041 §5: the log-activity composer now writes a canonical Work Task. Count Tasks.
  defp activity_count(org_id) do
    Samen.WebTest.Work.Task
    |> Ash.Query.ensure_selected([:org_id])
    |> Ash.read!(authorize?: false)
    |> Enum.count(&(&1.org_id == org_id))
  end

  # ---------------------------------------------------------------------------
  # Edit — tenant green path (AC-G1-1 + MC-2)
  # ---------------------------------------------------------------------------

  test "TENANT: Edit contact opens the modal with the name editable-CLEAR; a save persists through the vault (MC-2)",
       %{org_id: org_id, contact_id: contact_id} do
    socket = mount_socket(org_id, contact_id)

    assert html(socket) =~ ~s(id="edit-contact")

    socket = event(socket, "edit_contact", %{})
    rendered = html(socket)
    assert rendered =~ ~s(id="edit-contact-modal")
    assert rendered =~ ~s(role="dialog")
    # The composite name is EDITABLE on the tenant plane, pre-filled clear.
    assert rendered =~ ~s(name="form[full_name][first]")
    assert rendered =~ ~s(name="form[full_name][last]")
    assert rendered =~ ~s(value="Aurelia")
    refute rendered =~ "data-masked"

    socket =
      event(socket, "save_edit", %{
        "form" => %{
          "full_name" => %{"first" => "Aurelia", "last" => "Fablewright"},
          "job_title" => "VP Logistics"
        }
      })

    refute socket.assigns.show_edit
    # The reloaded surface renders the new values (resolved clear on tenant).
    rendered = html(socket)
    assert rendered =~ "Fablewright"
    assert rendered =~ "VP Logistics"

    # MC-2: the edited name is NOT plaintext at rest — the raw record (no resolver)
    # carries no name fragment. A vault bypass would make this scan FAIL.
    raw = raw_person(contact_id)
    refute inspect(raw.full_name) =~ "Fablewright"
    assert raw.job_title == "VP Logistics"
  end

  # ---------------------------------------------------------------------------
  # THE PER-PLANE FORM-MASKING GUARANTEE on the real surface (AC-G1-7)
  # ---------------------------------------------------------------------------

  test "OPERATOR: the SAME edit modal renders full_name read-only •••• — no name attr, no plaintext, no token",
       %{org_id: org_id, contact_id: contact_id} do
    socket = mount_socket(org_id, contact_id, plane: :operator, target_org_id: org_id)
    socket = event(socket, "edit_contact", %{})

    rendered = html(socket)
    # Non-vacuous: it IS the same modal + form…
    assert rendered =~ ~s(id="edit-contact-modal")
    assert rendered =~ "Full name"
    # …but the vaulted field is the read-only masked placeholder (form_field's
    # %Masked{} branch — dispatch on the VALUE, no plane branch in the LiveView)…
    assert rendered =~ "data-masked"
    assert rendered =~ "••••"
    refute rendered =~ ~s(name="form[full_name])
    # …with the plaintext ABSENT (any fragment in the DOM = leak)…
    refute rendered =~ "Aurelia"
    refute rendered =~ Seeds.contact_email()
    refute rendered =~ Seeds.contact_phone()
    # …and the vault token NEVER reaches the DOM.
    refute rendered =~ "vt_"
    # Masking does not over-block: the non-vaulted job_title stays editable.
    assert rendered =~ ~s(name="form[job_title]")
    assert rendered =~ "Head of Logistics"
  end

  # ---------------------------------------------------------------------------
  # RP-L1 — the operator write-path red path + the no-over-block pairing
  # ---------------------------------------------------------------------------

  test "RED PATH (RP-L1 / MC-1): an operator-plane save_edit with plaintext full_name is REJECTED; DB unchanged",
       %{org_id: org_id, contact_id: contact_id} do
    raw_before = raw_person(contact_id)

    socket = mount_socket(org_id, contact_id, plane: :operator, target_org_id: org_id)
    socket = event(socket, "edit_contact", %{})

    # A hand-crafted submit that bypasses the nameless masked input entirely — the
    # enforcement under test is the Ash write path (Samen.Pii.WriteGuard), not the DOM.
    socket =
      event(socket, "save_edit", %{
        "form" => %{"full_name" => %{"first" => "Operator", "last" => "Overwrite"}}
      })

    errors = AshPhoenix.Form.errors(socket.assigns.edit_form.source)
    assert inspect(errors) =~ "no-operator-plaintext-write"

    # DB provably unchanged — the stored vaulted value is byte-identical.
    raw_after = raw_person(contact_id)
    assert inspect(raw_after.full_name) == inspect(raw_before.full_name)
    refute inspect(raw_after.full_name) =~ "Overwrite"

    # And the tenant still reads the ORIGINAL name in the clear.
    tenant = mount_socket(org_id, contact_id)
    assert html(tenant) =~ "Aurelia"
  end

  test "PAIRING (no over-block): an operator editing ONLY the non-vaulted job_title succeeds",
       %{org_id: org_id, contact_id: contact_id} do
    socket = mount_socket(org_id, contact_id, plane: :operator, target_org_id: org_id)
    socket = event(socket, "edit_contact", %{})

    socket = event(socket, "save_edit", %{"form" => %{"job_title" => "Ops Lead"}})

    refute socket.assigns.show_edit
    assert raw_person(contact_id).job_title == "Ops Lead"
  end

  # ---------------------------------------------------------------------------
  # Log-activity — the kit form's inline-error red path (AC-G1-2)
  # ---------------------------------------------------------------------------

  test "RED PATH (AC-G1-2): an invalid composer submit (out-of-enum kind) shows inline errors, persists NOTHING",
       %{org_id: org_id, contact_id: contact_id} do
    before_count = activity_count(org_id)

    socket =
      mount_socket(org_id, contact_id)
      |> Phoenix.Component.assign(:active_tab, "activity")

    # ADR-041 §6.1: the composer writes a Work Task; `kind` is a bounded one_of enum. An
    # out-of-enum kind is refused at the write path and surfaced as an inline field error
    # (the composer's AC-G1-2 red path — invalid input rejected + surfaced + nothing persisted).
    socket =
      event(socket, "log_activity", %{
        "activity" => %{"kind" => "not_a_valid_kind", "title" => "Half-written note"}
      })

    rendered = html(socket)
    assert rendered =~ ~s(id="log-activity-form")
    assert rendered =~ "field-invalid"
    assert rendered =~ "field-error"
    assert activity_count(org_id) == before_count
  end

  # ---------------------------------------------------------------------------
  # Delete — interlock + soft-archive + navigate back (ADR-040 §5.9/T37c)
  # ---------------------------------------------------------------------------

  test "TENANT: delete carries the interlock, soft-archives the contact, and navigates back to the list",
       %{org_id: org_id} do
    person =
      Samen.WebTest.Crm.Person
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: org_id, display_name: "Deletable Person"},
        authorize?: false
      )
      |> Ash.create!()

    socket = mount_socket(org_id, person.id)

    rendered = html(socket)
    assert rendered =~ ~s(id="delete-contact")
    assert rendered =~ ~s(data-confirm="Delete this contact? This cannot be undone.")

    socket = event(socket, "delete_contact", %{"id" => person.id})

    assert {:live, :redirect, %{to: to}} = socket.redirected
    assert to =~ "/crm/contacts"

    # `raw_person/1` reads through the default (archived-excluding) filter — the
    # archived contact drops out, same observable shape as the old hard delete
    # for THIS assertion, even though the row still exists (T36 soft-destroy).
    assert_raise Ash.Error.Invalid, fn -> raw_person(person.id) end
    assert archived_person(person.id).archived_at
  end

  test "delete soft-archives a contact WITH a linked attachment too (no FK refusal — ADR-040 §5.4 declares no cascade)",
       %{org_id: org_id, contact_id: contact_id} do
    # ADR-041: the seeded contact's timeline is now Work Tasks anchored by a GENERIC
    # object-ref (not a CRM FK). Attach a CRM Attachment (a real belongs_to FK on
    # person) to prove the point on its own terms: CRM declares no cascade (§5.4),
    # so the destroy is no longer a real DELETE for Postgres to refuse — it
    # soft-archives and the page navigates away, exactly like the bare case.
    Samen.WebTest.Crm.Attachment
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org_id, file_name: "signed-nda.pdf", person_id: contact_id},
      actor: %{org_id: org_id, role: :member},
      authorize?: false
    )
    |> Ash.create!()

    socket = mount_socket(org_id, contact_id)
    socket = event(socket, "delete_contact", %{"id" => contact_id})

    # The redirect itself proves success (the error branch never navigates —
    # see the TENANT test above and the handler's `case` in contact_live.ex).
    assert {:live, :redirect, %{to: to}} = socket.redirected
    assert to =~ "/crm/contacts"
    assert archived_person(contact_id).archived_at

    # The linked Attachment row is untouched (no cascade) — still live and still
    # pointing at the now-archived contact.
    assert Samen.WebTest.Crm.Attachment
           |> Ash.Query.filter(person_id == ^contact_id)
           |> Ash.read!(authorize?: false)
           |> Enum.any?()
  end

  test "OPERATOR: the delete affordance is NOT offered (tenant-plane posture)",
       %{org_id: org_id, contact_id: contact_id} do
    socket = mount_socket(org_id, contact_id, plane: :operator, target_org_id: org_id)
    rendered = html(socket)
    refute rendered =~ ~s(id="delete-contact")
    refute rendered =~ ~s(phx-click="delete_contact")
  end
end
