defmodule Samen.Web.MarketingRenderTest do
  @moduledoc """
  Framework Marketing / outreach render + red-path tests (ADR-011 §7/§8) against the
  standalone test-support host. Proves the ADR-011 Phase-4/5 contract:

    1. `/marketing/campaigns`, `/marketing/campaigns/:id`, `/marketing/segments`,
       `/marketing/leads` all render 200 with the seeded data.
    2. CONSENT/SUPPRESSION red path — a send to a SUPPRESSED subscriber REFUSES
       (`{:error, :suppressed}`): no send row, no Oban job. A send to a DELIVERABLE
       subscriber succeeds.
    3. OPERATOR ISOLATION — the operator plane cannot enumerate a tenant's contact/subscriber
       emails: the subscriber `email` renders `••••` (masked) on the operator plane, the
       plaintext is ABSENT, no vault token leaks, and the compose/send controls are hidden.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Marketing.Reads
  alias Samen.Web.Mount

  setup do
    seeded = Seeds.seed_all()

    %{
      org_id: seeded.org_id,
      campaign_id: seeded.marketing.campaign.id,
      segment: seeded.marketing.segment,
      template_id: seeded.marketing.template.id,
      active_subscriber_id: seeded.marketing.active_subscriber.id,
      suppressed_subscriber_id: seeded.marketing.suppressed_subscriber.id
    }
  end

  # ==========================================================================
  # (a) The outreach + prospecting routes render 200 with data
  # ==========================================================================

  test "TENANT: /marketing/campaigns lists the seeded campaign", %{org_id: org_id} do
    mount = build_mount(:marketing)
    html = render_live(Samen.Web.Marketing.CampaignsLive, mount, [org_id])

    assert html =~ ~s(class="app")
    assert html =~ "Campaigns"
    assert html =~ Seeds.campaign_name()
  end

  test "TENANT: /marketing/campaigns/:id renders the compose page + the deliverable recipient in the clear", %{
    org_id: org_id,
    campaign_id: campaign_id
  } do
    mount = build_mount(:marketing)
    html = render_live(Samen.Web.Marketing.CampaignLive, mount, [org_id, campaign_id])

    assert html =~ "campaign-header"
    assert html =~ Seeds.campaign_name()
    # The compose form (tenant plane) is present.
    assert html =~ ~s(id="send-campaign-form")
    # The template + segment selects are populated.
    assert html =~ Seeds.template_name()
    assert html =~ Seeds.segment_name()
    # The recipient email is CLEAR on the tenant plane (the org owns its subscribers).
    assert html =~ Seeds.active_subscriber_email()
  end

  test "TENANT: /marketing/segments lists the segment + subscribers + the suppression flag", %{org_id: org_id} do
    mount = build_mount(:marketing)
    html = render_live(Samen.Web.Marketing.SegmentsLive, mount, [org_id])

    assert html =~ "Audience segments"
    assert html =~ Seeds.segment_name()
    # Both subscribers listed; emails clear on tenant.
    assert html =~ Seeds.active_subscriber_email()
    assert html =~ Seeds.suppressed_subscriber_email()
    # The suppressed subscriber is flagged.
    assert html =~ "suppressed"
  end

  test "TENANT: /marketing/leads lists the CRM lead (lifecycle lead) with its email clear", %{org_id: org_id} do
    mount = build_mount(:marketing)
    html = render_live(Samen.Web.Marketing.LeadsLive, mount, [org_id])

    assert html =~ "Leads"
    # The seeded CRM person has lifecycle_stage "lead" → appears in the leads lens, clear.
    assert html =~ Seeds.contact_full_name()
    assert html =~ Seeds.contact_email()
  end

  # ==========================================================================
  # (b) CONSENT / SUPPRESSION red path
  # ==========================================================================

  test "RED PATH: enqueue_send REFUSES a suppressed subscriber — no send row", %{
    org_id: org_id,
    campaign_id: campaign_id,
    suppressed_subscriber_id: suppressed_id
  } do
    mount = build_mount(:marketing)
    scope = Mount.scope(mount, org_id)

    before_count = length(Reads.sends_for_campaign(mount, scope, campaign_id))

    assert {:error, :suppressed} =
             Reads.enqueue_send(mount, scope, %{
               subscriber_id: suppressed_id,
               org_id: org_id,
               campaign_id: campaign_id
             })

    # No send row was created for the suppressed subscriber.
    after_count = length(Reads.sends_for_campaign(mount, scope, campaign_id))
    assert after_count == before_count
  end

  test "GREEN PATH: enqueue_send SUCCEEDS for a deliverable subscriber — a send row is created", %{
    org_id: org_id,
    campaign_id: campaign_id,
    active_subscriber_id: active_id
  } do
    mount = build_mount(:marketing)
    scope = Mount.scope(mount, org_id)

    assert {:ok, send} =
             Reads.enqueue_send(mount, scope, %{
               subscriber_id: active_id,
               org_id: org_id,
               campaign_id: campaign_id
             })

    assert send.subscriber_id == active_id
    assert send.status == :queued

    sends = Reads.sends_for_campaign(mount, scope, campaign_id)
    assert Enum.any?(sends, &(&1.id == send.id))
  end

  test "send_campaign_to_segment queues the active recipient (the segment audience is deliverable)", %{
    org_id: org_id,
    campaign_id: campaign_id,
    segment: segment,
    template_id: template_id
  } do
    mount = build_mount(:marketing)
    scope = Mount.scope(mount, org_id)
    {:ok, campaign} = Reads.get_campaign(mount, scope, campaign_id)

    results = Reads.send_campaign_to_segment(mount, scope, campaign, segment, template_id, org_id)

    # The segment audience is the ACTIVE subscriber → queued.
    assert Enum.any?(results, &match?(%{result: {:ok, _}}, &1))
  end

  test "send_to_subscribers surfaces per-recipient refusal for a mixed batch (active queued, suppressed refused)", %{
    org_id: org_id,
    campaign_id: campaign_id,
    active_subscriber_id: active_id,
    suppressed_subscriber_id: suppressed_id
  } do
    mount = build_mount(:marketing)
    scope = Mount.scope(mount, org_id)
    {:ok, campaign} = Reads.get_campaign(mount, scope, campaign_id)

    results = Reads.send_to_subscribers(mount, scope, [active_id, suppressed_id], campaign, nil, org_id)

    active_result = Enum.find(results, &(&1.subscriber_id == active_id))
    suppressed_result = Enum.find(results, &(&1.subscriber_id == suppressed_id))

    assert match?(%{result: {:ok, _}}, active_result)
    assert match?(%{result: {:error, :suppressed}}, suppressed_result)
  end

  test "the compose page RENDERS the refusal after a send attempt on a suppressed recipient", %{
    org_id: org_id,
    campaign_id: campaign_id,
    suppressed_subscriber_id: suppressed_id
  } do
    mount = build_mount(:marketing)
    scope = Mount.scope(mount, org_id)
    {:ok, campaign} = Reads.get_campaign(mount, scope, campaign_id)

    # Drive the results through the LiveView render path (send_results assign) to prove the
    # UI surfaces "suppressed — skipped".
    results = Reads.send_to_subscribers(mount, scope, [suppressed_id], campaign, nil, org_id)

    socket =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(:samen_mount, mount)
      |> Phoenix.Component.assign(:samen_acting_as, false)
      |> Samen.Web.Marketing.CampaignLive.load(org_id, campaign_id)
      |> Phoenix.Component.assign(:send_results, results)
      |> Phoenix.Component.assign(:notice, "Enqueued 0 send(s); 1 refused.")

    html = render_html(Samen.Web.Marketing.CampaignLive, socket.assigns)
    assert html =~ "suppressed — skipped"
  end

  # ==========================================================================
  # (c) OPERATOR ISOLATION — the operator plane cannot enumerate contact emails
  # ==========================================================================

  test "OPERATOR: the subscriber email is MASKED (••••) — plaintext + vault token ABSENT", %{org_id: org_id} do
    mount = build_mount(:marketing, plane: :operator, target_org_id: org_id)
    html = render_live(Samen.Web.Marketing.SegmentsLive, mount, [org_id])

    # Non-vacuous: the operator opened the tenant's segment view (segment name present).
    assert html =~ Seeds.segment_name()
    # Masked sentinel present.
    assert html =~ "••••"
    # The tenant's subscriber emails are ABSENT (not enumerable on the operator plane).
    refute html =~ Seeds.active_subscriber_email()
    refute html =~ Seeds.suppressed_subscriber_email()
    # No vault token / pii_ column leak.
    refute html =~ "vt_"
    refute html =~ "pii_"
  end

  test "OPERATOR: the campaign compose page masks recipients AND hides the send controls", %{
    org_id: org_id,
    campaign_id: campaign_id
  } do
    mount = build_mount(:marketing, plane: :operator, target_org_id: org_id)
    html = render_live(Samen.Web.Marketing.CampaignLive, mount, [org_id, campaign_id])

    # The operator opened the campaign (header present).
    assert html =~ "campaign-header"
    # Recipient emails masked, plaintext absent.
    assert html =~ "••••"
    refute html =~ Seeds.active_subscriber_email()
    # The send controls are NOT offered to an operator.
    refute html =~ ~s(id="send-campaign-form")
    refute html =~ "vt_"
  end

  test "OPERATOR: Reads.subscribers returns the email as %Masked{} on the operator plane", %{org_id: org_id} do
    mount = build_mount(:marketing, plane: :operator, target_org_id: org_id)
    scope = Mount.scope(mount, org_id)

    subs = Reads.subscribers(mount, scope)
    assert subs != []
    assert Enum.all?(subs, fn s -> match?(%Samen.Masked{}, s.email) end)
  end

  test "TENANT: Reads.subscribers returns the email in the CLEAR on the tenant plane", %{org_id: org_id} do
    mount = build_mount(:marketing, plane: :tenant)
    scope = Mount.scope(mount, org_id)

    subs = Reads.subscribers(mount, scope)
    emails = Enum.map(subs, & &1.email)
    assert Enum.any?(emails, &(&1 == Seeds.active_subscriber_email()))
    refute Enum.any?(emails, &match?(%Samen.Masked{}, &1))
  end

  # ==========================================================================
  # (d) add_subscriber (prospecting: CRM contact → subscriber) posture
  # ==========================================================================

  test "add_subscriber REFUSES a masked email (an operator must not enroll a tenant's contact)", %{org_id: org_id} do
    mount = build_mount(:marketing)
    scope = Mount.scope(mount, org_id)

    masked = Samen.Masked.new("vt_sometoken", :email)

    assert {:error, :masked_email_refused} =
             Reads.add_subscriber(mount, scope, %{email: masked, org_id: org_id})
  end

  test "add_subscriber creates a vault-routed subscriber from a clear (tenant) email", %{org_id: org_id} do
    mount = build_mount(:marketing)
    scope = Mount.scope(mount, org_id)

    assert {:ok, sub} =
             Reads.add_subscriber(mount, scope, %{email: "new.lead.plaintext@example.test", org_id: org_id})

    # The raw column holds a vault token, not plaintext.
    %{rows: [[email_col]]} =
      Samen.WebTest.Repo.query!("SELECT pii_wms_email FROM wms_subscriber WHERE wms_id = $1", [
        Ecto.UUID.dump!(sub.id)
      ])

    assert String.starts_with?(email_col, "vt_")
    refute email_col =~ "new.lead.plaintext@example.test"
  end
end
