defmodule Samen.Web.CRMCompaniesCrudTest do
  @moduledoc """
  A3 WIRING (crm batch) — `Samen.Web.CRM.CompaniesLive` on the full kit contract:

    * **BOUNDED list end-to-end (read!-elimination)** — a 55-row org NEVER loads the
      full set through the retrofitted `Reads.companies_page/3`; keyset next/prev
      completes the walk. `bounded!/4` (RP-G1-5) green-lights `companies_page/3` and
      the anti-tautology pairing red-lights an unbounded stand-in.
    * **CRUD (AC-G1-1/2)** — "New company" is a REAL button opening the modal +
      `simple_form`; an INVALID submit (`name` is required) renders inline errors and
      persists NOTHING; a VALID submit persists + refreshes the bounded list; each row
      carries the `delete_confirm/1` interlock and delete destroys through Ash.
    * **Plane posture** — Company is non-PII, but write AFFORDANCES are tenant-plane
      only (`writable?/1`): the operator render offers no New/Delete affordance.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.CRM.CompaniesLive
  alias Samen.Web.CRM.Reads, as: CrmReads
  alias Samen.Web.ListLive
  alias Samen.Web.Reads, as: WebReads
  alias Samen.Web.Reads.UnboundedReadError

  # -- harness (same shape as crm_contacts_list_test.exs) -----------------------

  defp mount_socket(org_id, plane_opts \\ []) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, build_mount(:crm, plane_opts))
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> Phoenix.Component.assign(:return_to, nil)
    |> CompaniesLive.load(org_id)
  end

  defp html(socket), do: render_html(CompaniesLive, socket.assigns)

  defp list_event(socket, name, params) do
    {:noreply, socket} = ListLive.handle_list_event(name, params, socket)
    socket
  end

  defp event(socket, name, params) do
    {:noreply, socket} = CompaniesLive.handle_event(name, params, socket)
    socket
  end

  defp names(socket), do: Enum.map(socket.assigns.page.items, & &1.name)

  defp company_count(org_id) do
    Samen.WebTest.Crm.Company
    |> Ash.Query.ensure_selected([:org_id])
    |> Ash.read!(authorize?: false)
    |> Enum.count(&(&1.org_id == org_id))
  end

  defp seed_org_with(n) do
    org_id = Ash.UUID.generate()

    for i <- 1..n do
      Samen.WebTest.Crm.Company
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          name: "Company #{String.pad_leading(to_string(i), 2, "0")}",
          industry: if(rem(i, 2) == 0, do: "Freight", else: "Veterinary")
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
    org_id = seed_org_with(55)
    socket = mount_socket(org_id)

    assert length(socket.assigns.page.items) == WebReads.default_page_size()
    assert socket.assigns.page.has_more

    rendered = html(socket)
    refute rendered =~ "Company 51"

    socket = list_event(socket, "paginate", %{"dir" => "next"})
    assert names(socket) == Enum.map(51..55, &"Company #{&1}")
    refute socket.assigns.page.has_more

    socket = list_event(socket, "paginate", %{"dir" => "prev"})
    assert length(socket.assigns.page.items) == WebReads.default_page_size()
    assert hd(names(socket)) == "Company 01"
  end

  test "sort + filter are kit defaults on the real page; an empty org renders the kit empty_state" do
    org_id = seed_org_with(7)
    socket = mount_socket(org_id)

    assert socket.assigns.list_state.sort == {:name, :asc}
    socket = list_event(socket, "sort", %{"field" => "name"})
    assert hd(names(socket)) == "Company 07"

    socket = list_event(socket, "filter", %{"filter" => "company 03"})
    assert names(socket) == ["Company 03"]

    empty = mount_socket(Ash.UUID.generate())
    assert empty.assigns.page.items == []
    rendered = html(empty)
    assert rendered =~ "empty-state"
    assert rendered =~ "No companies yet."
  end

  # ---------------------------------------------------------------------------
  # RP-G1-5 on the NEW reads fn — bounded! green + anti-tautology red
  # ---------------------------------------------------------------------------

  test "bounded! lint: companies_page/3 is bounded by construction; an unbounded stand-in RAISES" do
    org_id = seed_org_with(14)
    mount = build_mount(:crm)
    scope = Samen.Web.Mount.scope(mount, org_id)

    assert :ok = WebReads.bounded!(&CrmReads.companies_page/3, mount, scope, page_size: 5)

    # Anti-tautology pairing: the SAME probe rejects an unbounded read (a raw Ash.read!
    # stuffing every row into the page) — the lint discriminates, it is not a no-op.
    unbounded = fn m, s, _state ->
      items = Samen.Web.Mount.resource(m, Company) |> Ash.read!(scope: s)
      %Samen.Web.Page{items: items, page_size: 5}
    end

    assert_raise UnboundedReadError, fn ->
      WebReads.bounded!(unbounded, mount, scope, page_size: 5)
    end
  end

  # ---------------------------------------------------------------------------
  # CRUD — create (green + red) and delete (AC-G1-1/2)
  # ---------------------------------------------------------------------------

  test "New company is a REAL button: opens the modal + simple_form; a VALID submit persists + refreshes" do
    org_id = Ash.UUID.generate()
    socket = mount_socket(org_id)

    rendered = html(socket)
    assert rendered =~ ~s(id="new-company")
    assert rendered =~ ~s(phx-click="new_company")

    socket = event(socket, "new_company", %{})
    rendered = html(socket)
    assert rendered =~ ~s(role="dialog")
    assert rendered =~ ~s(id="new-company-form")
    assert rendered =~ ~s(name="form[name]")

    socket =
      event(socket, "save_new", %{
        "form" => %{"name" => "Bluebird Freight Co", "industry" => "Freight"}
      })

    refute socket.assigns.show_new
    assert company_count(org_id) == 1
    rendered = html(socket)
    assert rendered =~ "Bluebird Freight Co"
    refute rendered =~ "empty-state"
  end

  test "RED PATH (AC-G1-2): an INVALID submit (blank required name) shows inline errors and persists NOTHING" do
    org_id = Ash.UUID.generate()
    socket = mount_socket(org_id) |> event("new_company", %{})

    socket = event(socket, "save_new", %{"form" => %{"name" => "", "industry" => "Freight"}})

    # Modal stays open with the inline field error (AC-G1-2).
    assert socket.assigns.show_new
    rendered = html(socket)
    assert rendered =~ "field-invalid"
    assert rendered =~ "field-error"
    assert rendered =~ "is required"
    # Nothing persisted; the list is untouched.
    assert company_count(org_id) == 0
    assert socket.assigns.page.items == []
  end

  test "each row carries the delete_confirm interlock; delete destroys through Ash and refreshes" do
    org_id = Ash.UUID.generate()
    socket = mount_socket(org_id) |> event("new_company", %{})
    socket = event(socket, "save_new", %{"form" => %{"name" => "Doomed Freight Co"}})
    [company] = socket.assigns.page.items

    rendered = html(socket)
    assert rendered =~ ~s(data-confirm="Delete this record? This cannot be undone.")
    assert rendered =~ ~s(phx-click="delete")
    assert rendered =~ ~s(phx-value-id="#{company.id}")

    socket = event(socket, "delete", %{"id" => company.id})
    assert socket.assigns.page.items == []
    assert company_count(org_id) == 0
    assert html(socket) =~ "empty-state"
  end

  # ---------------------------------------------------------------------------
  # Plane posture — write affordances are tenant-plane only
  # ---------------------------------------------------------------------------

  test "OPERATOR plane: the list renders but offers NO write affordances (no New button, no delete)" do
    org_id = seed_org_with(3)
    socket = mount_socket(org_id, plane: :operator, target_org_id: org_id)

    rendered = html(socket)
    # Non-vacuous: the rows render for the operator (Company is non-PII)…
    assert rendered =~ "Company 01"
    # …but no write affordance is offered (kernel + guard enforce regardless).
    refute rendered =~ ~s(phx-click="new_company")
    refute rendered =~ ~s(phx-click="delete")
    refute rendered =~ "data-confirm"
  end
end
