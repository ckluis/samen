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
    * **Delete** — `delete_confirm/1` interlock + destroy + navigate back to the list.
  """
  use Samen.WebTest.DataCase, async: false

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

  defp activity_count(org_id) do
    Samen.WebTest.Crm.Activity
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

  test "RED PATH (AC-G1-2): an invalid composer submit (blank required type) shows inline errors, persists NOTHING",
       %{org_id: org_id, contact_id: contact_id} do
    before_count = activity_count(org_id)

    socket =
      mount_socket(org_id, contact_id)
      |> Phoenix.Component.assign(:active_tab, "activity")

    socket =
      event(socket, "log_activity", %{
        "activity" => %{"type" => "", "subject" => "Half-written note"}
      })

    rendered = html(socket)
    assert rendered =~ ~s(id="log-activity-form")
    assert rendered =~ "field-invalid"
    assert rendered =~ "field-error"
    assert rendered =~ "is required"
    assert activity_count(org_id) == before_count
  end

  # ---------------------------------------------------------------------------
  # Delete — interlock + destroy + navigate back
  # ---------------------------------------------------------------------------

  test "TENANT: delete carries the interlock, destroys the contact, and navigates back to the list",
       %{org_id: org_id} do
    # A FRESH contact with no linked activities — deletable under the kernel's FK rules.
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

    assert_raise Ash.Error.Invalid, fn -> raw_person(person.id) end
  end

  test "FAIL-HONEST RED PATH: deleting a contact with linked activities is REFUSED and SURFACED — no silent navigate",
       %{org_id: org_id, contact_id: contact_id} do
    # The seeded contact HAS activities; the kernel defines no cascade, so the DB
    # refuses the destroy. The page must surface the refusal, not navigate away.
    socket = mount_socket(org_id, contact_id)
    socket = event(socket, "delete_contact", %{"id" => contact_id})

    assert socket.redirected == nil
    assert socket.assigns.delete_error =~ "Could not delete this contact"
    assert html(socket) =~ ~s(id="delete-error")
    # The contact provably still exists.
    assert raw_person(contact_id).id == contact_id
  end

  test "OPERATOR: the delete affordance is NOT offered (tenant-plane posture)",
       %{org_id: org_id, contact_id: contact_id} do
    socket = mount_socket(org_id, contact_id, plane: :operator, target_org_id: org_id)
    rendered = html(socket)
    refute rendered =~ ~s(id="delete-contact")
    refute rendered =~ ~s(phx-click="delete_contact")
  end
end
