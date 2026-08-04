defmodule Samen.Web.CRM.ContactsGalleryLive do
  @moduledoc """
  Framework CRM / Contacts GALLERY page — contacts rendered as a responsive CARD GRID (with a
  monogram avatar facet) rather than a table, the G5 GALLERY view and the FIRST client of the
  generic `Samen.UI.gallery/1` (T54/WS-G) over a keyset-bounded `%Samen.Web.Page{}`.

  ## Framework-first (T54)

  This LiveView is THIN wiring over two framework primitives — it re-implements neither the
  bounded keyset read nor the grid layout:

    * READ — `Samen.Web.CRM.Reads.contacts_gallery/4` builds a keyset `%Samen.Web.Page{}` via
      `Samen.Web.Reads.page!/3`: one bounded card-page of contacts (sorted by `:id` so the cursor
      is a non-PII uuid), org-scoped by construction, PII (name/email/phone) plane-resolved AFTER
      paging (tenant clear / operator ••••).
    * RENDER — `Samen.UI.gallery/1` lays that `%Page{}` out as a responsive card grid; this module
      supplies only the CRM-specific `:media` (monogram) + `:card` (name/title) slots and the
      no-JS `?after=` pagination link. Any other resource reuses `gallery/1` at ≈0 LOC.

  ## No-JS pagination floor (ADR-042/T113)

  Pagination is a real `?after=<id>` link on this same route (the keyset cursor is the last
  card's `:id` — a non-PII opaque uuid, safe in a URL where `display_name` would not be), so a
  JS-off client pages by ordinary GET. Every card is server-rendered; there is no JS-only path.

  ## Masking (LOAD-BEARING — 3 proofs in `contacts_gallery_masking_test.exs`)

  Contact cards render VAULT-ROUTED (🔒) PII (`full_name`/`emails`/`phones`). The read resolves
  them through `Samen.Api.PiiResolution` on the actor's plane: tenant reads its own contacts
  CLEAR; an operator-without-grant sees `%Samen.Masked{}` → `••••` (never plaintext, never a
  `vt_*` token in the DOM). `gallery/1` is a dumb renderer — it never unwraps a field; masking is
  the resolver's per-plane decision, asserted with the sanctioned three-part `Samen.MaskingCase`
  proof.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.CRM.Live, only: [assign_mount: 2, crm_sidebar: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.CRM.Reads
  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount
  alias Samen.Web.Page

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    org_id = CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)
    after_id = parse_after(Map.get(params, "after"))
    {:ok, load(assign(socket, org_id: org_id, after_id: after_id), org_id)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    org_id = Map.get(params, "org") || socket.assigns.org_id
    after_id = parse_after(Map.get(params, "after"))
    {:noreply, load(assign(socket, org_id: org_id, after_id: after_id, return_to: return_path(uri)), org_id)}
  end

  @doc false
  def load(socket, org_id, after_id \\ nil)

  def load(socket, nil, _after_id) do
    socket
    |> ensure_return_to()
    |> assign(
      no_org: CurrentOrg.no_org?(socket.assigns[:samen_mount], nil),
      org_id: nil,
      after_id: nil,
      page: %Page{items: [], page_size: 12}
    )
    |> assign_nav(nil)
  end

  def load(socket, org_id, after_id) do
    mount = socket.assigns.samen_mount
    scope = Mount.scope(mount, org_id)
    after_id = after_id || socket.assigns[:after_id]

    page = Reads.contacts_gallery(mount, scope, after_id)

    socket
    |> ensure_return_to()
    |> assign(no_org: false, org_id: org_id, after_id: after_id, page: page)
    |> assign_nav(org_id)
  end

  defp ensure_return_to(socket) do
    if Map.has_key?(socket.assigns, :return_to), do: socket, else: assign(socket, return_to: nil)
  end

  # The no-JS pagination links — a real `?after=<last id>` GET (next) + a "first page" reset.
  # `next_href` only when the page has more (the keyset probe row was seen).
  defp assign_nav(socket, org_id) do
    org = if org_id, do: "org=#{org_id}&", else: ""
    page = socket.assigns.page
    last = List.last(page.items)

    next_href =
      if page.has_more and last, do: "?#{org}after=#{last.id}"

    prev_href = if socket.assigns.after_id, do: "?#{String.trim_trailing(org, "&")}"

    assign(socket, next_href: next_href, prev_href: prev_href)
  end

  # `?after=` is a bounded uuid string; a non-uuid is ignored (first page), never trusted.
  defp parse_after(value) when is_binary(value) do
    case Ecto.UUID.cast(String.trim(value)) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp parse_after(_), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <div id="crm-contacts-gallery">
      <.app_shell>
        <:sidebar>
          <.crm_sidebar mount={@samen_mount} org_id={@org_id} active={:crm_contacts} return_to={@return_to} />
        </:sidebar>

        <.topbar title="Contacts — Gallery" crumbs={crumbs(@samen_mount, @org_id, "Gallery")} />

        <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

        <%= if @no_org do %>
          <.no_org_card mount={@samen_mount} />
        <% else %>
          <span id="org-banner" style="display:none">CRM org: {@org_id}</span>

          <div class="wrap">
            <.gallery
              id="contacts-gallery"
              page={@page}
              prev_href={@prev_href}
              next_href={@next_href}
              empty_text="No contacts yet."
              empty_body="Contacts you add will appear here as cards."
            >
              <:media :let={person}>
                <div class="gcard-mono" aria-hidden="true">{monogram(person)}</div>
              </:media>
              <:card :let={person}>
                <div class="gcard-name mono" id={"contact-card-#{person.id}"}>{person.display_name}</div>
                <div class="gcard-sub">{render_name(person.full_name, person.display_name)}</div>
                <div :if={person.job_title} class="gcard-title">{person.job_title}</div>
                <div class="gcard-email mono">{render_email(person.emails)}</div>
              </:card>
            </.gallery>
          </div>
        <% end %>
      </.app_shell>
    </div>
    """
  end

  defp crumbs(mount, org_id, leaf), do: [CurrentOrg.name(mount, org_id), "CRM", "Contacts", leaf]

  # A monogram from the NON-PII display_name only (never the vaulted full_name) — a leading-
  # letters avatar that carries no secret.
  defp monogram(%{display_name: name}) when is_binary(name) do
    name
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join("", fn part -> String.slice(part, 0, 1) end)
    |> String.upcase()
  end

  defp monogram(_), do: "•"

  # Render the ALREADY-PLANE-RESOLVED vaulted composites (mirrors `Samen.Web.CRM.ContactLive`):
  # a `%Samen.Masked{}` (operator-without-grant) passes STRAIGHT THROUGH so it renders `••••`
  # via `Phoenix.HTML.Safe` — never unwrapped, never plaintext-downgraded. On the tenant plane
  # the field arrives as the clear composite (a JSON string / an `Emails` struct / a list) and is
  # decoded to a display string. This never calls the vault.
  defp render_name(%Samen.Masked{} = masked, _display), do: masked

  defp render_name(name, _display) when is_binary(name) do
    case Jason.decode(name) do
      {:ok, %{"first" => first, "last" => last}} -> String.trim("#{first} #{last}")
      _ -> name
    end
  end

  defp render_name(%Samen.Type.FullName{first: first, last: last}, _display),
    do: String.trim("#{first} #{last}")

  defp render_name(nil, display) when is_binary(display), do: display
  defp render_name(_other, display) when is_binary(display), do: display
  defp render_name(_other, _display), do: "—"

  defp render_email(%Samen.Masked{} = masked), do: masked
  defp render_email(%Samen.Type.Emails{entries: entries}), do: render_email(entries)

  defp render_email(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> render_email(list)
      _ -> "—"
    end
  end

  defp render_email(emails) when is_list(emails) do
    case List.first(emails) do
      %{"address" => addr} -> addr
      %{address: addr} -> addr
      _ -> "—"
    end
  end

  defp render_email(_), do: "—"
end
