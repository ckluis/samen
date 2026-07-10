defmodule Samen.Web.MarketingSegmentsCrudTest do
  @moduledoc """
  A3 WIRING (marketing batch) — `Samen.Web.Marketing.SegmentsLive` on the full kit
  contract (`ListLive` + `list_view` + `simple_form`/`modal`/`delete_confirm`) plus the
  BOUNDED subscribers audience panel (the 🔒 PII surface of this page):

    * **BOUNDED segments list end-to-end (read!-elimination, AC-G1-5)** — a 55-row org
      NEVER loads the full set through `Reads.segments_page/3`; keyset next/prev walks
      the rest. `bounded!/4` (RP-G1-5) green-lights `segments_page/3` AND
      `subscribers_page/3`; the anti-tautology pairing red-lights an unbounded stand-in.
    * **CRUD (AC-G1-1/2)** — "New segment" is a REAL button opening the modal +
      `simple_form`; an INVALID submit (`name` required) renders inline errors and
      persists NOTHING; a VALID submit persists + refreshes; each row carries the
      `delete_confirm/1` interlock and delete destroys through Ash.
    * **BOUNDED subscribers panel** — the old unbounded `Reads.subscribers/2` is gone
      from this surface: a 55-subscriber org renders exactly the first bounded page +
      the explicit "first N" note; the per-row suppression flag reads
      `Reads.suppressed_ids/3` bounded to the page's own ids.
    * **PER-PLANE MASKING (MC on the retrofitted PII read)** — through the NEW
      `subscribers_page/3` the tenant renders its subscribers' email CLEAR; the
      operator plane renders the SAME rows `••••` with plaintext AND vault token
      ABSENT from the DOM (the read rides the same `PiiResolution` chokepoint).
      This page offers NO subscriber write (subscribers enter through consented
      paths), so the panel is render-side masking only.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.ListLive
  alias Samen.Web.Marketing.Reads, as: MktReads
  alias Samen.Web.Marketing.SegmentsLive
  alias Samen.Web.Mount
  alias Samen.Web.Reads, as: WebReads
  alias Samen.Web.Reads.UnboundedReadError

  # -- harness -------------------------------------------------------------------

  defp mount_socket(org_id, plane_opts \\ []) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, build_mount(:marketing, plane_opts))
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> Phoenix.Component.assign(:return_to, nil)
    |> SegmentsLive.load(org_id)
  end

  defp html(socket), do: render_html(SegmentsLive, socket.assigns)

  defp event(socket, name, params) do
    {:noreply, socket} = SegmentsLive.handle_event(name, params, socket)
    socket
  end

  defp list_event(socket, name, params) do
    {:noreply, socket} = ListLive.handle_list_event(name, params, socket)
    socket
  end

  defp names(socket), do: Enum.map(socket.assigns.page.items, & &1.name)

  defp segment_count(org_id) do
    Samen.WebTest.Marketing.Segment
    |> Ash.Query.ensure_selected([:org_id])
    |> Ash.read!(authorize?: false)
    |> Enum.count(&(&1.org_id == org_id))
  end

  defp seed_segments(org_id, n) do
    for i <- 1..n//1 do
      Samen.WebTest.Marketing.Segment
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          name: "Segment #{String.pad_leading(to_string(i), 2, "0")}",
          description: "Audience #{i}",
          filter_criteria: %{"status" => "active"},
          subscriber_count: i
        },
        authorize?: false
      )
      |> Ash.create!()
    end

    org_id
  end

  defp seed_subscribers(org_id, n) do
    for i <- 1..n//1 do
      Samen.WebTest.Marketing.Subscriber
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          email: "subscriber.#{String.pad_leading(to_string(i), 2, "0")}@example.test",
          status: :active,
          source: "import"
        },
        authorize?: false
      )
      |> Ash.create!()
    end

    org_id
  end

  # ---------------------------------------------------------------------------
  # BOUNDED segments list end-to-end
  # ---------------------------------------------------------------------------

  test "a 55-segment org NEVER loads the full set: page one is exactly default_page_size rows, keyset walks the rest" do
    org_id = seed_segments(Ash.UUID.generate(), 55)
    socket = mount_socket(org_id)

    assert length(socket.assigns.page.items) == WebReads.default_page_size()
    assert socket.assigns.page.has_more

    rendered = html(socket)
    refute rendered =~ "Segment 51"

    socket = list_event(socket, "paginate", %{"dir" => "next"})
    assert names(socket) == Enum.map(51..55, &"Segment #{&1}")
    refute socket.assigns.page.has_more

    socket = list_event(socket, "paginate", %{"dir" => "prev"})
    assert length(socket.assigns.page.items) == WebReads.default_page_size()
    assert hd(names(socket)) == "Segment 01"
  end

  test "sort + filter are kit defaults on the real page; an empty org renders the kit empty_state" do
    org_id = seed_segments(Ash.UUID.generate(), 7)
    socket = mount_socket(org_id)

    assert socket.assigns.list_state.sort == {:name, :asc}
    socket = list_event(socket, "sort", %{"field" => "name"})
    assert hd(names(socket)) == "Segment 07"

    socket = list_event(socket, "filter", %{"filter" => "segment 03"})
    assert names(socket) == ["Segment 03"]

    empty = mount_socket(Ash.UUID.generate())
    assert empty.assigns.page.items == []
    rendered = html(empty)
    assert rendered =~ "empty-state"
    assert rendered =~ "No segments yet."
    assert rendered =~ "No subscribers yet."
  end

  # ---------------------------------------------------------------------------
  # RP-G1-5 on the NEW reads fns — bounded! green + anti-tautology red
  # ---------------------------------------------------------------------------

  test "bounded! lint: segments_page/3 AND subscribers_page/3 are bounded; an unbounded stand-in RAISES" do
    org_id = Ash.UUID.generate()
    seed_segments(org_id, 14)
    seed_subscribers(org_id, 14)
    mount = build_mount(:marketing)
    scope = Mount.scope(mount, org_id)

    assert :ok = WebReads.bounded!(&MktReads.segments_page/3, mount, scope, page_size: 5)
    assert :ok = WebReads.bounded!(&MktReads.subscribers_page/3, mount, scope, page_size: 5)

    # Anti-tautology pairing: the SAME probe rejects an unbounded read — the lint
    # discriminates, it is not a no-op.
    unbounded = fn m, s, _state ->
      items = Samen.Web.Mount.resource(m, Segment) |> Ash.read!(scope: s)
      %Samen.Web.Page{items: items, page_size: 5}
    end

    assert_raise UnboundedReadError, fn ->
      WebReads.bounded!(unbounded, mount, scope, page_size: 5)
    end
  end

  # ---------------------------------------------------------------------------
  # CRUD — create (green + red) and delete (AC-G1-1/2)
  # ---------------------------------------------------------------------------

  test "New segment is a REAL button: opens the modal + simple_form; a VALID submit persists + refreshes" do
    org_id = Ash.UUID.generate()
    socket = mount_socket(org_id)

    rendered = html(socket)
    assert rendered =~ ~s(id="new-segment")
    assert rendered =~ ~s(phx-click="new_segment")

    socket = event(socket, "new_segment", %{})
    rendered = html(socket)
    assert rendered =~ ~s(role="dialog")
    assert rendered =~ ~s(id="new-segment-form")
    assert rendered =~ ~s(name="form[name]")

    socket =
      event(socket, "save_new", %{
        "form" => %{"name" => "Lapsed carriers", "description" => "No load in 90 days"}
      })

    refute socket.assigns.show_new
    assert segment_count(org_id) == 1
    rendered = html(socket)
    assert rendered =~ "Lapsed carriers"
    refute rendered =~ "No segments yet."
  end

  test "RED PATH (AC-G1-2): an INVALID submit (blank required name) shows inline errors and persists NOTHING" do
    org_id = Ash.UUID.generate()
    socket = mount_socket(org_id) |> event("new_segment", %{})

    socket = event(socket, "save_new", %{"form" => %{"name" => "", "description" => "half"}})

    # Modal stays open with the inline field error (AC-G1-2).
    assert socket.assigns.show_new
    rendered = html(socket)
    assert rendered =~ "field-invalid"
    assert rendered =~ "field-error"
    assert rendered =~ "is required"
    # Nothing persisted; the list is untouched.
    assert segment_count(org_id) == 0
    assert socket.assigns.page.items == []
  end

  test "each row carries the delete_confirm interlock; delete destroys through Ash and refreshes" do
    org_id = Ash.UUID.generate()
    socket = mount_socket(org_id) |> event("new_segment", %{})
    socket = event(socket, "save_new", %{"form" => %{"name" => "Doomed segment"}})
    [segment] = socket.assigns.page.items

    rendered = html(socket)
    assert rendered =~ ~s(data-confirm="Delete this record? This cannot be undone.")
    assert rendered =~ ~s(phx-click="delete")
    assert rendered =~ ~s(phx-value-id="#{segment.id}")

    socket = event(socket, "delete", %{"id" => segment.id})
    assert socket.assigns.page.items == []
    assert segment_count(org_id) == 0
    assert html(socket) =~ "No segments yet."
  end

  # ---------------------------------------------------------------------------
  # The BOUNDED subscribers panel (read!-elimination on the PII list)
  # ---------------------------------------------------------------------------

  test "a 55-subscriber org renders exactly the first bounded page + the explicit 'first N' note" do
    org_id = seed_subscribers(Ash.UUID.generate(), 55)
    socket = mount_socket(org_id)

    assert length(socket.assigns.sub_page.items) == WebReads.default_page_size()
    assert socket.assigns.sub_page.has_more

    rendered = html(socket)
    assert rendered =~ "subscribers-bounded-note"
    assert rendered =~ "Showing the first #{WebReads.default_page_size()} subscribers"
  end

  test "the suppression flag reads suppressed_ids/3 bounded to the page's own ids (flagged row renders 'suppressed')" do
    %{org_id: org_id, marketing: mkt} = Seeds.seed_all()
    socket = mount_socket(org_id)

    # The seeded suppressed subscriber is flagged; the deliverable one is not.
    assert MapSet.member?(socket.assigns.suppressed_ids, mkt.suppressed_subscriber.id)
    refute MapSet.member?(socket.assigns.suppressed_ids, mkt.active_subscriber.id)
    assert html(socket) =~ "suppressed-flag"

    # Bounded by construction: an empty page asks for no suppression rows at all.
    mount = build_mount(:marketing)
    scope = Mount.scope(mount, org_id)
    assert MktReads.suppressed_ids(mount, scope, []) == MapSet.new()
  end

  # ---------------------------------------------------------------------------
  # PER-PLANE MASKING on the retrofitted PII read (MC — the batch's PII surface)
  # ---------------------------------------------------------------------------

  test "TENANT plane: the subscribers panel renders the org's own emails CLEAR through subscribers_page/3" do
    %{org_id: org_id} = Seeds.seed_all()
    socket = mount_socket(org_id)

    rendered = html(socket)
    assert rendered =~ Seeds.active_subscriber_email()
    assert rendered =~ Seeds.suppressed_subscriber_email()
    refute rendered =~ "vt_"
  end

  test "MASKING RED PATH: OPERATOR plane renders the SAME rows ‘••••’ — plaintext AND token ABSENT from the DOM" do
    %{org_id: org_id} = Seeds.seed_all()
    socket = mount_socket(org_id, plane: :operator, target_org_id: org_id)

    # Non-vacuous: the subscriber rows RENDER on the operator plane, and every email
    # is a RESOLVED %Masked{} (not nil, not a skipped-resolution raw value)…
    assert socket.assigns.sub_page.items != []
    assert Enum.all?(socket.assigns.sub_page.items, &match?(%Samen.Masked{}, &1.email))
    rendered = html(socket)
    assert rendered =~ "subscriber-row"
    # …masked to pixel: •••• present, plaintext + vault token + pii column absent.
    assert rendered =~ "••••"
    refute rendered =~ Seeds.active_subscriber_email()
    refute rendered =~ Seeds.suppressed_subscriber_email()
    refute rendered =~ "vt_"
    refute rendered =~ "pii_"
  end

  # ---------------------------------------------------------------------------
  # Plane posture — write affordances are tenant-plane only (belt)
  # ---------------------------------------------------------------------------

  test "OPERATOR plane: the page renders but offers NO write affordances (no New button, no delete)" do
    org_id = seed_segments(Ash.UUID.generate(), 3)
    socket = mount_socket(org_id, plane: :operator, target_org_id: org_id)

    rendered = html(socket)
    # Non-vacuous: the rows render for the operator (Segment is non-PII)…
    assert rendered =~ "Segment 01"
    # …but no write affordance is offered (kernel + guard enforce regardless).
    refute rendered =~ ~s(phx-click="new_segment")
    refute rendered =~ ~s(phx-click="delete")
    refute rendered =~ "data-confirm"
  end
end
