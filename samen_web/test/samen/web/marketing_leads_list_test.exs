defmodule Samen.Web.MarketingLeadsListTest do
  @moduledoc """
  A3 WIRING (crm batch) — `Samen.Web.Marketing.LeadsLive` retrofitted onto the kit
  contract (`ListLive` + `list_view/1` + the BOUNDED `Reads.leads_page/3`):

    * **BOUNDED lens end-to-end (read!-elimination)** — a 55-lead org NEVER loads the
      full set; keyset next completes the walk; the LIFECYCLE FILTER is server-side
      (a non-lead contact never appears on ANY page — the lens is complete AND
      bounded, which an Elixir post-filter over a limited read could not be).
    * **RP-G1-5** — `bounded!/4` green-lights `leads_page/3`; the anti-tautology
      pairing red-lights an unbounded stand-in.
    * **PER-PLANE MASKING on the lens** — tenant reads the lead's name/email CLEAR;
      the operator plane renders the SAME rows `••••` with plaintext + token absent
      (the leads read rides the SAME PiiResolution chokepoint as the CRM pages).
    * **Read-only by design** — the lens offers no write affordance: the domain
      defines no lead-specific write action (leads ARE CRM people).
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.ListLive
  alias Samen.Web.Marketing.LeadsLive
  alias Samen.Web.Mount
  alias Samen.Web.CRM.Reads, as: CrmReads
  alias Samen.Web.Reads, as: WebReads
  alias Samen.Web.Reads.UnboundedReadError

  # -- harness -------------------------------------------------------------------

  defp mount_socket(org_id, plane_opts \\ []) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, build_mount(:marketing, plane_opts))
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> Phoenix.Component.assign(:return_to, nil)
    |> LeadsLive.load(org_id)
  end

  defp html(socket), do: render_html(LeadsLive, socket.assigns)

  defp list_event(socket, name, params) do
    {:noreply, socket} = ListLive.handle_list_event(name, params, socket)
    socket
  end

  defp names(socket), do: Enum.map(socket.assigns.page.items, & &1.display_name)

  # Seed `leads` early-funnel people + `others` non-lead people in one org. The Tier-1
  # custom field must be registered before a custom value writes (the tnt_field rule).
  defp seed_org(leads, others) do
    org_id = Ash.UUID.generate()

    {:ok, _} =
      Samen.CustomFields.define_field(
        %{org_id: org_id, table_name: "swp_person", field_name: "lifecycle_stage", type: :string},
        Samen.WebTest.Repo
      )

    # `1..n//1` — an empty range when n = 0 (a bare `1..0` steps DOWN and would seed
    # two phantom rows, silently un-emptying the "empty funnel" fixture).
    for i <- 1..leads//1 do
      seed_person(org_id, "Lead #{String.pad_leading(to_string(i), 2, "0")}", "lead")
    end

    for i <- 1..others//1 do
      seed_person(org_id, "NotLead #{String.pad_leading(to_string(i), 2, "0")}", "customer")
    end

    org_id
  end

  defp seed_person(org_id, display_name, stage) do
    Samen.WebTest.Crm.Person
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org_id,
        display_name: display_name,
        job_title: "Broker",
        custom: %{"lifecycle_stage" => stage}
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  defp crm_mount, do: build_mount(:crm)

  # ---------------------------------------------------------------------------
  # BOUNDED + COMPLETE lens end-to-end
  # ---------------------------------------------------------------------------

  test "a 55-lead org NEVER loads the full set; the lifecycle filter is server-side (no NotLead on ANY page)" do
    org_id = seed_org(55, 5)
    socket = mount_socket(org_id)

    assert length(socket.assigns.page.items) == WebReads.default_page_size()
    assert socket.assigns.page.has_more
    refute html(socket) =~ "Lead 51"

    # Keyset next completes the walk — exactly the 5 remaining LEADS, never a NotLead.
    socket = list_event(socket, "paginate", %{"dir" => "next"})
    assert names(socket) == Enum.map(51..55, &"Lead #{&1}")
    refute socket.assigns.page.has_more
    refute Enum.any?(names(socket), &String.starts_with?(&1, "NotLead"))
  end

  test "filter narrows the lens server-side; an empty funnel renders the kit empty_state" do
    org_id = seed_org(7, 2)
    socket = mount_socket(org_id)

    socket = list_event(socket, "filter", %{"filter" => "lead 03"})
    assert names(socket) == ["Lead 03"]

    empty = mount_socket(seed_org(0, 3))
    assert empty.assigns.page.items == []
    rendered = html(empty)
    assert rendered =~ "empty-state"
    assert rendered =~ "No leads in the early funnel yet."
  end

  test "read-only by design: the lens offers no write affordance" do
    org_id = seed_org(2, 0)
    rendered = html(mount_socket(org_id))
    # Non-vacuous: the lens DOES render rows + the kit's read-only filter bar…
    assert rendered =~ "lead-row"
    assert rendered =~ ~s(phx-submit="filter")
    # …but no write affordance: no delete interlock, no create/edit modal or form,
    # no "New …" trigger. (The filter bar's phx-submit is a READ, not a write.)
    refute rendered =~ "data-confirm"
    refute rendered =~ ~s(role="dialog")
    refute rendered =~ ~s(phx-click="new_)
    refute rendered =~ ~s(phx-submit="save)
    refute rendered =~ ~s(phx-submit="log_)
  end

  # ---------------------------------------------------------------------------
  # RP-G1-5 on the NEW reads fn
  # ---------------------------------------------------------------------------

  test "bounded! lint: leads_page/3 is bounded by construction; an unbounded stand-in RAISES" do
    org_id = seed_org(14, 0)
    crm = crm_mount()
    scope = Mount.scope(crm, org_id)

    assert :ok = WebReads.bounded!(&CrmReads.leads_page/3, crm, scope, page_size: 5)

    # Anti-tautology pairing: the OLD unbounded lens shape (read-then-Elixir-filter,
    # wrapped in a %Page{}) is exactly what the lint must reject.
    unbounded = fn m, s, _state ->
      %Samen.Web.Page{items: CrmReads.leads(m, s), page_size: 5}
    end

    assert_raise UnboundedReadError, fn ->
      WebReads.bounded!(unbounded, crm, scope, page_size: 5)
    end
  end

  # ---------------------------------------------------------------------------
  # PER-PLANE MASKING on the lens (the PII read surface)
  # ---------------------------------------------------------------------------

  test "TENANT: the seeded lead renders name + email CLEAR (non-vacuous masking control)" do
    %{org_id: org_id} = Seeds.seed_all()
    rendered = html(mount_socket(org_id))

    assert rendered =~ "lead-row"
    assert rendered =~ Seeds.contact_full_name()
    assert rendered =~ Seeds.contact_email()
  end

  test "OPERATOR: the SAME lens masks name + email •••• — plaintext and vault token absent" do
    %{org_id: org_id} = Seeds.seed_all()
    rendered = html(mount_socket(org_id, plane: :operator, target_org_id: org_id))

    # Non-vacuous: the same seeded lead row renders…
    assert rendered =~ "lead-row"
    # …masked.
    assert rendered =~ "••••"
    refute rendered =~ Seeds.contact_full_name()
    refute rendered =~ Seeds.contact_email()
    refute rendered =~ Seeds.contact_phone()
    refute rendered =~ "vt_"
  end
end
