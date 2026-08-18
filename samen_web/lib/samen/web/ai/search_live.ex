defmodule Samen.Web.AI.SearchLive do
  @moduledoc """
  Surface 2/5 — semantic (vector) search with the T152 self-describing `%Hit{}` snippets.
  Org-scoped by construction (`Samen.AI.Embeddings.search/3`'s `aie_org_id` filter — cross-org
  rows are never even ranked). The ranking's SIMULATED-vs-real state is signposted from
  `Samen.AI.Embeddings.embedder_simulated?/1` (T78/T152). A rendered Hit snippet is
  masking-safe by construction (an embedded field is non-PII; the snippet stores only a
  `vt_`-free excerpt) — the UI renders it verbatim and asserts no `vt_*`/plaintext leak.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Live, only: [assign_mount: 2]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, name: 2]
  import Samen.Web.AI.Components

  alias Samen.Web.AI.Server
  alias Samen.Web.Mount

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    mount = socket.assigns[:samen_mount]
    org_id = Samen.Web.CurrentOrg.resolve(mount, params, session)
    {:ok, load(socket, org_id, q: params["q"] || "")}
  end

  @doc "The framework page-load seam."
  def load(socket, org_id, opts \\ []) do
    q = Keyword.get(opts, :q, "")

    {hits, simulated?, error} =
      if org_id && q != "" do
        case Server.search(socket.assigns[:samen_mount], org_id, q) do
          {{:ok, hits}, sim} -> {hits, sim, nil}
          {{:error, reason}, sim} -> {[], sim, reason}
        end
      else
        {[], false, nil}
      end

    socket
    |> Phoenix.Component.assign(:org_id, org_id)
    |> Phoenix.Component.assign(:q, q)
    |> Phoenix.Component.assign(:hits, hits)
    |> Phoenix.Component.assign(:simulated, simulated?)
    |> Phoenix.Component.assign(:error, error)
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket),
    do: {:noreply, load(socket, socket.assigns.org_id, q: q)}

  @impl true
  def render(assigns) do
    ~H"""
    <.app_shell>
      <:sidebar>
        <.sidebar title={name(@samen_mount, @org_id)} subtitle="AI" logo={Mount.label(@samen_mount, :glyph, "AI")}>
          <.ai_sidebar_nav active={:search} base={ai_base(@samen_mount)} />
        </.sidebar>
      </:sidebar>

      <.topbar title="AI · Semantic search" crumbs={["AI", "Semantic search"]} />
      <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />
      <.ai_tabs active={:search} base={ai_base(@samen_mount)} />

      <%= if is_nil(@org_id) do %>
        <.no_org_card mount={@samen_mount} />
      <% else %>
        <div class="pane" style="display:flex;flex-direction:column;gap:16px;padding:16px">
          <form phx-submit="search" class="card" style="display:flex;gap:8px;padding:16px">
            <input type="text" name="q" id="ai-search-input" value={@q} placeholder="Search semantically…" style="flex:1" />
            <.button variant="primary" type="submit">Search</.button>
          </form>

          <div :if={@simulated} id="ai-search-simulated">
            <.pill variant="warn">SIMULATED ranking — deterministic embedder, not a real model</.pill>
          </div>

          <div :if={@error} class="card" id="ai-search-error" style="padding:12px">
            <.pill variant="warn">Search unavailable</.pill>
          </div>

          <div :if={@q != "" and @hits == [] and is_nil(@error)} id="ai-search-empty">
            <.empty_state title="No matches" body="No embedded rows in this org matched that query." icon="⌕" />
          </div>

          <ul :if={@hits != []} id="ai-search-hits" class="card" style="list-style:none;margin:0;padding:8px 0">
            <li
              :for={hit <- @hits}
              class="ai-search-hit"
              id={"ai-hit-#{hit.source_id}-#{hit.field}"}
              style="padding:10px 16px;border-bottom:1px solid var(--line,#222)"
            >
              <div style="font-size:12px;color:var(--muted)">
                {short_resource(hit.source_resource)} · {hit.field} · d={fmt_distance(hit.distance)}
              </div>
              <div :if={hit.snippet} class="ai-hit-snippet">{hit.snippet}</div>
              <div :if={is_nil(hit.snippet)} class="ai-hit-snippet" style="color:var(--muted);font-style:italic">
                (no snippet)
              </div>
            </li>
          </ul>
        </div>
      <% end %>
    </.app_shell>
    """
  end

  defp short_resource(res) when is_binary(res), do: res |> String.split(".") |> List.last()
  defp short_resource(res), do: inspect(res)

  defp fmt_distance(d) when is_float(d), do: :erlang.float_to_binary(d, decimals: 3)
  defp fmt_distance(d), do: to_string(d)
end
