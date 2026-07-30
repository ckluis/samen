defmodule Samen.Web.CRMContactsCrudTest do
  @moduledoc """
  A3 WIRING (crm batch) — the WRITE side of `Samen.Web.CRM.ContactsLive` (🔒 PII:
  `full_name` is a vault-routed composite; the read side landed in A2):

    * **CRUD (AC-G1-1/2)** — "New contact" is a REAL button opening the modal +
      `simple_form` (composite first/last inputs for the vaulted name); an INVALID
      submit renders inline errors and persists NOTHING; a VALID submit persists +
      refreshes the bounded list; each row carries `delete_confirm/1` and delete
      destroys through Ash.
    * **MC-2 (vault write chokepoint)** — the tenant-created `full_name` is NOT
      plaintext at rest: the raw (resolver-bypassing) record does not contain the name.
    * **MC-1 / RP-G1-7 (the write-path red path)** — an operator-plane submit carrying
      plaintext `full_name` is REJECTED at the Ash write path (`Samen.Pii.WriteGuard`),
      the DB is unchanged. The affordances are also absent from the operator DOM
      (belt), but the red path drives the HANDLER directly — proving the enforcement
      is the write path, not the hidden button (anti-tautology: the SAME submit on the
      tenant plane succeeds, so the rejection discriminates on the plane).
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.CRM.ContactsLive

  # -- harness -------------------------------------------------------------------

  defp mount_socket(org_id, plane_opts \\ []) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, build_mount(:crm, plane_opts))
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> Phoenix.Component.assign(:return_to, nil)
    |> ContactsLive.load(org_id)
  end

  defp html(socket), do: render_html(ContactsLive, socket.assigns)

  defp event(socket, name, params) do
    {:noreply, socket} = ContactsLive.handle_event(name, params, socket)
    socket
  end

  defp person_count(org_id) do
    Samen.WebTest.Crm.Person
    |> Ash.Query.ensure_selected([:org_id])
    |> Ash.read!(authorize?: false)
    |> Enum.count(&(&1.org_id == org_id))
  end

  defp raw_person(id), do: Ash.get!(Samen.WebTest.Crm.Person, id, authorize?: false)

  # ---------------------------------------------------------------------------
  # Create — green path (AC-G1-1/2 + MC-2)
  # ---------------------------------------------------------------------------

  test "New contact opens the modal; a VALID submit persists, refreshes the list, and vault-routes the name (MC-2)" do
    org_id = Ash.UUID.generate()
    socket = mount_socket(org_id)

    rendered = html(socket)
    assert rendered =~ ~s(id="new-contact")
    assert rendered =~ ~s(phx-click="new_contact")

    socket = event(socket, "new_contact", %{})
    rendered = html(socket)
    assert rendered =~ ~s(role="dialog")
    assert rendered =~ ~s(id="new-contact-form")
    # The composite name field submits the map shape the vaulted type casts.
    assert rendered =~ ~s(name="form[full_name][first]")
    assert rendered =~ ~s(name="form[full_name][last]")
    assert rendered =~ ~s(name="form[display_name]")

    socket =
      event(socket, "save_new", %{
        "form" => %{
          "full_name" => %{"first" => "Nova", "last" => "Quillwright"},
          "display_name" => "Nova Quillwright",
          "job_title" => "Dispatcher"
        }
      })

    refute socket.assigns.show_new
    assert person_count(org_id) == 1
    # The refreshed (bounded) list renders the new contact — name resolved CLEAR on
    # the tenant plane through PiiResolution.
    rendered = html(socket)
    assert rendered =~ "Nova Quillwright"

    # MC-2: the vaulted full_name is NOT plaintext at rest — the raw record (no
    # resolver) carries no name fragment. If the write had bypassed the vault path,
    # this scan would find the plaintext and FAIL.
    [person] = socket.assigns.page.items
    raw = raw_person(person.id)
    refute inspect(raw.full_name) =~ "Quillwright"
  end

  test "RED PATH (AC-G1-2): an INVALID submit (garbage company_id) shows inline errors and persists NOTHING" do
    org_id = Ash.UUID.generate()
    socket = mount_socket(org_id) |> event("new_contact", %{})

    socket =
      event(socket, "save_new", %{
        "form" => %{
          "display_name" => "Half Finished",
          "company_id" => "not-a-uuid"
        }
      })

    # Modal stays open with the inline field error.
    assert socket.assigns.show_new
    rendered = html(socket)
    assert rendered =~ "field-invalid"
    assert rendered =~ "field-error"
    # Nothing persisted.
    assert person_count(org_id) == 0
    assert socket.assigns.page.items == []
  end

  # ---------------------------------------------------------------------------
  # Delete — the interlocked row action
  # ---------------------------------------------------------------------------

  test "each row carries the delete_confirm interlock; delete destroys through Ash and refreshes" do
    org_id = Ash.UUID.generate()
    socket = mount_socket(org_id) |> event("new_contact", %{})

    socket =
      event(socket, "save_new", %{
        "form" => %{"full_name" => %{"first" => "Doomed", "last" => "Row"}, "display_name" => "Doomed Row"}
      })

    [person] = socket.assigns.page.items

    rendered = html(socket)
    assert rendered =~ ~s(data-confirm="Delete this record? This cannot be undone.")
    assert rendered =~ ~s(phx-value-id="#{person.id}")

    socket = event(socket, "delete", %{"id" => person.id})
    assert socket.assigns.page.items == []
    assert person_count(org_id) == 0
    assert html(socket) =~ "empty-state"
  end

  # ---------------------------------------------------------------------------
  # MC-1 / RP-G1-7 — the operator plane: DOM belt + write-path suspenders
  # ---------------------------------------------------------------------------

  test "OPERATOR plane: no create/delete affordance in the DOM; list still renders masked (belt)" do
    %{org_id: org_id} = Seeds.seed_all()
    socket = mount_socket(org_id, plane: :operator, target_org_id: org_id)

    rendered = html(socket)
    # Non-vacuous: the seeded contact row renders, masked.
    assert rendered =~ "contact-row"
    assert rendered =~ "••••"
    refute rendered =~ Seeds.contact_email()
    # No write affordance offered to the operator.
    refute rendered =~ ~s(phx-click="new_contact")
    refute rendered =~ ~s(phx-click="delete")
    refute rendered =~ "data-confirm"
    # And no PII/token leaks through the (hidden) form plumbing.
    refute rendered =~ "vt_"
  end

  test "RED PATH (MC-1 / RP-G1-7): an operator-plane create with plaintext full_name is REJECTED at the write path; DB unchanged" do
    org_id = Ash.UUID.generate()
    before_count = person_count(org_id)

    # Drive the HANDLER directly on an operator-plane socket — bypassing the hidden
    # button entirely. The enforcement under test is Samen.Pii.WriteGuard on the Ash
    # write path, NOT the DOM.
    socket = mount_socket(org_id, plane: :operator, target_org_id: org_id)

    socket =
      event(socket, "save_new", %{
        "form" => %{
          "full_name" => %{"first" => "Operator", "last" => "Authored"},
          "display_name" => "Operator Authored"
        }
      })

    # The write was refused with the MC-1 error; nothing reached the DB.
    assert person_count(org_id) == before_count
    assert AshPhoenix.Form.errors(socket.assigns.new_form.source) != []

    assert socket.assigns.new_form.source
           |> AshPhoenix.Form.errors()
           |> inspect() =~ "no-operator-plaintext-write"
  end

  test "ANTI-TAUTOLOGY pairing: the SAME submit on the TENANT plane succeeds — the rejection discriminates on the plane" do
    org_id = Ash.UUID.generate()
    socket = mount_socket(org_id)

    _socket =
      event(socket, "save_new", %{
        "form" => %{
          "full_name" => %{"first" => "Tenant", "last" => "Authored"},
          "display_name" => "Tenant Authored"
        }
      })

    # If the guard rejected regardless of plane (over-block) this would fail; if it
    # never rejected (tautology) the operator red path above would fail instead.
    assert person_count(org_id) == 1
  end

  # ---------------------------------------------------------------------------
  # T37h (ADR-040 §5.8) — archive/restore/archived-filter toggle, generated "for
  # free" by `Samen.Web.ListLive` (the SAME framework mixin `Samen.Web.Billing.
  # PlansLive` uses — no per-vertical hand-wiring here beyond one `Reads.contacts_page/3`
  # line honoring `state.show_archived`, per that module's own moduledoc). Doubles as
  # the INV-1 UI proof: an archived Person's vault fields still mask on the operator
  # plane through the SAME `Samen.Api.PiiResolution` path a live row uses.
  # ---------------------------------------------------------------------------

  alias Samen.Web.ListLive

  defp list_event(socket, name, params) do
    {:noreply, socket} = ListLive.handle_list_event(name, params, socket)
    socket
  end

  defp archived_person(id) do
    Samen.WebTest.Crm.Person
    |> Ash.Query.for_read(:archived)
    |> Ash.read!(authorize?: false)
    |> Enum.find(&(&1.id == id))
  end

  describe "T37h — archive → hidden → toggle shows it (trash view) → restore → visible again" do
    test "an archived contact is hidden by default, appears in the toggled trash view with Restore (not Edit/Delete), and restore returns it to the live view" do
      org_id = Ash.UUID.generate()

      {:ok, person} =
        Samen.WebTest.Crm.Person
        |> Ash.Changeset.for_create(
          :create,
          %{org_id: org_id, full_name: %{first: "Trash", last: "Bound"}, display_name: "Trash Bound"},
          authorize?: false
        )
        |> Ash.create()

      socket = mount_socket(org_id) |> event("delete", %{"id" => person.id})
      assert archived_person(person.id).archived_at
      refute html(socket) =~ ~s(phx-value-id="#{person.id}")

      # Toggle ON: `Reads.contacts_page/3` switches to the `:archived` trash-only read.
      socket = list_event(socket, "toggle_archived", %{})
      assert socket.assigns.list_state.show_archived
      rendered = html(socket)
      assert rendered =~ ~s(phx-value-id="#{person.id}")
      assert rendered =~ "archived"
      assert rendered =~ ~s(phx-click="restore" phx-value-id="#{person.id}")
      refute rendered =~ ~s(phx-click="delete" phx-value-id="#{person.id}")

      # Restore — Person is only RoleAtLeast :member-gated (no elevation needed,
      # unlike Plan), so the plain list scope suffices (write_scope defaults identity).
      socket = list_event(socket, "restore", %{"id" => person.id})
      refute Ash.get!(Samen.WebTest.Crm.Person, person.id, authorize?: false).archived_at

      # Gone from the trash view (graduated back to live) …
      refute html(socket) =~ ~s(phx-value-id="#{person.id}")

      # … and back on the default (live) view with the normal delete affordance.
      socket = list_event(socket, "toggle_archived", %{})
      rendered = html(socket)
      assert rendered =~ ~s(phx-click="delete" phx-value-id="#{person.id}")
      refute rendered =~ ~s(phx-click="restore" phx-value-id="#{person.id}")
    end

    test "INV-1: an archived contact's PII still masks on the operator plane (••••, no vault token) in the toggled trash view" do
      %{org_id: org_id} = Seeds.seed_all()

      tenant_socket = mount_socket(org_id)
      [seeded] = tenant_socket.assigns.page.items
      _ = event(tenant_socket, "delete", %{"id" => seeded.id})
      assert archived_person(seeded.id).archived_at

      operator_socket =
        mount_socket(org_id, plane: :operator, target_org_id: org_id)
        |> list_event("toggle_archived", %{})

      # Non-vacuous: the archived row IS present in the operator's trash view (the
      # row's `<tr id="contacts-row-...">` is unconditional — the write-affordance
      # `<td>` restore/delete are `writable?`-gated and absent for operator, same
      # posture as every other write on this page, unrelated to whether the ROW
      # itself renders).
      assert Enum.any?(operator_socket.assigns.page.items, &(&1.id == seeded.id))
      rendered = html(operator_socket)
      assert rendered =~ ~s(id="contacts-row-#{seeded.id}")
      refute rendered =~ ~s(phx-click="restore")
      refute rendered =~ ~s(phx-click="delete")

      # Masked, never plaintext, never a raw vault token — archiving never bypasses
      # Samen.Api.PiiResolution (the read-side resolver runs identically on the
      # `:archived` query, same as any other read).
      assert rendered =~ "••••"
      refute rendered =~ Seeds.contact_full_name()
      refute rendered =~ Seeds.contact_email()
      refute rendered =~ "vt_"
    end
  end
end
