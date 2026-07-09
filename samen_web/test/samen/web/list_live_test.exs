defmodule Samen.Web.ListLiveTest do
  @moduledoc """
  A2 mixin tests (ADR-016 §2/§3) on the fixture LiveView
  (`Samen.WebTest.ListFixture.ContactsLive` — `use Samen.Web.ListLive` + `list_view/1`,
  zero list-ergonomics lines of its own). Proves, against real DB rows:

    * **BOUNDED reads** (the `read!`-elimination guarantee): a dataset exceeding the
      page size NEVER loads the full set — the built query always carries
      `limit(page_size + 1)`, and a hostile `page_size` is CAPPED, not honored
      (RP-Page-1 analog).
    * **KEYSET pagination** — the full walk visits every row exactly once and is
      STABLE UNDER CONCURRENT INSERTS (a row inserted before the cursor cannot
      shift/duplicate rows onto the next page — the offset failure mode).
    * sort toggle (asc↔desc) + the BOUNDED sortable-field rule (client input never
      names an undeclared field, never mints an atom).
    * filter narrows the read server-side (still bounded).
    * select / select_all / bulk over the selection set.
    * the `:handle_event` hook wiring (halts owned events, `:cont`s the rest,
      attach is idempotent).
    * **THE PER-PLANE MASKING GUARANTEE on the table primitive** — the SAME fixture
      renders the seeded contact's PII CLEAR on the tenant plane and `••••` (plaintext
      + vault token ABSENT) on the operator plane.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.ListLive
  alias Samen.Web.ListState
  alias Samen.WebTest.ListFixture.ContactsLive

  # ---------------------------------------------------------------------------
  # Harness
  # ---------------------------------------------------------------------------

  defp mount_socket(mount, org_id) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, mount)
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> ContactsLive.load(org_id)
  end

  defp html(socket), do: render_html(ContactsLive, socket.assigns)

  defp event(socket, name, params) do
    {:noreply, socket} = ListLive.handle_list_event(name, params, socket)
    socket
  end

  defp names(socket) do
    Enum.map(socket.assigns.page.items, & &1.display_name)
  end

  defp ids(socket), do: Enum.map(socket.assigns.page.items, & &1.id)

  defp count(html, needle), do: html |> String.split(needle) |> length() |> Kernel.-(1)

  # Seed `n` contacts "Contact 01".."Contact NN" in one fresh org (no sentinel row).
  defp seed_org_with(n) do
    org_id = Ash.UUID.generate()

    people =
      for i <- 1..n do
        create_person(org_id, "Contact #{String.pad_leading(to_string(i), 2, "0")}", job(i))
      end

    {org_id, people}
  end

  defp job(i) when rem(i, 2) == 0, do: "Dispatcher"
  defp job(_i), do: "Broker"

  defp create_person(org_id, display_name, job_title) do
    [first, last] = String.split(display_name, " ", parts: 2)

    Samen.WebTest.Crm.Person
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org_id,
        display_name: display_name,
        job_title: job_title,
        full_name: %Samen.Type.FullName{first: first, last: last},
        emails: [%{label: "work", address: "#{String.downcase(last)}@example.test"}],
        phones: [%{label: "mobile", number: "+1-555-0100"}]
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  # ---------------------------------------------------------------------------
  # BOUNDED reads (the red-path guarantee: never load the full set)
  # ---------------------------------------------------------------------------

  test "RED PATH pairing: a 12-row org on page_size 5 NEVER loads the full set" do
    {org_id, _} = seed_org_with(12)
    socket = mount_socket(build_mount(:crm), org_id)

    assert length(socket.assigns.page.items) == 5
    assert socket.assigns.page.has_more

    rendered = html(socket)
    assert count(rendered, ~s(class="list-row")) == 5
    refute rendered =~ "Contact 06"
  end

  test "Samen.Web.Reads.build/3 ALWAYS carries limit page_size + 1 (the bound itself)" do
    query = Ash.Query.new(Samen.WebTest.Crm.Person)

    bounded = Samen.Web.Reads.build(query, %ListState{page_size: 5, sort: {:display_name, :asc}})
    assert bounded.limit == 6

    # RP-Page-1 analog: a hostile page_size is CAPPED to max_page_size, not honored.
    hostile = Samen.Web.Reads.build(query, %ListState{page_size: 10_000, sort: {:display_name, :asc}})
    assert hostile.limit == Samen.Web.Reads.max_page_size() + 1

    # Garbage page_size falls back to the default, still bounded.
    garbage = Samen.Web.Reads.build(query, %ListState{page_size: nil})
    assert garbage.limit == Samen.Web.Reads.default_page_size() + 1
  end

  # ---------------------------------------------------------------------------
  # Keyset pagination (stable under concurrent inserts)
  # ---------------------------------------------------------------------------

  test "keyset walk visits every row exactly once and is STABLE under a concurrent insert" do
    {org_id, people} = seed_org_with(12)
    original_ids = MapSet.new(people, & &1.id)
    socket = mount_socket(build_mount(:crm), org_id)

    page1 = ids(socket)
    assert names(socket) == Enum.map(1..5, &"Contact #{String.pad_leading(to_string(&1), 2, "0")}")

    # CONCURRENT INSERT sorting BEFORE the cursor — under offset pagination this
    # shifts "Contact 05" onto page 2 (duplicate); under keyset it cannot.
    inserted = create_person(org_id, "Aaa Newrow", "Broker")

    socket = event(socket, "paginate", %{"dir" => "next"})
    page2 = ids(socket)
    assert names(socket) == Enum.map(6..10, &"Contact #{String.pad_leading(to_string(&1), 2, "0")}")

    socket = event(socket, "paginate", %{"dir" => "next"})
    page3 = ids(socket)
    assert names(socket) == ["Contact 11", "Contact 12"]
    refute socket.assigns.page.has_more

    walked = page1 ++ page2 ++ page3
    # No duplicates, no skips: the walk is exactly the 12 pre-insert rows.
    assert length(walked) == 12
    assert MapSet.new(walked) == original_ids
    refute inserted.id in walked

    # "next" past the last page is a no-op.
    socket = event(socket, "paginate", %{"dir" => "next"})
    assert names(socket) == ["Contact 11", "Contact 12"]

    # Prev pops the cursor stack back to page 2, then to an HONEST first page
    # (which now includes the concurrently inserted first-sorting row).
    socket = event(socket, "paginate", %{"dir" => "prev"})
    assert ids(socket) == page2
    socket = event(socket, "paginate", %{"dir" => "prev"})
    assert hd(names(socket)) == "Aaa Newrow"
    # Prev on the first page is a no-op.
    socket = event(socket, "paginate", %{"dir" => "prev"})
    assert hd(names(socket)) == "Aaa Newrow"
  end

  # ---------------------------------------------------------------------------
  # Sort
  # ---------------------------------------------------------------------------

  test "sort toggles asc↔desc on the active field and resets to the first page" do
    {org_id, _} = seed_org_with(7)
    socket = mount_socket(build_mount(:crm), org_id)

    # Same field → toggle to desc, back to page one.
    socket = event(socket, "sort", %{"field" => "display_name"})
    assert socket.assigns.list_state.sort == {:display_name, :desc}
    assert hd(names(socket)) == "Contact 07"
    assert socket.assigns.list_state.cursor == nil
    assert socket.assigns.list_state.cursor_stack == []

    # Different declared field → asc on it.
    socket = event(socket, "sort", %{"field" => "job_title"})
    assert socket.assigns.list_state.sort == {:job_title, :asc}
    assert hd(socket.assigns.page.items).job_title == "Broker"

    # The sort header reflects the active field (aria-sort + direction glyph).
    rendered = html(socket)
    assert rendered =~ ~s(aria-sort="ascending")
  end

  test "RED PATH: an undeclared sort field from the client is REFUSED (no atom minting, state unchanged)" do
    {org_id, _} = seed_org_with(3)
    socket = mount_socket(build_mount(:crm), org_id)
    before_state = socket.assigns.list_state

    # `org_id` is a real column but NOT declared sortable; the injection string is
    # not even an existing atom — both must leave the state untouched.
    socket = event(socket, "sort", %{"field" => "org_id"})
    assert socket.assigns.list_state == before_state

    socket = event(socket, "sort", %{"field" => "no_such_field_#{System.unique_integer([:positive])}"})
    assert socket.assigns.list_state == before_state
  end

  # ---------------------------------------------------------------------------
  # Filter
  # ---------------------------------------------------------------------------

  test "filter narrows the read server-side (case-insensitive, still bounded) and resets paging" do
    {org_id, _} = seed_org_with(12)
    socket = mount_socket(build_mount(:crm), org_id)
    socket = event(socket, "paginate", %{"dir" => "next"})

    socket = event(socket, "filter", %{"filter" => "CONTACT 07", "_target" => ["filter"]})
    assert names(socket) == ["Contact 07"]
    refute socket.assigns.page.has_more
    assert socket.assigns.list_state.cursor == nil

    # Clearing the filter restores the (bounded) first page.
    socket = event(socket, "filter", %{"filter" => ""})
    assert length(socket.assigns.page.items) == 5
    assert socket.assigns.page.has_more
  end

  # ---------------------------------------------------------------------------
  # Bulk selection
  # ---------------------------------------------------------------------------

  test "select toggles a row; select_all toggles the page; bulk calls handle_bulk and clears" do
    {org_id, _} = seed_org_with(6)
    socket = mount_socket(build_mount(:crm), org_id)
    [first_id | _] = ids(socket)

    socket = event(socket, "select", %{"id" => first_id})
    assert MapSet.member?(socket.assigns.list_state.selected, first_id)
    assert html(socket) =~ "1 selected"

    socket = event(socket, "select", %{"id" => first_id})
    refute MapSet.member?(socket.assigns.list_state.selected, first_id)
    refute html(socket) =~ ~s(class="bulk-bar")

    socket = event(socket, "select_all", %{})
    assert MapSet.size(socket.assigns.list_state.selected) == 5
    page_ids = MapSet.new(ids(socket))

    socket = event(socket, "bulk", %{"action" => "archive"})
    # The view's handle_bulk/3 received exactly the selected ids…
    assert MapSet.new(socket.assigns.bulk_archived) == page_ids
    # …and the selection was cleared afterwards.
    assert MapSet.size(socket.assigns.list_state.selected) == 0

    # select_all on an already fully-selected page deselects it.
    socket = event(socket, "select_all", %{})
    socket = event(socket, "select_all", %{})
    assert MapSet.size(socket.assigns.list_state.selected) == 0
  end

  # ---------------------------------------------------------------------------
  # Hook wiring (the mixin owns its events; everything else :cont's)
  # ---------------------------------------------------------------------------

  test "init_list attaches the handle_event hook on a mounted socket, idempotently" do
    {org_id, _} = seed_org_with(2)
    mount = build_mount(:crm)

    socket =
      %Phoenix.LiveView.Socket{private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}}}
      |> Phoenix.Component.assign(:samen_mount, mount)
      |> Phoenix.Component.assign(:samen_acting_as, false)
      |> ContactsLive.load(org_id)

    hooks = socket.private.lifecycle.handle_event
    assert Enum.count(hooks, &(&1.id == :samen_list_live)) == 1

    # Re-entry (handle_params re-load) must not double-attach or raise.
    socket = ContactsLive.load(socket, org_id)
    assert Enum.count(socket.private.lifecycle.handle_event, &(&1.id == :samen_list_live)) == 1

    # The hook HALTS the events it owns and CONTinues everything else.
    assert {:halt, _} = ListLive.on_event("sort", %{"field" => "display_name"}, socket)
    assert {:halt, _} = ListLive.on_event("paginate", %{"dir" => "next"}, socket)
    assert {:cont, ^socket} = ListLive.on_event("log_activity", %{}, socket)
  end

  test "empty org renders the :empty slot through list_view's default path" do
    org_id = Ash.UUID.generate()
    socket = mount_socket(build_mount(:crm), org_id)

    assert socket.assigns.page.items == []
    rendered = html(socket)
    assert rendered =~ ~s(id="fixture-empty")
    refute rendered =~ "<table>"
  end

  # ===========================================================================
  # THE PER-PLANE MASKING GUARANTEE on the table primitive (tenant clear /
  # operator ••••) — the A2-required masking test.
  # ===========================================================================

  test "TENANT plane: the list_view table renders the contact's PII in the clear" do
    %{org_id: org_id} = Seeds.seed_all()
    socket = mount_socket(build_mount(:crm, plane: :tenant), org_id)
    rendered = html(socket)

    # Non-vacuous: the seeded row is present as a list_view row.
    assert rendered =~ ~s(class="list-row")
    assert rendered =~ Seeds.contact_full_name()
    assert rendered =~ Seeds.contact_email()
  end

  test "OPERATOR plane: the SAME list_view table renders the SAME contact masked ••••, PII + token ABSENT" do
    %{org_id: org_id} = Seeds.seed_all()
    socket = mount_socket(build_mount(:crm, plane: :operator, target_org_id: org_id), org_id)
    rendered = html(socket)

    # Non-vacuous: the SAME seeded row is present.
    assert rendered =~ ~s(class="list-row")
    # Masked sentinel present; plaintext ABSENT.
    assert rendered =~ "••••"
    refute rendered =~ Seeds.contact_full_name()
    refute rendered =~ Seeds.contact_email()
    refute rendered =~ Seeds.contact_phone()
    # RED PATH: no vault token leaks into the DOM.
    refute rendered =~ "vt_"
  end
end
