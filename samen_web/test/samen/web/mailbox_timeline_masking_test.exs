defmodule Samen.Web.MailboxTimelineMaskingTest do
  @moduledoc """
  T74 (spec §I1) — THE PER-PLANE MASKING GATE for synced mailbox messages on the CRM
  detail timelines (INV-1, the masking watch-list discipline).

  The SAME synced message — vault-routed `subject`/`body` (`:pii_body`) and
  `counterparty_address` (`:pii_email`) — renders through the SHIPPED
  `Samen.Web.CRM.ContactLive` / `CompanyLive` Activity tab:

    1. **GREEN** — tenant plane: subject/body/counterparty resolve CLEAR.
    2. **RED** — operator (impersonation, no grant): the SAME row renders `••••`,
       with the plaintext ABSENT from the DOM and NO `vt_*` vault token anywhere.
    3. **SABOTAGE twin (anti-tautology)** — both directions are proven live on the
       SAME record (a mask-everything or clear-everything regression cannot pass),
       the row is proven PRESENT on both planes (non-vacuous), and the leak scan is
       shown to be refutable via `assert_leak_detected!/2`.
  """
  use Samen.WebTest.DataCase, async: false
  use Samen.MaskingCase

  require Ash.Query

  alias Samen.Mailbox
  alias Samen.Mailbox.{Config, FakeProvider, Message}
  alias Samen.Web.CRM.{CompanyLive, ContactLive}

  @body "MBX-MASK-BODY-SENTINEL the revised rate confirmation is attached."
  @subject "MBX-MASK-SUBJECT-SENTINEL Rate confirmation"

  setup do
    FakeProvider.reset()
    FakeProvider.set_capabilities([:inbound_sync, :outbound_send])
    on_exit(fn -> FakeProvider.reset() end)

    seeded = Seeds.seed_all()
    cfg = config(seeded.org_id)

    {:ok, connection} =
      Mailbox.connect(%{user_id: Ash.UUID.generate(), address: "rep@ourco.test"}, cfg)

    FakeProvider.deliver_to_inbox([
      %Message{
        direction: :inbound,
        external_id: "ext-mask-1",
        thread_id: "thr-mask",
        from_address: Seeds.contact_email(),
        to_addresses: ["rep@ourco.test"],
        subject: @subject,
        body: @body,
        occurred_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }
    ])

    {:ok, %{synced: 1}} = Mailbox.sync(connection, cfg)

    %{
      org_id: seeded.org_id,
      contact_id: seeded.crm.person.id,
      company_id: seeded.crm.company.id
    }
  end

  defp config(org_id) do
    %Config{
      org_id: org_id,
      repo: Samen.WebTest.Repo,
      provider: FakeProvider,
      provider_config: %{configured: true},
      connection_resource: Samen.WebTest.Mailbox.Connection,
      message_resource: Samen.WebTest.Mailbox.MailMessage,
      person_resource: Samen.WebTest.Crm.Person,
      company_resource: Samen.WebTest.Crm.Company
    }
  end

  defp activity_tab(module, mount, org_id, subject_id) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, mount)
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> module.load(org_id, subject_id)
    |> Phoenix.Component.assign(:active_tab, "activity")
    |> then(&render_html(module, &1.assigns))
  end

  # ==========================================================================
  # 1 — GREEN (tenant plane resolves CLEAR)
  # ==========================================================================

  test "GREEN: TENANT plane renders the synced message's subject/body/counterparty CLEAR on the contact timeline",
       %{org_id: org_id, contact_id: contact_id} do
    html = activity_tab(ContactLive, build_mount(:crm, plane: :tenant), org_id, contact_id)

    assert html =~ ~s(class="tl-rail")
    assert html =~ @subject
    assert html =~ @body
    assert html =~ Seeds.contact_email()
    # The direction is legible — the two-way sync's leg, rendered as the entry status.
    assert html =~ "inbound"
    # Even on the clear plane, the raw vault token never reaches the DOM.
    refute html =~ "vt_"
  end

  test "GREEN: the same message is CLEAR on the COMPANY timeline too (secondary anchor)", %{
    org_id: org_id,
    company_id: company_id
  } do
    html = activity_tab(CompanyLive, build_mount(:crm, plane: :tenant), org_id, company_id)

    assert html =~ @subject
    assert html =~ @body
    refute html =~ "vt_"
  end

  # ==========================================================================
  # 2 — RED (operator without grant renders •••• and leaks nothing)
  # ==========================================================================

  test "RED: OPERATOR plane renders •••• — subject/body/counterparty ABSENT, no vt_ token",
       %{org_id: org_id, contact_id: contact_id} do
    mount = build_mount(:crm, plane: :operator, target_org_id: org_id)
    html = activity_tab(ContactLive, mount, org_id, contact_id)

    # Non-vacuous: the SAME timeline rail and the SAME entry are rendered…
    assert html =~ ~s(class="tl-rail")
    assert html =~ "inbound"
    assert html =~ mask()
    # …and every 🔒 field is absent.
    refute html =~ @subject
    refute html =~ @body
    refute html =~ Seeds.contact_email()
    refute html =~ "vt_"
  end

  test "RED: the COMPANY timeline masks the same message identically", %{
    org_id: org_id,
    company_id: company_id
  } do
    mount = build_mount(:crm, plane: :operator, target_org_id: org_id)
    html = activity_tab(CompanyLive, mount, org_id, company_id)

    assert html =~ ~s(class="tl-rail")
    assert html =~ mask()
    refute html =~ @subject
    refute html =~ @body
    refute html =~ "vt_"
  end

  # ==========================================================================
  # 3 — SABOTAGE TWIN (anti-tautology): both directions + a refutable leak scan
  # ==========================================================================

  test "ANTI-TAUTOLOGY: the SAME record is CLEAR on tenant and MASKED on operator (plane flip)",
       %{org_id: org_id, contact_id: contact_id} do
    tenant_html = activity_tab(ContactLive, build_mount(:crm, plane: :tenant), org_id, contact_id)

    operator_html =
      activity_tab(
        ContactLive,
        build_mount(:crm, plane: :operator, target_org_id: org_id),
        org_id,
        contact_id
      )

    # The same entry exists on BOTH planes — the only difference is masking.
    assert tenant_html =~ "inbound"
    assert operator_html =~ "inbound"
    assert tenant_html =~ @body
    refute operator_html =~ @body
    assert operator_html =~ mask()
  end

  test "ANTI-TAUTOLOGY: the leak scan is REFUTABLE — a modelled clear render IS detected", %{
    org_id: org_id,
    contact_id: contact_id
  } do
    operator_html =
      activity_tab(
        ContactLive,
        build_mount(:crm, plane: :operator, target_org_id: org_id),
        org_id,
        contact_id
      )

    # AS-DESIGNED: the operator DOM does not carry the sentinels.
    assert_masked_dom!(operator_html, [@body, @subject, Seeds.contact_email()])

    # REFUTABLE: the SAME scan applied to a deliberately-leaked render catches it —
    # so the assertions above are discriminating, not vacuously true.
    leaked = operator_html <> @body
    assert_leak_detected!(leaked, @body)
  end

  # ==========================================================================
  # 4 — the resolver itself (record level), both planes
  # ==========================================================================

  test "record level: tenant resolves the vaulted fields clear; operator resolves %Masked{}", %{
    org_id: org_id
  } do
    row =
      Samen.WebTest.Mailbox.MailMessage
      |> Ash.Query.filter(org_id == ^org_id)
      |> Ash.Query.ensure_selected([:subject, :body, :counterparty_address])
      |> Ash.read_one!(authorize?: false)

    clear = resolve_on_plane(row, Samen.WebTest.Mailbox.MailMessage, :tenant, repo: Samen.WebTest.Repo)
    assert_plane_clear!(clear.body, @body)
    assert_plane_clear!(clear.subject, @subject)

    masked =
      resolve_on_plane(row, Samen.WebTest.Mailbox.MailMessage, :operator, repo: Samen.WebTest.Repo)

    assert_plane_masked!(masked.body, @body)
    assert_plane_masked!(masked.subject, @subject)
    assert_plane_masked!(masked.counterparty_address, Seeds.contact_email())
    refute to_string(masked.body) =~ "vt_"
  end
end
