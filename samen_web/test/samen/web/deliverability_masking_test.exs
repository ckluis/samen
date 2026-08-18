defmodule Samen.Web.DeliverabilityMaskingTest do
  @moduledoc """
  T114 (R2) — THE PER-PLANE MASKING GATE for the new operator deliverability
  surface (`Samen.Web.Operator.DeliverabilityLive`). `dlv_email_event` /
  `dlv_suppression` carry no PII themselves (opaque `subscriber_id` only); this
  surface's ONLY masking-relevant behavior is resolving that id to an
  `Identity.User`'s vault-routed `full_name`/`emails` through
  `Samen.Api.PiiResolution` — the SAME chokepoint every framework read uses
  (`Samen.Web.Operator.DeliverabilityReads.resolve_recipient/5`).

  Per CLAUDE.md's per-plane masking discipline (`Samen.MaskingCase`), THREE
  proofs:

    1. GREEN — operator WITH a live reveal grant resolves the recipient CLEAR
       (plaintext name + email, no `vt_*` token).
    2. RED — operator WITHOUT a grant sees `••••`: the recipient is masked on
       BOTH the suppression-list row and the delivery-timeline row for the SAME
       subscriber; plaintext is ABSENT from the DOM; no `vt_*` token leaks.
    3. SABOTAGE TWIN (anti-tautology) — the SAME record flipped to the tenant
       plane leaks the plaintext, proving the RED scan above is refutable (a
       real leak WOULD be caught), not vacuously true.
  """
  use Samen.WebTest.DataCase, async: false
  use Samen.MaskingCase

  alias Samen.Delivery.{EmailEvent, Suppression}
  alias Samen.Web.Operator.DeliverabilityLive
  alias Samen.WebTest.Operator, as: Op
  alias Samen.WebTest.Repo

  # A distinctive sentinel — if it EVER appears in an operator-without-grant DOM,
  # the mask-by-default red-path has failed.
  @recipient_first "Zelphine"
  @recipient_last "Redactatest"
  @recipient_email "zelphine.redact.sentinel@example.test"

  # ---------------------------------------------------------------------------
  # Grant stubs — inject the reveal authority per test (the T1.6 grant model,
  # the SAME pattern `file_preview_masking_test.exs`/`notifications_masking_test.exs` use).
  # ---------------------------------------------------------------------------

  defmodule AllowAllGrant do
    @moduledoc false
    def granted?(_ctx), do: true
  end

  defmodule DenyAllGrant do
    @moduledoc false
    def granted?(_ctx), do: false
  end

  # ---------------------------------------------------------------------------
  # Seed: one tenant org, one recipient User, one bounce event, one suppression.
  # ---------------------------------------------------------------------------

  setup do
    org =
      Op.Org
      |> Ash.Changeset.for_create(:create, %{name: "T114 Deliverability Test Org", plan: "growth"}, authorize?: false)
      |> Ash.create!()

    user =
      Op.User
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org.id,
          handle: "recipient-mask-sentinel",
          status: "active",
          full_name: %Samen.Type.FullName{first: @recipient_first, last: @recipient_last},
          emails: [%{label: "work", address: @recipient_email}]
        },
        authorize?: false
      )
      |> Ash.create!()

    {:ok, :inserted, event} =
      EmailEvent.record(Repo, %{
        provider: "masktest",
        provider_event_id: "evt_mask_#{System.unique_integer([:positive])}",
        provider_message_id: "msg_mask",
        kind: "bounce",
        send_id: Ash.UUID.generate(),
        org_id: org.id,
        subscriber_id: user.id,
        occurred_at: DateTime.utc_now()
      })

    {:ok, suppression} =
      Suppression.suppress(Repo, %{org_id: org.id, subscriber_id: user.id, reason: "bounce"})

    %{org: org, user: user, event: event, suppression: suppression}
  end

  # T150: the production drill-in read now runs through a real impersonation-session gate.
  # For the grant-driven masking tests (which inject `:grant`, not `:actor`), open a real
  # session so the gate passes; the injected grant still drives clear-vs-•••• through
  # `PiiResolution`. The anti-tautology test injects `:actor` directly (the resolved-actor
  # seam) and bypasses the gate — no session needed there.
  defp render_deliverability(org_id, opts) do
    operator_id = Ecto.UUID.generate()
    mount = build_operator_mount(Ecto.UUID.generate())

    socket = Phoenix.Component.assign(%Phoenix.LiveView.Socket{}, :samen_mount, mount)

    socket =
      if Keyword.has_key?(opts, :actor) do
        socket
      else
        open_impersonation!(operator_id, org_id)
        with_operator_identity(socket, operator_id)
      end

    socket
    |> DeliverabilityLive.load(org_id, opts)
    |> then(&render_html(DeliverabilityLive, &1.assigns))
  end

  # ==========================================================================
  # GREEN — operator WITH a live grant resolves CLEAR
  # ==========================================================================

  test "operator WITH a reveal grant sees the recipient CLEAR (plaintext, no vt_ token)", %{org: org} do
    html = render_deliverability(org.id, grant: AllowAllGrant)

    assert html =~ @recipient_email
    assert html =~ "#{@recipient_first} #{@recipient_last}"
    # The row itself is present (non-vacuous — the SAME record, not a different one).
    assert html =~ "bounce"
    refute html =~ "vt_"
  end

  # ==========================================================================
  # RED — operator WITHOUT a grant sees •••• on BOTH surfaces (suppression +
  # timeline), plaintext ABSENT, no vt_ token leaked (INV-1's red path).
  # ==========================================================================

  test "operator WITHOUT a grant sees •••• on the suppression row AND the delivery-timeline row (INV-1)",
       %{org: org} do
    html = render_deliverability(org.id, grant: DenyAllGrant)

    # The mask sentinel is present (impersonation-shaped actor => %Masked{} rendered,
    # not omitted) …
    assert html =~ "••••"
    # … the rows themselves exist (non-vacuous: same records, same page) …
    assert html =~ "bounce"
    # … and the plaintext is ABSENT everywhere on the page.
    refute html =~ @recipient_email
    refute html =~ "#{@recipient_first} #{@recipient_last}"
    refute html =~ @recipient_first
    refute html =~ @recipient_last
    # No vault token leaks either (the ADR-009/010 red-path scan).
    refute html =~ "vt_"
  end

  test "operator WITHOUT a grant: BOTH the suppression list row and the timeline row for the SAME subscriber mask",
       %{org: org, suppression: suppression, event: event} do
    html = render_deliverability(org.id, grant: DenyAllGrant)

    assert html =~ "suppression-#{suppression.id}"
    assert html =~ "event-#{event.id}"
    refute html =~ @recipient_email
  end

  # ==========================================================================
  # BOTH directions on the SAME record — anti-tautology (mirrors
  # notifications_masking_test.exs's "crown-jewel shape").
  # ==========================================================================

  test "BOTH directions on the SAME record — operator-with-grant clear vs operator-without-grant masked",
       %{org: org} do
    clear_html = render_deliverability(org.id, grant: AllowAllGrant)
    masked_html = render_deliverability(org.id, grant: DenyAllGrant)

    assert clear_html =~ @recipient_email
    refute masked_html =~ @recipient_email
    assert masked_html =~ "••••"
  end

  # ==========================================================================
  # SABOTAGE TWIN — the RED scan above is REFUTABLE: the same record on the
  # TENANT plane leaks the plaintext, so `refute html =~ @recipient_email` in
  # the red-path tests is a genuine gate, not a tautology.
  # ==========================================================================

  test "ANTI-TAUTOLOGY: the same record on the TENANT plane leaks plaintext (proving the mask scan is refutable)",
       %{org: org} do
    leaked_html = render_deliverability(org.id, actor: %{plane: :tenant})

    assert_leak_detected!(leaked_html, @recipient_email)
    assert_leak_detected!(leaked_html, "#{@recipient_first} #{@recipient_last}")
  end

  # ==========================================================================
  # Fail-honest fallback: an unresolvable subscriber_id never fabricates PII.
  # ==========================================================================

  test "a subscriber_id with no matching User renders the bounded id, never a fabricated identity" do
    org_id = Ash.UUID.generate()
    stray_subscriber = Ash.UUID.generate()

    {:ok, :inserted, _event} =
      EmailEvent.record(Repo, %{
        provider: "masktest",
        provider_event_id: "evt_stray_#{System.unique_integer([:positive])}",
        kind: "delivered",
        send_id: Ash.UUID.generate(),
        org_id: org_id,
        subscriber_id: stray_subscriber,
        occurred_at: DateTime.utc_now()
      })

    html = render_deliverability(org_id, grant: DenyAllGrant)

    assert html =~ "subscriber "
    # No PII field was ever resolved (the recipient is unknown) — the mask branch
    # never engages, and no vault token leaks either.
    refute html =~ "••••"
    refute html =~ "vt_"
  end
end
