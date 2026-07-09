defmodule Samen.WebTest.ListFixture.Reads do
  @moduledoc """
  Fixture reads for the A2 `ListLive`/`list_view` tests — the CONVENTIONAL shape a
  vertical `Reads` function takes after A3: `(mount, scope, %ListState{}) -> %Page{}`,
  built on `Samen.Web.Reads.page!/3` (keyset + ALWAYS-bounded) with PII resolved
  through the shared `Samen.Api.PiiResolution` chokepoint AFTER paging.
  """

  alias Samen.Web.Mount

  def contacts(mount, scope, state) do
    page =
      Mount.resource(mount, Person)
      |> Ash.Query.ensure_selected([:full_name, :emails, :phones, :display_name, :job_title])
      |> Samen.Web.Reads.page!(state, scope: scope, filter_fields: [:display_name, :job_title])

    %{page | items: resolve_pii(page.items, mount, Person, scope)}
  end

  # Same chokepoint + fail-safe posture as `Samen.Web.CRM.Reads` — on any resolver
  # error the records stay masked (no plaintext downgrade).
  defp resolve_pii(records, mount, name, scope) do
    Samen.Api.PiiResolution.resolve(
      records,
      Mount.resource(mount, name),
      actor_of(scope),
      repo: mount.repo
    )
  rescue
    _ -> records
  end

  defp actor_of(%Samen.Scope{actor: actor}), do: actor
  defp actor_of(actor) when is_map(actor), do: actor
  defp actor_of(_), do: %{}
end

defmodule Samen.WebTest.ListFixture.ContactsLive do
  @moduledoc """
  The A2 fixture LiveView — a minimal list page adopting the FULL list ergonomics via
  `use Samen.Web.ListLive` + `Samen.UI.list_view/1`. Note what is ABSENT: no
  `handle_event/3` for sort/filter/paginate/select/bulk, no pagination state, no
  unbounded read — the adoption cost the design measures (≈0 vertical lines).
  """
  use Phoenix.LiveView

  import Samen.UI

  alias Samen.Web.Mount

  use Samen.Web.ListLive,
    resource: Person,
    reads: &Samen.WebTest.ListFixture.Reads.contacts/3,
    sortable: [:display_name, :job_title],
    filter_fields: [:display_name, :job_title],
    default_sort: {:display_name, :asc},
    page_size: 5

  @doc false
  def load(socket, org_id) do
    mount = socket.assigns.samen_mount
    scope = Mount.scope(mount, org_id)

    socket
    |> assign(org_id: org_id)
    |> init_list(mount, scope)
  end

  # A bulk handler so the "bulk" event is provable end-to-end.
  def handle_bulk("archive", ids, socket), do: assign(socket, :bulk_archived, ids)
  def handle_bulk(_action, _ids, socket), do: socket

  @impl true
  def render(assigns) do
    ~H"""
    <div id="list-fixture">
      <.list_view
        id="contacts"
        page={@page}
        state={@list_state}
        selectable
        bulk_actions={[%{name: "archive", label: "Archive"}]}
      >
        <:head>
          <.sort_header field={:display_name} label="Name" sort={@list_state.sort} />
          <.sort_header field={:job_title} label="Title" sort={@list_state.sort} />
          <th scope="col">Email</th>
        </:head>
        <:row :let={p}>
          <td class="p-name">{render_full_name(p.full_name, p.display_name)}</td>
          <td class="p-title">{p.job_title || "—"}</td>
          <td class="p-email">{render_email(p.emails)}</td>
        </:row>
        <:empty>
          <div class="card" id="fixture-empty">No contacts yet.</div>
        </:empty>
      </.list_view>
    </div>
    """
  end

  # -- helpers (MASKING INVARIANT — same posture as Samen.Web.CRM.ContactsLive) ----
  # A %Masked{} is returned AS-IS so it renders •••• via Phoenix.HTML.Safe; only a
  # plaintext string is reshaped. No unwrap, no vault, no to_string on a field value.

  defp render_full_name(%Samen.Masked{} = masked, _display_name), do: masked

  defp render_full_name(name, _display_name) when is_binary(name) do
    case Jason.decode(name) do
      {:ok, %{"first" => first, "last" => last}} -> String.trim("#{first} #{last}")
      _ -> name
    end
  end

  defp render_full_name(nil, display_name) when is_binary(display_name), do: display_name
  defp render_full_name(_other, _display_name), do: "—"

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
