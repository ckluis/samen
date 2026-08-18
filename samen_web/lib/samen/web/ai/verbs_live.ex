defmodule Samen.Web.AI.VerbsLive do
  @moduledoc """
  Surface 1/5 — the six ADR-043 §7.5 intelligence verbs run over a record's content
  (Summarize · Extract · Classify · Generate · Recommend · Analyze). Free-text input is the
  record's own content (§3.2 step-2d user-consented keystrokes); the record-BOUND masked path
  is exercised by the CRM surface (`Samen.Web.AI.CrmLive`). Every run routes through
  `Samen.Web.AI.Server` → `Samen.AI.Verbs` → `Samen.AI.complete/4` → `Samen.AI.Chokepoint`
  (INV-7). SIMULATED vs live and `:not_configured` are signposted by `ai_result/1`.
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
    {:ok, load(socket, org_id)}
  end

  @doc "The framework page-load seam (drives the test harness + `mount/3`)."
  def load(socket, org_id, opts \\ []) do
    socket =
      socket
      |> Phoenix.Component.assign(:org_id, org_id)
      |> Phoenix.Component.assign(:verb, Keyword.get(opts, :verb, :summarize))
      |> Phoenix.Component.assign(:input, Keyword.get(opts, :input, ""))
      |> Phoenix.Component.assign(:labels, Keyword.get(opts, :labels, ""))
      |> Phoenix.Component.assign(:result, nil)

    if Keyword.get(opts, :run, false),
      do: Phoenix.Component.assign(socket, :result, run(socket.assigns)),
      else: socket
  end

  @impl true
  def handle_event("run", %{"verb" => verb, "input" => input} = params, socket) do
    {:noreply,
     load(socket, socket.assigns.org_id,
       verb: safe_verb(verb),
       input: input,
       labels: Map.get(params, "labels", ""),
       run: true
     )}
  end

  defp run(%{org_id: nil}), do: nil

  defp run(assigns) do
    params = if assigns.labels == "", do: %{}, else: %{labels: assigns.labels}
    Server.run_verb(assigns.samen_mount, assigns.org_id, assigns.verb, assigns.input, params)
  end

  defp safe_verb(v) when is_binary(v) do
    Enum.find(Server.verbs(), :summarize, &(Atom.to_string(&1) == v))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.app_shell>
      <:sidebar>
        <.sidebar title={name(@samen_mount, @org_id)} subtitle="AI" logo={Mount.label(@samen_mount, :glyph, "AI")}>
          <.ai_sidebar_nav active={:verbs} base={ai_base(@samen_mount)} />
        </.sidebar>
      </:sidebar>

      <.topbar title="AI · Verbs" crumbs={["AI", "Verbs"]} />
      <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />
      <.ai_tabs active={:verbs} base={ai_base(@samen_mount)} />

      <%= if is_nil(@org_id) do %>
        <.no_org_card mount={@samen_mount} />
      <% else %>
        <div class="pane" style="display:flex;flex-direction:column;gap:16px;padding:16px">
          <form phx-submit="run" class="card" style="display:flex;flex-direction:column;gap:10px;padding:16px">
            <label style="font-size:13px;font-weight:600">Verb</label>
            <select name="verb" id="ai-verb-select">
              <option :for={v <- Server.verbs()} value={v} selected={v == @verb}>{v}</option>
            </select>

            <label style="font-size:13px;font-weight:600">Record content / input</label>
            <textarea name="input" id="ai-verb-input" rows="6" placeholder="Paste the record's content…">{@input}</textarea>

            <label style="font-size:13px;font-weight:600">Classify labels (optional, comma-separated)</label>
            <input type="text" name="labels" id="ai-verb-labels" value={@labels} placeholder="billing, sales, bug" />

            <div>
              <.button variant="primary" type="submit">Run verb</.button>
            </div>
          </form>

          <.ai_result :if={@result} result={@result} id="ai-verbs-result" />
        </div>
      <% end %>
    </.app_shell>
    """
  end
end
