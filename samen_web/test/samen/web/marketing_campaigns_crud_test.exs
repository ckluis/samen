defmodule Samen.Web.MarketingCampaignsCrudTest do
  @moduledoc """
  A3 WIRING (marketing batch) — `Samen.Web.Marketing.CampaignsLive` on the full kit
  contract (`ListLive` + `list_view` + `simple_form`/`modal`/`delete_confirm`).
  Campaign is non-PII (name / status / schedule); writes are ADMIN-gated by the kernel
  and go through the plane-preserving `Reads.write_scope/2` (the billing precedent):

    * **BOUNDED list end-to-end (read!-elimination, AC-G1-5)** — a 55-row org NEVER
      loads the full set through the retrofitted `Reads.campaigns_page/3`; keyset
      next/prev completes the walk; the per-row send count is an `Ash.count`
      aggregate that rides the same re-read. `bounded!/4` (RP-G1-5) green-lights
      `campaigns_page/3`; the anti-tautology pairing red-lights an unbounded stand-in.
    * **CRUD (AC-G1-1/2)** — "New campaign" is a REAL button opening the modal +
      `simple_form`; an INVALID submit (`name` required) renders inline errors and
      persists NOTHING; a VALID submit persists + refreshes the bounded list; each
      row carries the `delete_confirm/1` interlock and delete destroys through Ash
      (FAIL-HONEST: an FK-linked campaign surfaces the refusal).
    * **Plane posture (belt)** — write affordances are tenant-plane only
      (`Marketing.Live.writable?/1`): the operator render offers no New/Delete.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.ListLive
  alias Samen.Web.Marketing.CampaignsLive
  alias Samen.Web.Marketing.Reads, as: MktReads
  alias Samen.Web.Mount
  alias Samen.Web.Reads, as: WebReads
  alias Samen.Web.Reads.UnboundedReadError

  # -- harness (same shape as crm_companies_crud_test.exs) ----------------------

  defp mount_socket(org_id, plane_opts \\ []) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, build_mount(:marketing, plane_opts))
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> Phoenix.Component.assign(:return_to, nil)
    |> CampaignsLive.load(org_id)
  end

  defp html(socket), do: render_html(CampaignsLive, socket.assigns)

  defp event(socket, name, params) do
    {:noreply, socket} = CampaignsLive.handle_event(name, params, socket)
    socket
  end

  defp list_event(socket, name, params) do
    {:noreply, socket} = ListLive.handle_list_event(name, params, socket)
    socket
  end

  defp names(socket), do: Enum.map(socket.assigns.page.items, & &1.name)

  defp campaign_count(org_id) do
    Samen.WebTest.Marketing.Campaign
    |> Ash.Query.ensure_selected([:org_id])
    |> Ash.read!(authorize?: false)
    |> Enum.count(&(&1.org_id == org_id))
  end

  defp seed_campaigns(org_id, n) do
    for i <- 1..n//1 do
      Samen.WebTest.Marketing.Campaign
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          name: "Campaign #{String.pad_leading(to_string(i), 2, "0")}",
          description: "Outreach wave #{i}",
          status: :draft
        },
        authorize?: false
      )
      |> Ash.create!()
    end

    org_id
  end

  # ---------------------------------------------------------------------------
  # BOUNDED list end-to-end (pagination as a kit default on the real page)
  # ---------------------------------------------------------------------------

  test "a 55-row org NEVER loads the full set: page one is exactly default_page_size rows, keyset walks the rest" do
    org_id = seed_campaigns(Ash.UUID.generate(), 55)
    socket = mount_socket(org_id)

    assert length(socket.assigns.page.items) == WebReads.default_page_size()
    assert socket.assigns.page.has_more

    rendered = html(socket)
    refute rendered =~ "Campaign 51"

    socket = list_event(socket, "paginate", %{"dir" => "next"})
    assert names(socket) == Enum.map(51..55, &"Campaign #{&1}")
    refute socket.assigns.page.has_more

    socket = list_event(socket, "paginate", %{"dir" => "prev"})
    assert length(socket.assigns.page.items) == WebReads.default_page_size()
    assert hd(names(socket)) == "Campaign 01"
  end

  test "sort + filter are kit defaults on the real page; an empty org renders the kit empty_state" do
    org_id = seed_campaigns(Ash.UUID.generate(), 7)
    socket = mount_socket(org_id)

    assert socket.assigns.list_state.sort == {:name, :asc}
    socket = list_event(socket, "sort", %{"field" => "name"})
    assert hd(names(socket)) == "Campaign 07"

    socket = list_event(socket, "filter", %{"filter" => "campaign 03"})
    assert names(socket) == ["Campaign 03"]

    empty = mount_socket(Ash.UUID.generate())
    assert empty.assigns.page.items == []
    rendered = html(empty)
    assert rendered =~ "empty-state"
    assert rendered =~ "No campaigns yet."
  end

  test "the send-count column is an Ash.count aggregate attached by the reads fn (fresh on every re-read)" do
    %{org_id: org_id, marketing: mkt} = Seeds.seed_all()
    mount = build_mount(:marketing)
    scope = Mount.scope(mount, org_id)

    # Zero sends → count 0 on the page item.
    socket = mount_socket(org_id)
    seeded = Enum.find(socket.assigns.page.items, &(&1.name == Seeds.campaign_name()))
    assert Map.get(seeded, :send_count) == 0

    # Queue ONE real send through the ONLY send path (consent + suppression enforced)…
    assert {:ok, _send} =
             MktReads.enqueue_send(mount, scope, %{
               subscriber_id: mkt.active_subscriber.id,
               org_id: org_id,
               campaign_id: mkt.campaign.id,
               template_id: mkt.template.id
             })

    # …and the RE-READ page (the same read every list event runs) reflects it.
    socket = mount_socket(org_id)
    seeded = Enum.find(socket.assigns.page.items, &(&1.name == Seeds.campaign_name()))
    assert Map.get(seeded, :send_count) == 1
    assert html(socket) =~ "campaign-sends"
  end

  # ---------------------------------------------------------------------------
  # RP-G1-5 on the NEW reads fn — bounded! green + anti-tautology red
  # ---------------------------------------------------------------------------

  test "bounded! lint: campaigns_page/3 is bounded by construction; an unbounded stand-in RAISES" do
    org_id = seed_campaigns(Ash.UUID.generate(), 14)
    mount = build_mount(:marketing)
    scope = Mount.scope(mount, org_id)

    assert :ok = WebReads.bounded!(&MktReads.campaigns_page/3, mount, scope, page_size: 5)

    # Anti-tautology pairing: the SAME probe rejects an unbounded read (a raw Ash.read!
    # stuffing every row into the page) — the lint discriminates, it is not a no-op.
    unbounded = fn m, s, _state ->
      items = Samen.Web.Mount.resource(m, Campaign) |> Ash.read!(scope: s)
      %Samen.Web.Page{items: items, page_size: 5}
    end

    assert_raise UnboundedReadError, fn ->
      WebReads.bounded!(unbounded, mount, scope, page_size: 5)
    end
  end

  # ---------------------------------------------------------------------------
  # CRUD — create (green + red) and delete (AC-G1-1/2)
  # ---------------------------------------------------------------------------

  test "New campaign is a REAL button: opens the modal + simple_form; a VALID submit persists + refreshes" do
    org_id = Ash.UUID.generate()
    socket = mount_socket(org_id)

    rendered = html(socket)
    assert rendered =~ ~s(id="new-campaign")
    assert rendered =~ ~s(phx-click="new_campaign")

    socket = event(socket, "new_campaign", %{})
    rendered = html(socket)
    assert rendered =~ ~s(role="dialog")
    assert rendered =~ ~s(id="new-campaign-form")
    assert rendered =~ ~s(name="form[name]")

    socket =
      event(socket, "save_new", %{
        "form" => %{"name" => "Autumn lane-offer outreach", "description" => "Q4 wave"}
      })

    refute socket.assigns.show_new
    assert campaign_count(org_id) == 1
    rendered = html(socket)
    assert rendered =~ "Autumn lane-offer outreach"
    refute rendered =~ "empty-state"
  end

  test "RED PATH (AC-G1-2): an INVALID submit (blank required name) shows inline errors and persists NOTHING" do
    org_id = Ash.UUID.generate()
    socket = mount_socket(org_id) |> event("new_campaign", %{})

    socket = event(socket, "save_new", %{"form" => %{"name" => "", "description" => "half"}})

    # Modal stays open with the inline field error (AC-G1-2).
    assert socket.assigns.show_new
    rendered = html(socket)
    assert rendered =~ "field-invalid"
    assert rendered =~ "field-error"
    assert rendered =~ "is required"
    # Nothing persisted; the list is untouched.
    assert campaign_count(org_id) == 0
    assert socket.assigns.page.items == []
  end

  test "each row carries the delete_confirm interlock; delete destroys through Ash and refreshes" do
    org_id = Ash.UUID.generate()
    socket = mount_socket(org_id) |> event("new_campaign", %{})
    socket = event(socket, "save_new", %{"form" => %{"name" => "Doomed outreach"}})
    [campaign] = socket.assigns.page.items

    rendered = html(socket)
    assert rendered =~ ~s(data-confirm="Delete this record? This cannot be undone.")
    assert rendered =~ ~s(phx-click="delete")
    assert rendered =~ ~s(phx-value-id="#{campaign.id}")

    socket = event(socket, "delete", %{"id" => campaign.id})
    assert socket.assigns.page.items == []
    assert campaign_count(org_id) == 0
    assert html(socket) =~ "empty-state"
  end

  test "FAIL-HONEST delete: a campaign with linked sends is REFUSED (FK) and the refusal is surfaced" do
    %{org_id: org_id, marketing: mkt} = Seeds.seed_all()
    mount = build_mount(:marketing)
    scope = Mount.scope(mount, org_id)

    assert {:ok, _send} =
             MktReads.enqueue_send(mount, scope, %{
               subscriber_id: mkt.active_subscriber.id,
               org_id: org_id,
               campaign_id: mkt.campaign.id,
               template_id: mkt.template.id
             })

    before_count = campaign_count(org_id)
    socket = mount_socket(org_id)
    socket = event(socket, "delete", %{"id" => mkt.campaign.id})

    # The kernel defines no cascade — the send FK refuses the destroy; the campaign
    # survives and the error renders on the page (fail-honest, not fail-silent).
    assert campaign_count(org_id) == before_count
    assert socket.assigns.delete_error
    assert html(socket) =~ "Could not delete this campaign"
  end

  # ---------------------------------------------------------------------------
  # Plane posture — write affordances are tenant-plane only (belt)
  # ---------------------------------------------------------------------------

  test "OPERATOR plane: the list renders but offers NO write affordances (no New button, no delete)" do
    org_id = seed_campaigns(Ash.UUID.generate(), 3)
    socket = mount_socket(org_id, plane: :operator, target_org_id: org_id)

    rendered = html(socket)
    # Non-vacuous: the rows render for the operator (Campaign is non-PII)…
    assert rendered =~ "Campaign 01"
    # …but no write affordance is offered (kernel + guard enforce regardless).
    refute rendered =~ ~s(phx-click="new_campaign")
    refute rendered =~ ~s(phx-click="delete")
    refute rendered =~ "data-confirm"
  end
end
