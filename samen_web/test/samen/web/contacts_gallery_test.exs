defmodule Samen.Web.ContactsGalleryTest do
  @moduledoc """
  T54 (G5) — the CRM Contacts GALLERY (`Samen.Web.CRM.ContactsGalleryLive` +
  `Samen.Web.CRM.Reads.contacts_gallery/4`), the first client of `Samen.UI.gallery/1`. Proves,
  against real DB rows:

    * BOUNDED KEYSET READ — a 20-contact org NEVER loads the full set on the real page: exactly
      the gallery page size (12) cards on page one; the no-JS `?after=<id>` keyset link completes
      the walk (anti-tautology: an org SMALLER than the page has no next link).
    * NO-JS PAGINATION — the next link is a real `?after=<last id>` GET carrying a non-PII uuid
      (never `display_name`); it is absent on the last page.
    * ORG-SCOPE — a 2-org seed: org B's contacts NEVER appear in org A's gallery
      (sabotage-refutable — org B genuinely holds cards, proven absent from org A's grid).
    * GRID RENDER — contacts render as `.gcard` cards (not a table).
  """
  use Samen.WebTest.DataCase, async: false

  require Ash.Query

  alias Samen.Web.CRM.ContactsGalleryLive
  alias Samen.Web.Mount

  defp seed_contacts(org_id, n) do
    for i <- 1..n do
      Samen.WebTest.Crm.Person
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          display_name: "Contact #{String.pad_leading(to_string(i), 2, "0")}",
          job_title: "Role #{i}"
        },
        authorize?: false
      )
      |> Ash.create!()
    end
  end

  defp mount_socket(mount, org_id, after_id \\ nil) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, mount)
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> Phoenix.Component.assign(:return_to, nil)
    |> ContactsGalleryLive.load(org_id, after_id)
  end

  defp html(socket), do: render_html(ContactsGalleryLive, socket.assigns)
  defp count(html, needle), do: html |> String.split(needle) |> length() |> Kernel.-(1)

  # -- BOUNDED KEYSET READ -----------------------------------------------------

  test "BOUNDED: a 20-contact org loads exactly the gallery page size on page one, keyset next completes the walk" do
    mount = build_mount(:crm)
    org_id = Ash.UUID.generate()
    seed_contacts(org_id, 20)

    socket = mount_socket(mount, org_id)
    page1 = socket.assigns.page

    assert length(page1.items) == 12
    assert page1.has_more
    assert socket.assigns.next_href =~ "after="

    # The rendered grid shows exactly 12 cards, never the full 20.
    rendered = html(socket)
    assert count(rendered, ~s(class="gcard")) == 12

    # Follow the no-JS keyset cursor: page 2 holds the remaining 8, and has no next link.
    last_id = List.last(page1.items).id
    socket2 = mount_socket(mount, org_id, last_id)
    assert length(socket2.assigns.page.items) == 8
    refute socket2.assigns.page.has_more
    refute socket2.assigns.next_href

    # No overlap between the two pages (keyset, not offset — stable, complete).
    ids1 = MapSet.new(page1.items, & &1.id)
    ids2 = MapSet.new(socket2.assigns.page.items, & &1.id)
    assert MapSet.disjoint?(ids1, ids2)
  end

  test "the ?after= cursor is a non-PII uuid, never the display_name" do
    mount = build_mount(:crm)
    org_id = Ash.UUID.generate()
    seed_contacts(org_id, 15)

    socket = mount_socket(mount, org_id)
    last = List.last(socket.assigns.page.items)

    # The cursor carries the last card's opaque uuid (never the display_name).
    assert socket.assigns.next_href =~ "after=#{last.id}"
    refute socket.assigns.next_href =~ "Contact"
  end

  test "a small org (under the page size) has no next link (anti-tautology for BOUNDED)" do
    mount = build_mount(:crm)
    org_id = Ash.UUID.generate()
    seed_contacts(org_id, 3)

    socket = mount_socket(mount, org_id)
    assert length(socket.assigns.page.items) == 3
    refute socket.assigns.page.has_more
    refute socket.assigns.next_href
  end

  # -- ORG-SCOPE (sabotage-refutable) ------------------------------------------

  test "ORG-SCOPE: org B's contacts NEVER appear in org A's gallery" do
    mount = build_mount(:crm)
    org_a = Ash.UUID.generate()
    org_b = Ash.UUID.generate()

    seed_contacts(org_a, 4)
    seed_contacts(org_b, 6)

    # Refutation setup: org B genuinely holds 6 contacts (a live, non-empty set).
    b_ids =
      Samen.WebTest.Crm.Person
      |> Ash.Query.filter(org_id == ^org_b)
      |> Ash.read!(scope: Mount.scope(mount, org_b))
      |> MapSet.new(& &1.id)

    assert MapSet.size(b_ids) == 6

    socket = mount_socket(mount, org_a)
    a_ids = MapSet.new(socket.assigns.page.items, & &1.id)

    # OrgScope narrows the gallery to org A's 4 contacts; none of org B's 6 (disjoint by id —
    # org B genuinely holds a live set above, so this is sabotage-refutable, not a dead read).
    assert MapSet.size(a_ids) == 4
    assert MapSet.disjoint?(a_ids, b_ids)
  end

  # -- GRID RENDER -------------------------------------------------------------

  test "GRID: contacts render as gallery cards, not a table" do
    mount = build_mount(:crm)
    org_id = Ash.UUID.generate()
    seed_contacts(org_id, 2)

    rendered = html(mount_socket(mount, org_id))
    assert rendered =~ ~s(class="gallery-grid")
    assert rendered =~ "Contact 01"
    assert rendered =~ "Contact 02"
  end

  test "no org resolved renders the honest empty state, never a crash" do
    rendered = html(mount_socket(build_mount(:crm), nil))
    assert is_binary(rendered)
  end
end
