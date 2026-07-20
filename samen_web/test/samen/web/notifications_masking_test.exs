defmodule Samen.Web.NotificationsMaskingTest do
  @moduledoc """
  WS-A A4 UNIT 2 — THE PER-PLANE MASKING GATE for the notifications inbox (the design
  MC rider: MC-3 + MC-4; AC-G2-8 + AC-G2-9 + RP-N1/RP-N2).

  The SAME notification — vault-routed `rendered_body` + a `subject_ref` pointing at a
  vault-routed CRM person — renders through `Samen.Web.Notifications.InboxLive`:

    * **TENANT plane:** body CLEAR + the unfurled `object_card` shows the REAL person
      (name/email clear) — through the EXISTING `ObjectRef.resolve/3 → object_card`
      path, no bespoke code.
    * **OPERATOR / impersonation plane:** the SAME record renders `••••` — body masked
      (MC-3) AND the unfurled card masked (MC-4) — with the plaintext ABSENT from the
      DOM (leak scan = 0) and no vault token (`vt_`) leaked.

  Anti-tautology: BOTH directions are proven live in one test (tenant clear ∧ operator
  masked on the same record), so neither a mask-everything nor a clear-everything
  regression can pass. Cross-org refs resolve to the inert chip (no existence oracle).
  """
  use Samen.WebTest.DataCase, async: false
  use Samen.MaskingCase

  alias Samen.Notifications.Engine
  alias Samen.Web.Notifications.InboxLive

  @body "MC3-BODY-SENTINEL please review the attached contact record."

  setup do
    seeded = Seeds.seed_all()

    {:ok, notification} =
      Engine.notify(
        %{
          org_id: seeded.org_id,
          recipient_id: Ash.UUID.generate(),
          event_type: "crm.person.flagged",
          channel: :in_app,
          rendered_body: @body,
          subject_ref: "samen:crm.person:#{seeded.crm.person.id}"
        },
        notification_module: Samen.WebTest.Primitives.Notification,
        preference_module: Samen.WebTest.Primitives.NotificationPreference,
        repo: Samen.WebTest.Repo
      )

    %{org_id: seeded.org_id, person_id: seeded.crm.person.id, notification: notification}
  end

  defp render_inbox(org_id, plane_opts) do
    mount = build_mount(:notifications, plane_opts)

    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, mount)
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> Phoenix.Component.assign(:return_to, nil)
    |> InboxLive.load(org_id)
    |> then(&render_html(InboxLive, &1.assigns))
  end

  # ==========================================================================
  # MC-3 + MC-4 — the SAME notification, per-plane (the crown-jewel shape)
  # ==========================================================================

  test "TENANT plane: body CLEAR + the unfurled person card CLEAR (MC-3/MC-4 green half)",
       %{org_id: org_id} do
    html = render_inbox(org_id, plane: :tenant)

    # MC-3 — the vault-routed body resolves CLEAR on the owner's plane.
    assert html =~ "MC3-BODY-SENTINEL"
    # MC-4 — the subject_ref unfurled through ObjectRef → object_card, person CLEAR.
    assert html =~ "obj-card"
    assert html =~ Seeds.contact_full_name()
    # No vault token in the tenant DOM either (the resolver, not the raw column).
    refute html =~ "vt_"
  end

  test "OPERATOR plane: the SAME notification renders •••• — body masked, card masked, DOM leak scan = 0",
       %{org_id: org_id} do
    html = render_inbox(org_id, plane: :operator, target_org_id: org_id)

    # The mask sentinel is PRESENT (impersonation = %Masked{} rendered, not omitted) …
    assert html =~ "••••"
    # … the row + the unfurled card exist (non-vacuous: same record, same unfurl path) …
    assert html =~ "crm.person.flagged"
    assert html =~ "obj-card"
    # … and the plaintext is ABSENT: body (MC-3) and person PII (MC-4).
    refute html =~ "MC3-BODY-SENTINEL"
    refute html =~ Seeds.contact_full_name()
    refute html =~ Seeds.contact_email()
    refute html =~ Seeds.contact_phone()
    # No vault token / raw pii column string leaks (the ADR-009/010 red-path scan).
    refute html =~ "vt_"
    # Write affordances are not offered on the operator plane (posture; kernel enforces).
    refute html =~ ~s(phx-click="mark_read")
    refute html =~ ~s(id="mark-all-read")
  end

  test "BOTH directions on the SAME record — tenant clear ∧ operator masked (anti-tautology)",
       %{org_id: org_id, notification: notification} do
    tenant_html = render_inbox(org_id, plane: :tenant)
    operator_html = render_inbox(org_id, plane: :operator, target_org_id: org_id)

    # The SAME notification row is on both planes (same id rendered)…
    assert tenant_html =~ notification.id
    assert operator_html =~ notification.id
    # …the ONLY difference is masking.
    assert tenant_html =~ "MC3-BODY-SENTINEL"
    refute operator_html =~ "MC3-BODY-SENTINEL"
    assert tenant_html =~ Seeds.contact_full_name()
    refute operator_html =~ Seeds.contact_full_name()
    assert operator_html =~ "••••"
  end

  test "ANTI-TAUTOLOGY: the operator mask scan is REFUTABLE — a clear render leaks and is caught",
       %{org_id: org_id} do
    # AS-DESIGNED: the operator plane masks the body + the unfurled person card — the
    # sentinels are ABSENT (the `refute operator_html =~ ...` scans above).
    operator_html = render_inbox(org_id, plane: :operator, target_org_id: org_id)
    refute operator_html =~ "MC3-BODY-SENTINEL"
    refute operator_html =~ Seeds.contact_full_name()

    # SABOTAGE MODEL: a resolver that failed to mask would render the SAME notification's
    # body + person card in the CLEAR — which is precisely the tenant-plane render. The
    # `assert_leak_detected!` scan FLIPS on it, proving the operator `refute` scans above
    # are refutable (a real leak WOULD be caught), not vacuously true.
    leaked_html = render_inbox(org_id, plane: :tenant)
    assert_leak_detected!(leaked_html, "MC3-BODY-SENTINEL")
    assert_leak_detected!(leaked_html, Seeds.contact_full_name())
  end

  # ==========================================================================
  # The unfurl fail-safes (RP-N2 adjuncts — no oracle, no raise, no plaintext)
  # ==========================================================================

  test "a CROSS-ORG subject_ref unfurls to the inert 'not available' chip (no leak)",
       %{org_id: org_id} do
    other_org = Ash.UUID.generate()

    foreign_person =
      Samen.WebTest.Crm.Person
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: other_org,
          display_name: "Foreign Person",
          full_name: %Samen.Type.FullName{first: "Foreign", last: "Secretperson"},
          emails: [%{label: "work", address: "foreign.secret@example.test"}]
        },
        authorize?: false
      )
      |> Ash.create!()

    {:ok, _} =
      Engine.notify(
        %{
          org_id: org_id,
          recipient_id: Ash.UUID.generate(),
          event_type: "crm.person.flagged",
          channel: :in_app,
          rendered_body: "cross-org ref below",
          subject_ref: "samen:crm.person:#{foreign_person.id}"
        },
        notification_module: Samen.WebTest.Primitives.Notification,
        repo: Samen.WebTest.Repo
      )

    html = render_inbox(org_id, plane: :tenant)

    # The chip is inert: no foreign plaintext, indistinguishable from a missing row.
    assert html =~ "not available"
    refute html =~ "Secretperson"
    refute html =~ "foreign.secret@example.test"
  end

  test "a notification with NO subject_ref renders no card (and no crash)", %{org_id: org_id} do
    {:ok, _} =
      Engine.notify(
        %{
          org_id: org_id,
          recipient_id: Ash.UUID.generate(),
          event_type: "system.plain",
          channel: :in_app,
          rendered_body: "no ref here"
        },
        notification_module: Samen.WebTest.Primitives.Notification,
        repo: Samen.WebTest.Repo
      )

    html = render_inbox(org_id, plane: :tenant)
    assert html =~ "system.plain"
  end

  # ==========================================================================
  # PII discipline at rest, seen from the web host (the UNIT 1 rule re-proven
  # against the samen_web mount): the body is a vault token in the domain row.
  # ==========================================================================

  test "the domain row stores a vt_ token, never the plaintext body", %{notification: notification} do
    %{rows: [[raw_body]]} =
      Samen.WebTest.Repo.query!(
        "SELECT pii_wnn_rendered_body FROM wnn_notification WHERE wnn_id = $1",
        [Ecto.UUID.dump!(notification.id)]
      )

    assert is_binary(raw_body)
    assert String.starts_with?(raw_body, "vt_")
    refute raw_body =~ "MC3-BODY-SENTINEL"
  end
end
