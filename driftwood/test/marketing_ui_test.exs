defmodule Driftwood.MarketingUiTest do
  @moduledoc """
  Marketing / outreach UI tests — the inherited Marketing module rendered by the FRAMEWORK
  (ADR-011 §7), MOUNTED by `DriftwoodWeb.Router`
  (`samen_module_routes :marketing, Driftwood.Marketing, ...`) over Driftwood's materialized
  `Driftwood.Marketing.*` resources. The DEEP render/masking + red-path coverage lives in
  samen_web's own suite (`web/marketing_render_test.exs`); these driftwood-side tests prove
  Driftwood's OWN MOUNT is correct:

    1. Each mounted Marketing page renders with Driftwood's seeded rows (non-vacuous).
    2. CONSENT / SUPPRESSION red path — `enqueue_send` REFUSES a suppressed subscriber
       (no send row) over Driftwood's Marketing resources.
    3. OPERATOR ISOLATION — the operator plane cannot enumerate a tenant's subscriber emails:
       the subscriber email renders •••• and the plaintext is ABSENT.
  """
  use Driftwood.DataCase, async: false

  alias Samen.Web.Marketing
  alias Samen.Web.Marketing.Reads
  alias Samen.Web.Mount

  @carrier_email "dana.marketing.plaintext@carrier.example"
  @opted_out_email "optedout.marketing.plaintext@carrier.example"

  setup do
    org_id = Ecto.UUID.generate()
    seeded = seed_marketing(org_id)
    Map.put(seeded, :org_id, org_id)
  end

  # ==========================================================================
  # MOUNTED ROUTES render Driftwood's seeded rows
  # ==========================================================================

  test "the mounted /marketing/campaigns renders Driftwood's seeded campaign", %{org_id: org_id} do
    mount = driftwood_mount(:marketing)
    html = render_framework(Marketing.CampaignsLive, mount, [org_id])

    assert html =~ ~s(class="app")
    assert html =~ "Campaigns"
    assert html =~ "Q3 lane-offer outreach"
    refute html =~ "vt_"
  end

  test "the mounted /marketing/segments renders segments + subscribers (email clear on tenant)", %{org_id: org_id} do
    mount = driftwood_mount(:marketing)
    html = render_framework(Marketing.SegmentsLive, mount, [org_id])

    assert html =~ "Audience segments"
    assert html =~ "Active carriers"
    # The tenant reads its own subscribers' email in the CLEAR.
    assert html =~ @carrier_email
    assert html =~ @opted_out_email
    # The opted-out subscriber is flagged suppressed.
    assert html =~ "suppressed"
    refute html =~ "vt_"
  end

  test "the mounted /marketing/campaigns/:id renders the compose form + recipients clear", %{
    org_id: org_id,
    campaign: campaign
  } do
    mount = driftwood_mount(:marketing)
    html = render_framework(Marketing.CampaignLive, mount, [org_id, campaign.id])

    assert html =~ "campaign-header"
    assert html =~ ~s(id="send-campaign-form")
    assert html =~ @carrier_email
    refute html =~ "vt_"
  end

  # ==========================================================================
  # CONSENT / SUPPRESSION red path over Driftwood's Marketing resources
  # ==========================================================================

  test "RED PATH: enqueue_send REFUSES the suppressed subscriber — no send row", %{
    org_id: org_id,
    campaign: campaign,
    suppressed: suppressed
  } do
    mount = driftwood_mount(:marketing)
    scope = Mount.scope(mount, org_id)

    before = length(Reads.sends_for_campaign(mount, scope, campaign.id))

    assert {:error, :suppressed} =
             Reads.enqueue_send(mount, scope, %{
               subscriber_id: suppressed.id,
               org_id: org_id,
               campaign_id: campaign.id
             })

    assert length(Reads.sends_for_campaign(mount, scope, campaign.id)) == before
  end

  test "GREEN PATH: enqueue_send queues the active subscriber — a send row + Oban job", %{
    org_id: org_id,
    campaign: campaign,
    active: active
  } do
    mount = driftwood_mount(:marketing)
    scope = Mount.scope(mount, org_id)

    assert {:ok, send} =
             Reads.enqueue_send(mount, scope, %{
               subscriber_id: active.id,
               org_id: org_id,
               campaign_id: campaign.id
             })

    assert send.subscriber_id == active.id
    assert send.status == :queued
  end

  # ==========================================================================
  # OPERATOR ISOLATION — no enumeration of a tenant's subscriber emails
  # ==========================================================================

  test "OPERATOR: subscriber emails are MASKED (••••), plaintext + token ABSENT, send controls hidden", %{
    org_id: org_id,
    campaign: campaign
  } do
    mount = driftwood_mount(:marketing, plane: :operator, target_org_id: org_id)

    seg_html = render_framework(Marketing.SegmentsLive, mount, [org_id])
    assert seg_html =~ "Active carriers"
    assert seg_html =~ "••••"
    refute seg_html =~ @carrier_email
    refute seg_html =~ @opted_out_email
    refute seg_html =~ "vt_"
    refute seg_html =~ "pii_"

    camp_html = render_framework(Marketing.CampaignLive, mount, [org_id, campaign.id])
    assert camp_html =~ "••••"
    refute camp_html =~ @carrier_email
    # The send controls are not offered to an operator.
    refute camp_html =~ ~s(id="send-campaign-form")
  end

  test "OPERATOR: Reads.subscribers masks the email; TENANT reads it clear", %{org_id: org_id} do
    op = driftwood_mount(:marketing, plane: :operator, target_org_id: org_id)
    op_subs = Reads.subscribers(op, Mount.scope(op, org_id))
    assert op_subs != []
    assert Enum.all?(op_subs, fn s -> match?(%Samen.Masked{}, s.email) end)

    tn = driftwood_mount(:marketing)
    tn_subs = Reads.subscribers(tn, Mount.scope(tn, org_id))
    assert Enum.any?(tn_subs, fn s -> s.email == @carrier_email end)
  end

  # -- seed helper -------------------------------------------------------------

  defp seed_marketing(org_id) do
    admin = %{org_id: org_id, role: :admin, plane: :tenant, kind: :tenant}
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    campaign =
      Driftwood.Marketing.Campaign
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: org_id, name: "Q3 lane-offer outreach", description: "Active carriers", status: :draft},
        actor: admin,
        authorize?: false
      )
      |> Ash.create!()

    Driftwood.Marketing.Template
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org_id, name: "Carrier onboarding", subject_line: "Partner with us", enabled: true},
      actor: admin,
      authorize?: false
    )
    |> Ash.create!()

    Driftwood.Marketing.Segment
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org_id, name: "Active carriers", filter_criteria: %{"status" => "active"}, subscriber_count: 1},
      actor: admin,
      authorize?: false
    )
    |> Ash.create!()

    active =
      Driftwood.Marketing.Subscriber
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: org_id, email: @carrier_email, status: :active, consent_at: now, source: "crm"},
        authorize?: false
      )
      |> Ash.create!()

    suppressed =
      Driftwood.Marketing.Subscriber
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: org_id, email: @opted_out_email, status: :active, source: "import"},
        authorize?: false
      )
      |> Ash.create!()

    Driftwood.Marketing.Suppression
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org_id, subscriber_id: suppressed.id, reason: :unsubscribed, active: true, suppressed_at: now},
      actor: admin,
      authorize?: false
    )
    |> Ash.create!()

    %{campaign: campaign, active: active, suppressed: suppressed}
  end
end
