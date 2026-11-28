defmodule Samen.Web.TenantRoleMarketingTest do
  @moduledoc """
  ADR-045 §4.4 residual (the `:member` default), Marketing: the campaigns list, the campaign page (compose and send) and
  the segments page act with the role the signed-in person's ACTIVE membership resolves to (`Samen.Web.TenantActor`),
  never `Plane.scope/2`'s fixed `:member`.

  Driven with a REAL spine login (`POST /login`) and the REAL tenant gate (`Samen.WebTest.RoleHarness`); every refusal is
  paired with a positive control.

  Policy (the blueprint): reads are not role-gated. `Campaign` and `Segment` writes are `RoleAtLeast :admin`. `Send`
  (the campaign page's "Send to segment") only checks the org in the kernel, so the PAGE requires an admin to send, the
  rank of every other campaign write (consent and suppression stay enforced by `Reads.enqueue_send/3`).
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Marketing.{CampaignLive, CampaignsLive, SegmentsLive}
  alias Samen.WebTest.RoleHarness, as: H
  alias Samen.WebTest.SpineAccounts

  setup do
    H.setup_accounts()
  end

  defp html(view, socket), do: render_html(view, socket.assigns)

  # -- seeds (system context) ---------------------------------------------------------------------------------

  defp campaign!(org_id, name) do
    Samen.WebTest.Marketing.Campaign
    |> Ash.Changeset.for_create(:create, %{org_id: org_id, name: name, description: "wave", status: :draft}, authorize?: false)
    |> Ash.create!()
  end

  defp segment!(org_id, name) do
    Samen.WebTest.Marketing.Segment
    |> Ash.Changeset.for_create(:create, %{org_id: org_id, name: name, description: "all", filter_criteria: %{"status" => "active"}, subscriber_count: 1}, authorize?: false)
    |> Ash.create!()
  end

  defp template!(org_id) do
    Samen.WebTest.Marketing.Template
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org_id, name: "welcome", subject_line: "Welcome aboard", body_html: "<p>Welcome</p>", from_name: "Northwind", from_address: "hello@northwind.example", enabled: true},
      authorize?: false
    )
    |> Ash.create!()
  end

  defp subscriber!(org_id, email) do
    Samen.WebTest.Marketing.Subscriber
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org_id, email: email, status: :active, consent_at: DateTime.utc_now() |> DateTime.truncate(:second), source: "crm"},
      authorize?: false
    )
    |> Ash.create!()
  end

  defp rows(resource, org_id, select) do
    resource |> Ash.Query.ensure_selected([:org_id | select]) |> Ash.read!(authorize?: false) |> Enum.filter(&(&1.org_id == org_id))
  end

  defp campaigns(org_id), do: rows(Samen.WebTest.Marketing.Campaign, org_id, [:name])
  defp segments(org_id), do: rows(Samen.WebTest.Marketing.Segment, org_id, [:name])
  defp sends(org_id), do: rows(Samen.WebTest.Marketing.Send, org_id, [:campaign_id])

  defp pages(org_id) do
    campaign = campaign!(org_id, "Zebra Campaign")
    segment!(org_id, "Zebra Segment")
    template!(org_id)
    subscriber!(org_id, "probe.subscriber@example.test")

    [
      %{name: "CampaignsLive", view: CampaignsLive, path: "/marketing/campaigns", extra: %{}, events: [{"new_campaign", %{}}, {"delete", %{"id" => campaign.id}}]},
      %{name: "CampaignLive", view: CampaignLive, path: "/marketing/campaigns/:id", extra: %{"id" => campaign.id}, events: [{"send_campaign", %{"send" => %{"template_id" => "x", "segment_id" => "y"}}}, {"retry_load", %{}}]},
      %{name: "SegmentsLive", view: SegmentsLive, path: "/marketing/segments", extra: %{}, events: [{"new_segment", %{}}, {"retry_load", %{}}]}
    ]
  end

  # -- every page acts as the RESOLVED role --------------------------------------------------------------------

  test "every Marketing page acts with the RESOLVED role, not :member", ctx do
    logins = for who <- [:viewer, :member, :admin, :owner], into: %{}, do: {who, H.log_in(Map.fetch!(ctx, who))}

    for page <- pages(ctx.org_id), role <- [:viewer, :member, :admin, :owner] do
      socket = H.live_socket(Map.fetch!(logins, role), page.view, page.path, ctx.org_id, page.extra)
      assert socket.assigns.actor_state == :ok, page.name
      assert socket.assigns.acting_scope.actor.role == role, "#{page.name} acted as #{socket.assigns.acting_scope.actor.role}, not #{role}"
      assert socket.assigns.acting_scope.actor.resolved == true
      refute String.starts_with?(socket.assigns.acting_scope.actor.id, "broker:")
    end
  end

  test "NAVIGATION: a suspended member's page is the denied state: nothing is read, no event reads or writes", ctx do
    pages = pages(ctx.org_id)
    login = H.log_in(ctx.member)
    sockets = for page <- pages, do: {page, H.live_socket(login, page.view, page.path, ctx.org_id, page.extra)}

    for {page, socket} <- sockets do
      assert html(page.view, socket) =~ "Zebra", "#{page.name}: nothing to read while acting (vacuous control)"
    end

    before = {length(campaigns(ctx.org_id)), length(segments(ctx.org_id)), length(sends(ctx.org_id))}
    SpineAccounts.suspend!(ctx.member, ctx.org_id)

    for {page, socket} <- sockets do
      refused = H.params(page.view, socket, page.extra)
      assert refused.assigns.actor_state == :denied, page.name
      assert refused.assigns.acting_scope == nil, page.name
      out = html(page.view, refused)
      assert out =~ ~s(id="actor-denied"), page.name
      refute out =~ "Zebra", page.name

      for {name, p} <- page.events do
        assert H.event(page.view, name, p, refused).assigns == refused.assigns, "#{page.name} #{name} changed the refused page"
      end
    end

    assert before == {length(campaigns(ctx.org_id)), length(segments(ctx.org_id)), length(sends(ctx.org_id))}
  end

  test "a failed membership lookup is the UNAVAILABLE state on every Marketing page, never an empty page", ctx do
    login = H.log_in(ctx.member)

    for page <- pages(ctx.org_id) do
      socket = H.live_socket(login, page.view, page.path, ctx.org_id, page.extra) |> H.break_identity()
      {refused, _log} = ExUnit.CaptureLog.with_log(fn -> H.params(page.view, socket, page.extra) end)
      assert refused.assigns.actor_state == :unavailable, page.name
      assert refused.assigns.acting_scope == nil
      out = html(page.view, refused)
      assert out =~ ~s(id="actor-unavailable"), page.name
      refute out =~ "Zebra"
    end
  end

  test "OPEN PAGE: an admin demoted or suspended while Segments and the campaign are open writes and sends nothing at the next event", ctx do
    keep = segment!(ctx.org_id, "Keep Segment")
    lose = segment!(ctx.org_id, "Lose Segment")
    login = H.log_in(ctx.admin)

    open = H.open_socket(login, SegmentsLive, "/marketing/segments", ctx.org_id)
    assert open.assigns.can_admin
    # positive control: the same event as an admin
    H.live_event(SegmentsLive, "delete", %{"id" => lose.id}, open)
    refute Enum.any?(segments(ctx.org_id), &(&1.id == lose.id))

    campaign = campaign!(ctx.org_id, "Open Campaign")
    template = template!(ctx.org_id)
    segment = segment!(ctx.org_id, "Audience")
    subscriber!(ctx.org_id, "audience@example.test")
    campaign_open = H.open_socket(login, CampaignLive, "/marketing/campaigns/:id", ctx.org_id, %{"id" => campaign.id})
    send_params = %{"send" => %{"template_id" => template.id, "segment_id" => segment.id}}

    SpineAccounts.set_role!(ctx.admin, ctx.org_id, :member)
    demoted = H.live_event(SegmentsLive, "delete", %{"id" => keep.id}, open)
    assert demoted.assigns.acting_scope.actor.role == :member
    refute demoted.assigns.can_admin
    assert demoted.assigns.delete_error
    assert Enum.any?(segments(ctx.org_id), &(&1.id == keep.id))

    sent = H.live_event(CampaignLive, "send_campaign", send_params, campaign_open)
    assert sent.assigns.notice == "Only an admin can send a campaign."
    assert sends(ctx.org_id) == []

    SpineAccounts.suspend!(ctx.admin, ctx.org_id)
    gone = H.live_event(SegmentsLive, "delete", %{"id" => keep.id}, demoted)
    assert gone.assigns.actor_state == :denied
    assert Enum.any?(segments(ctx.org_id), &(&1.id == keep.id))
    gone = H.live_event(CampaignLive, "send_campaign", send_params, sent)
    assert gone.assigns.actor_state == :denied
    assert sends(ctx.org_id) == []
  end

  # -- writes -------------------------------------------------------------------------------------------------

  describe "CampaignsLive writes (admin)" do
    test "a VIEWER and a MEMBER cannot create or delete a campaign; an admin can", ctx do
      target = campaign!(ctx.org_id, "Existing Campaign")
      before = length(campaigns(ctx.org_id))
      path = "/marketing/campaigns"

      create = fn account, name ->
        socket = H.live_socket(H.log_in(account), CampaignsLive, path, ctx.org_id)
        socket = H.event(CampaignsLive, "new_campaign", %{}, socket)
        H.event(CampaignsLive, "save_new", %{"form" => %{"name" => name, "description" => "d", "status" => "draft"}}, socket)
      end

      for account <- [ctx.viewer, ctx.member] do
        create.(account, "Denied Campaign")
        assert length(campaigns(ctx.org_id)) == before
        socket = H.live_socket(H.log_in(account), CampaignsLive, path, ctx.org_id)
        socket = H.event(CampaignsLive, "delete", %{"id" => target.id}, socket)
        assert socket.assigns.delete_error == "Could not delete this campaign."
        assert length(campaigns(ctx.org_id)) == before
      end

      create.(ctx.admin, "Admin Campaign")
      assert length(campaigns(ctx.org_id)) == before + 1
      admin = H.live_socket(H.log_in(ctx.admin), CampaignsLive, path, ctx.org_id)
      H.event(CampaignsLive, "delete", %{"id" => target.id}, admin)
      refute Enum.any?(campaigns(ctx.org_id), &(&1.id == target.id))
    end
  end

  describe "SegmentsLive writes (admin)" do
    test "a VIEWER and a MEMBER cannot create or delete a segment; an admin can", ctx do
      target = segment!(ctx.org_id, "Existing Segment")
      before = length(segments(ctx.org_id))
      path = "/marketing/segments"

      create = fn account, name ->
        socket = H.live_socket(H.log_in(account), SegmentsLive, path, ctx.org_id)
        socket = H.event(SegmentsLive, "new_segment", %{}, socket)
        H.event(SegmentsLive, "save_new", %{"form" => %{"name" => name, "description" => "d"}}, socket)
      end

      for account <- [ctx.viewer, ctx.member] do
        create.(account, "Denied Segment")
        assert length(segments(ctx.org_id)) == before
        socket = H.live_socket(H.log_in(account), SegmentsLive, path, ctx.org_id)
        socket = H.event(SegmentsLive, "delete", %{"id" => target.id}, socket)
        assert socket.assigns.delete_error
        assert length(segments(ctx.org_id)) == before
      end

      create.(ctx.admin, "Admin Segment")
      assert length(segments(ctx.org_id)) == before + 1
      admin = H.live_socket(H.log_in(ctx.admin), SegmentsLive, path, ctx.org_id)
      H.event(SegmentsLive, "delete", %{"id" => target.id}, admin)
      refute Enum.any?(segments(ctx.org_id), &(&1.id == target.id))
    end
  end

  describe "CampaignLive: sending is admin's" do
    test "a VIEWER and a MEMBER cannot send a campaign to a segment; an admin and an owner can", ctx do
      campaign = campaign!(ctx.org_id, "Send Campaign")
      template = template!(ctx.org_id)
      segment = segment!(ctx.org_id, "Audience")
      subscriber!(ctx.org_id, "audience@example.test")
      path = "/marketing/campaigns/:id"
      params = %{"send" => %{"template_id" => template.id, "segment_id" => segment.id}}
      open = fn account -> H.live_socket(H.log_in(account), CampaignLive, path, ctx.org_id, %{"id" => campaign.id}) end

      for account <- [ctx.viewer, ctx.member] do
        socket = open.(account)
        refute html(CampaignLive, socket) =~ ~s(id="send-campaign-form")
        socket = H.event(CampaignLive, "send_campaign", params, socket)
        assert socket.assigns.notice == "Only an admin can send a campaign."
        assert sends(ctx.org_id) == []
      end

      admin = open.(ctx.admin)
      assert html(CampaignLive, admin) =~ ~s(id="send-campaign-form")
      admin = H.event(CampaignLive, "send_campaign", params, admin)
      assert admin.assigns.notice =~ "Enqueued 1 send(s)"
      assert length(sends(ctx.org_id)) == 1
    end
  end

  describe "write controls follow the acting role" do
    test "campaign and segment controls are an admin's", ctx do
      campaign!(ctx.org_id, "Controls Campaign")
      segment!(ctx.org_id, "Controls Segment")
      logins = %{viewer: H.log_in(ctx.viewer), member: H.log_in(ctx.member), admin: H.log_in(ctx.admin)}

      pages = [
        {CampaignsLive, "/marketing/campaigns", ["new-campaign", ~s(phx-click="delete")]},
        {SegmentsLive, "/marketing/segments", ["new-segment", ~s(phx-click="delete")]}
      ]

      for {view, path, controls} <- pages do
        render = fn who -> html(view, H.live_socket(logins[who], view, path, ctx.org_id)) end
        {viewer, member, admin} = {render.(:viewer), render.(:member), render.(:admin)}

        for control <- controls do
          assert admin =~ control, "#{inspect(view)}: the admin's page has no #{control} (vacuous)"
          refute member =~ control, "#{inspect(view)}: the member's page offers #{control}"
          refute viewer =~ control, "#{inspect(view)}: the viewer's page offers #{control}"
        end
      end
    end
  end
end
