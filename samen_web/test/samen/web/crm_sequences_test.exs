defmodule Samen.Web.CRMSequencesTest do
  @moduledoc """
  T85 (spec §I2 CRM sequences actually send) — the tenant-plane CRM **Sequences** surface
  (`/crm/sequences`): the enroll flow + sequence/enrollment lists + the HONEST per-step
  send status over the EXISTING Outreach scope (`Samen.Scopes.Outreach`, T75).

  The two load-bearing asserts this file exists for:

    * **ORG-SCOPE** — a tenant sees ONLY its own sequences/enrollments. Proven refutably by
      a cross-org red-path (org B's enrollment is NEVER visible to org A) paired with a
      positive control (each org DOES see its own). Sabotage patch 167 flips it.
    * **HONESTY** — a keyless step (recorded `StepSend.status == :blocked`) renders "Blocked",
      NEVER a fabricated "Delivered"/"Sent". Only a genuine `:delivered` reads as delivered.
      Sabotage patch 168 flips it.

  NO PII renders on this surface: the three Outreach resources carry no vaulted (🔒) column;
  `Enrollment.person_id` is an opaque uuid rendered as a short non-secret chip. Proven: no
  `vt_*` token ever reaches the DOM.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.CRM.SequencesLive
  alias Samen.Web.CRM.SequencesReads
  alias Samen.Web.Mount

  @steps [
    %{"delay_hours" => 0, "subject" => "Hello", "body" => "First touch"},
    %{"delay_hours" => 24, "subject" => "Follow up", "body" => "Second touch"}
  ]

  setup do
    %{org_id: Ash.UUID.generate()}
  end

  # -- seeding helpers (authorize?: false — system context) --------------------

  defp create_sequence(org_id, name, steps \\ @steps) do
    Samen.WebTest.Outreach.Sequence
    |> Ash.Changeset.for_create(:create, %{org_id: org_id, name: name, status: :active, steps: steps},
      authorize?: false
    )
    |> Ash.create!()
  end

  defp enroll!(org_id, sequence, person_id) do
    Samen.WebTest.Outreach.Enrollment
    |> Ash.Changeset.for_create(
      :enroll,
      %{org_id: org_id, sequence_id: sequence.id, person_id: person_id},
      authorize?: false
    )
    |> Ash.create!()
  end

  defp queue_send!(org_id, enrollment, step_index) do
    Samen.WebTest.Outreach.StepSend
    |> Ash.Changeset.for_create(
      :queue,
      %{org_id: org_id, enrollment_id: enrollment.id, step_index: step_index},
      authorize?: false
    )
    |> Ash.create!()
  end

  defp mark_send!(send, status) do
    send
    |> Ash.Changeset.for_update(:mark, %{status: status}, authorize?: false)
    |> Ash.update!()
  end

  defp tenant_scope(org_id), do: Mount.scope(build_mount(:crm, plane: :tenant), org_id)

  defp render(org_id, mount_opts), do: render_live(SequencesLive, build_mount(:crm, mount_opts), [org_id])

  # ==========================================================================
  # Render + honest send-state banner
  # ==========================================================================

  test "renders the org's sequences and enrollments", %{org_id: org_id} do
    seq = create_sequence(org_id, "Onboarding drip")
    enrollment = enroll!(org_id, seq, Ash.UUID.generate())

    html = render(org_id, plane: :tenant)

    assert html =~ "Onboarding drip"
    assert html =~ "sequence-#{seq.id}"
    assert html =~ "enrollment-#{enrollment.id}"
    assert html =~ "2 step(s)"
  end

  test "with NO provider wired, the honest 'no sender configured' banner shows (never a fake sent)",
       %{org_id: org_id} do
    seq = create_sequence(org_id, "Drip")
    enroll!(org_id, seq, Ash.UUID.generate())

    refute SequencesReads.sends_configured?(org_id)

    html = render(org_id, plane: :tenant)

    assert html =~ "sequences-sends-not-configured"
    assert html =~ "No sender configured"
    refute html =~ ~s(data-state="configured")
  end

  # ==========================================================================
  # HONESTY — a keyless/blocked step is NEVER a fabricated "Delivered"/"Sent"
  # ==========================================================================

  test "a BLOCKED step renders 'Blocked', never 'Delivered' or 'Sent'", %{org_id: org_id} do
    seq = create_sequence(org_id, "Drip")
    enrollment = enroll!(org_id, seq, Ash.UUID.generate())
    org_id |> queue_send!(enrollment, 0) |> mark_send!(:blocked)

    html = render(org_id, plane: :tenant)

    # The honest status shows…
    assert html =~ "enrollment-#{enrollment.id}"
    assert html =~ "Blocked — no sender configured"
    # …and the row NEVER claims a delivery for the keyless step.
    row = enrollment_row(html, enrollment.id)
    refute row =~ "Delivered"
    refute row =~ "Sent"
  end

  test "the honest status labels never fabricate a delivery for a non-delivered outcome" do
    # Unit-pin the honesty chokepoint directly: only :delivered reads as delivered.
    for status <- [:queued, :blocked, :suppressed, :failed, :skipped] do
      label = SequencesLive.step_status_label(status)
      refute label =~ "Delivered"
      refute label =~ "Sent"
    end

    assert SequencesLive.step_status_label(:delivered) == "Delivered"
  end

  test "a genuinely DELIVERED step is the ONLY one that reads 'Delivered'", %{org_id: org_id} do
    seq = create_sequence(org_id, "Drip")
    enrollment = enroll!(org_id, seq, Ash.UUID.generate())
    org_id |> queue_send!(enrollment, 0) |> mark_send!(:delivered)

    html = render(org_id, plane: :tenant)
    row = enrollment_row(html, enrollment.id)

    assert row =~ "Delivered"
  end

  # ==========================================================================
  # ORG-SCOPE — cross-org red-path + positive control (the boundary this pins)
  # ==========================================================================

  test "CROSS-ORG: another org's sequences/enrollments NEVER appear in this org's reads", %{
    org_id: org_a
  } do
    seq_a = create_sequence(org_a, "Org A drip")
    enr_a = enroll!(org_a, seq_a, Ash.UUID.generate())

    org_b = Ash.UUID.generate()
    seq_b = create_sequence(org_b, "Org B drip")
    enr_b = enroll!(org_b, seq_b, Ash.UUID.generate())

    mount = build_mount(:crm, plane: :tenant)

    seq_ids_a = mount |> SequencesReads.sequences(Mount.scope(mount, org_a)) |> Enum.map(& &1.id)
    seq_ids_b = mount |> SequencesReads.sequences(Mount.scope(mount, org_b)) |> Enum.map(& &1.id)
    enr_ids_a = mount |> SequencesReads.enrollments(Mount.scope(mount, org_a)) |> Enum.map(& &1.id)
    enr_ids_b = mount |> SequencesReads.enrollments(Mount.scope(mount, org_b)) |> Enum.map(& &1.id)

    # Positive control — each org DOES see its own (a test that can't fail is a bug).
    assert seq_a.id in seq_ids_a
    assert seq_b.id in seq_ids_b
    assert enr_a.id in enr_ids_a
    assert enr_b.id in enr_ids_b

    # …and NEVER the other org's. A sequences page listing every tenant's enrollments is
    # exactly the regression this pins.
    refute seq_b.id in seq_ids_a
    refute seq_a.id in seq_ids_b
    refute enr_b.id in enr_ids_a
    refute enr_a.id in enr_ids_b

    # The rendered page carries the same boundary.
    html = render(org_a, plane: :tenant)
    assert html =~ "enrollment-#{enr_a.id}"
    refute html =~ "enrollment-#{enr_b.id}"
    refute html =~ "sequence-#{seq_b.id}"
  end

  # ==========================================================================
  # NO PII — the surface resolves nothing through the vault
  # ==========================================================================

  test "NO vault token ever reaches the DOM (person_id is an opaque, non-PII chip)", %{
    org_id: org_id
  } do
    seq = create_sequence(org_id, "Drip")
    enrollment = enroll!(org_id, seq, Ash.UUID.generate())

    # tenant plane…
    tenant_html = render(org_id, plane: :tenant)
    assert tenant_html =~ "enrollment-#{enrollment.id}"
    assert tenant_html =~ "Contact "
    refute tenant_html =~ "vt_"

    # …and operator plane (impersonation) — still no vault token, because there is no
    # vault field on this surface at all.
    operator_html = render(org_id, plane: :operator, target_org_id: org_id)
    assert operator_html =~ "enrollment-#{enrollment.id}"
    refute operator_html =~ "vt_"
  end

  # ==========================================================================
  # ENROLL FLOW — via the EXISTING :enroll action, tenant plane only
  # ==========================================================================

  test "enroll/4 enrolls a contact through the existing :enroll action", %{org_id: org_id} do
    seq = create_sequence(org_id, "Drip")
    mount = build_mount(:crm, plane: :tenant)
    person_id = Ash.UUID.generate()

    assert {:ok, enrollment} = SequencesReads.enroll(mount, tenant_scope(org_id), seq.id, person_id)
    assert enrollment.person_id == person_id
    assert enrollment.status in [:active, :completed]
  end

  test "enroll refuses a sequence that belongs to ANOTHER org (the enroll action's own guard)",
       %{org_id: org_a} do
    org_b = Ash.UUID.generate()
    seq_b = create_sequence(org_b, "Org B drip")
    mount = build_mount(:crm, plane: :tenant)

    # org A tries to enroll into org B's sequence — refused by the action's same-org check.
    assert {:error, _reason} =
             SequencesReads.enroll(mount, tenant_scope(org_a), seq_b.id, Ash.UUID.generate())
  end

  test "OPERATOR plane hides the enroll affordance (an operator does not author into tenant data)",
       %{org_id: org_id} do
    create_sequence(org_id, "Drip")

    html = render(org_id, plane: :operator, target_org_id: org_id)

    refute html =~ ~s(id="sequences-enroll")
    refute html =~ "Enroll contact"
  end

  test "the enroll handle_event creates an enrollment and reports success", %{org_id: org_id} do
    seq = create_sequence(org_id, "Drip")
    mount = build_mount(:crm, plane: :tenant)

    socket =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(:samen_mount, mount)
      |> Phoenix.Component.assign(:samen_acting_as, false)
      |> SequencesLive.load(org_id)

    {:noreply, after_click} =
      SequencesLive.handle_event(
        "enroll",
        %{"sequence_id" => seq.id, "person_id" => Ash.UUID.generate()},
        socket
      )

    assert length(after_click.assigns.enrollments) == 1
    html = render_html(SequencesLive, after_click.assigns)
    assert html =~ "sequences-enroll-notice"
    assert html =~ "Contact enrolled"
  end

  # ==========================================================================
  # SCOPE-ABSENCE — a host with no Outreach scope gets the honest empty state
  # ==========================================================================

  test "a mount whose host has NOT mounted the Outreach scope reads honest-empty", %{org_id: org_id} do
    bare = Mount.new(:crm, NoSuchHost.Crm, Samen.WebTest.Repo, plane: Samen.Web.Plane.tenant())

    refute SequencesReads.scope_mounted?(bare)
    assert SequencesReads.sequences(bare, Mount.scope(bare, org_id)) == []
    assert SequencesReads.enrollments(bare, Mount.scope(bare, org_id)) == []
    assert SequencesReads.step_sends_by_enrollment(bare, Mount.scope(bare, org_id)) == %{}

    html = render_live(SequencesLive, bare, [org_id])
    assert html =~ "sequences-not-mounted"
    assert html =~ "not enabled for this workspace"
  end

  # -- helpers -----------------------------------------------------------------

  # Extract just the one enrollment's <tr> …</tr> so a delivery claim on a DIFFERENT row
  # can't make a per-row honesty assert vacuously pass.
  defp enrollment_row(html, enrollment_id) do
    case Regex.run(~r/<tr[^>]*id="enrollment-#{enrollment_id}".*?<\/tr>/s, html) do
      [row] -> row
      _ -> ""
    end
  end
end
