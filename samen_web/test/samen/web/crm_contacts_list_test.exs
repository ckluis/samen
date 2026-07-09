defmodule Samen.Web.CRMContactsListTest do
  @moduledoc """
  A2 Task 3 — the CONTRACT SMOKE PROOF on a REAL framework surface:
  `Samen.Web.CRM.ContactsLive` (mounted by BOTH verticals via
  `Samen.Web.Router.samen_crm`) retrofitted onto `use Samen.Web.ListLive` +
  `list_view/1` + the default `empty_state/1`. Proves, against real DB rows:

    * **BOUNDED read end-to-end** — a 55-row org NEVER loads the full set on the real
      page: exactly `default_page_size` (50) rows on page one, keyset "next" completes
      the walk. (Anti-tautology pairing: sabotaging `contacts_page/3` back to the old
      unbounded `contacts/2` read makes this FAIL.)
    * sort toggle + RED PATH: an undeclared client sort field is REFUSED (no atom
      minting, state unchanged) on the real page.
    * filter narrows server-side and resets paging.
    * zero rows render the kit-default `empty_state/1` (the AC-G5-1 component path)
      instead of a table.

  Per-plane masking on this page (tenant clear / operator ••••) is asserted in
  `crm_render_test.exs`, which now exercises the SAME `list_view` render path.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.ListLive
  alias Samen.Web.CRM.ContactsLive
  alias Samen.Web.Reads, as: WebReads

  # -- harness (same shape as list_live_test.exs) ------------------------------

  defp mount_socket(mount, org_id) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, mount)
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> Phoenix.Component.assign(:return_to, nil)
    |> ContactsLive.load(org_id)
  end

  defp html(socket), do: render_html(ContactsLive, socket.assigns)

  defp event(socket, name, params) do
    {:noreply, socket} = ListLive.handle_list_event(name, params, socket)
    socket
  end

  defp names(socket), do: Enum.map(socket.assigns.page.items, & &1.display_name)

  defp count(html, needle), do: html |> String.split(needle) |> length() |> Kernel.-(1)

  defp seed_org_with(n) do
    org_id = Ash.UUID.generate()

    for i <- 1..n do
      Samen.WebTest.Crm.Person
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          display_name: "Contact #{String.pad_leading(to_string(i), 2, "0")}",
          job_title: if(rem(i, 2) == 0, do: "Dispatcher", else: "Broker")
        },
        authorize?: false
      )
      |> Ash.create!()
    end

    org_id
  end

  # ---------------------------------------------------------------------------
  # BOUNDED read end-to-end on the REAL page (read!-elimination smoke proof)
  # ---------------------------------------------------------------------------

  test "a 55-row org NEVER loads the full set: page one is exactly default_page_size rows" do
    org_id = seed_org_with(55)
    socket = mount_socket(build_mount(:crm), org_id)

    assert length(socket.assigns.page.items) == WebReads.default_page_size()
    assert socket.assigns.page.has_more

    rendered = html(socket)
    assert count(rendered, ~s(contact-row)) == WebReads.default_page_size()
    refute rendered =~ "Contact 51"

    # Keyset "next" completes the walk with the remaining 5 rows.
    socket = event(socket, "paginate", %{"dir" => "next"})
    assert names(socket) == Enum.map(51..55, &"Contact #{&1}")
    refute socket.assigns.page.has_more

    # "prev" pops back to a full first page.
    socket = event(socket, "paginate", %{"dir" => "prev"})
    assert length(socket.assigns.page.items) == WebReads.default_page_size()
    assert hd(names(socket)) == "Contact 01"
  end

  # ---------------------------------------------------------------------------
  # Sort — kit default on the real page, with the bounded-field red path
  # ---------------------------------------------------------------------------

  test "sort toggles asc↔desc on the real page; RED PATH: an undeclared field is REFUSED" do
    org_id = seed_org_with(7)
    socket = mount_socket(build_mount(:crm), org_id)

    assert socket.assigns.list_state.sort == {:display_name, :asc}
    assert hd(names(socket)) == "Contact 01"
    assert html(socket) =~ ~s(aria-sort="ascending")

    socket = event(socket, "sort", %{"field" => "display_name"})
    assert socket.assigns.list_state.sort == {:display_name, :desc}
    assert hd(names(socket)) == "Contact 07"

    socket = event(socket, "sort", %{"field" => "job_title"})
    assert socket.assigns.list_state.sort == {:job_title, :asc}

    # RED PATH: `org_id` is a real column but NOT declared sortable; the injection
    # string is not even an existing atom — both leave the state untouched.
    before_state = socket.assigns.list_state
    socket = event(socket, "sort", %{"field" => "org_id"})
    assert socket.assigns.list_state == before_state
    socket = event(socket, "sort", %{"field" => "nope_#{System.unique_integer([:positive])}"})
    assert socket.assigns.list_state == before_state
  end

  # ---------------------------------------------------------------------------
  # Filter — server-side, still bounded, resets paging
  # ---------------------------------------------------------------------------

  test "filter narrows the read server-side and resets the cursor" do
    org_id = seed_org_with(55)
    socket = mount_socket(build_mount(:crm), org_id)
    socket = event(socket, "paginate", %{"dir" => "next"})

    socket = event(socket, "filter", %{"filter" => "CONTACT 07", "_target" => ["filter"]})
    assert names(socket) == ["Contact 07"]
    refute socket.assigns.page.has_more
    assert socket.assigns.list_state.cursor == nil

    socket = event(socket, "filter", %{"filter" => ""})
    assert length(socket.assigns.page.items) == WebReads.default_page_size()
  end

  # ---------------------------------------------------------------------------
  # Empty state — the kit DEFAULT empty_state renders at zero rows (AC-G5-1 path)
  # ---------------------------------------------------------------------------

  test "an empty org renders the kit-default empty_state, not a table" do
    org_id = Ash.UUID.generate()
    socket = mount_socket(build_mount(:crm), org_id)

    assert socket.assigns.page.items == []
    rendered = html(socket)
    assert rendered =~ "empty-state"
    assert rendered =~ "No contacts yet."
    refute rendered =~ "<table>"
  end
end
