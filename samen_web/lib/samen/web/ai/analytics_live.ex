defmodule Samen.Web.AI.AnalyticsLive do
  @moduledoc """
  Surface 4/5 — the D7 token-blind analytics ask-box. A natural-language question is answered
  over a `use Samen.Aggregate.Resource` projection whose schema structurally contains NO PII
  columns; the read runs as the singleton aggregate actor with k-anon/l-diversity floors
  (`Samen.AI.Analytics.ask/4`). Per the T144 gate the CALLER must hold a platform/operator
  capability — a tenant-plane session is refused `{:error, :unauthorized}` fail-closed BEFORE
  any row is read, and `ai_result/1` renders that honestly (never a fabricated aggregate). The
  aggregate resource is the host-configured `:ai_aggregate_resource` mount label.

  ## M4 dogfood fix — no dead-tab ask input on the tenant plane

  A tenant-plane caller is refused DETERMINISTICALLY, before any row is read, on
  every single question — the ask form could never once succeed for that persona.
  Presenting a live-looking input + Ask button that can never succeed is a dead
  tab, not honesty. `Samen.Web.AI.Components.analytics_ask_offered?/1` (mirroring
  `Samen.Web.CRM.Live.writable?/1`'s tenant/operator UI posture split) gates the
  INPUT ITSELF: on the tenant plane this page renders the SAME honest
  `ai_result/1` `:unauthorized` card up front (no input to type into); on the
  operator plane the real input still renders. T144 itself is UNCHANGED — this is
  a UI posture, not a security gate; the kernel's deny-by-default check still runs
  on every submit regardless.
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

  @doc "The framework page-load seam."
  def load(socket, org_id, opts \\ []) do
    mount = socket.assigns[:samen_mount]
    resource = Mount.label(mount, :ai_aggregate_resource, nil)
    question = Keyword.get(opts, :question, "")

    result =
      if Keyword.get(opts, :run, false) and org_id && resource && question != "",
        do: Server.analytics_ask(mount, org_id, resource, question),
        else: nil

    socket
    |> Phoenix.Component.assign(:org_id, org_id)
    |> Phoenix.Component.assign(:aggregate_resource, resource)
    |> Phoenix.Component.assign(:question, question)
    |> Phoenix.Component.assign(:result, result)
  end

  @impl true
  def handle_event("ask", %{"question" => question}, socket),
    do: {:noreply, load(socket, socket.assigns.org_id, question: question, run: true)}

  @impl true
  def render(assigns) do
    ~H"""
    <.app_shell>
      <:sidebar>
        <.sidebar title={name(@samen_mount, @org_id)} subtitle="AI" logo={Mount.label(@samen_mount, :glyph, "AI")}>
          <.ai_sidebar_nav active={:analytics} base={ai_base(@samen_mount)} />
        </.sidebar>
      </:sidebar>

      <.topbar title="AI · Analytics" crumbs={["AI", "Analytics"]} />
      <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />
      <.ai_tabs active={:analytics} base={ai_base(@samen_mount)} />

      <%= cond do %>
        <% is_nil(@org_id) -> %>
          <.no_org_card mount={@samen_mount} />
        <% is_nil(@aggregate_resource) -> %>
          <div class="pane" style="padding:16px">
            <.empty_state
              title="No aggregate resource configured"
              body="Set the :ai_aggregate_resource mount label to a use Samen.Aggregate.Resource projection."
              icon="◫"
            />
          </div>
        <% true -> %>
          <div class="pane" style="display:flex;flex-direction:column;gap:16px;padding:16px">
            <div class="card" id="ai-analytics-note" style="padding:12px">
              <.pill variant="info">Token-blind aggregate plane</.pill>
              <span style="color:var(--muted);font-size:12px;margin-left:8px">
                cross-tenant totals, k-anon/l-diversity floored; authorized for platform/operator callers only
              </span>
            </div>

            <%= if analytics_ask_offered?(@samen_mount) do %>
              <form phx-submit="ask" class="card" id="ai-analytics-ask-form" style="display:flex;gap:8px;padding:16px">
                <input type="text" name="question" id="ai-analytics-input" value={@question} placeholder="Ask an analytics question…" style="flex:1" />
                <.button variant="primary" type="submit">Ask</.button>
              </form>

              <.ai_result :if={@result} result={@result} id="ai-analytics-result" />
            <% else %>
              <.ai_result result={{:error, :unauthorized}} id="ai-analytics-result" />
            <% end %>
          </div>
      <% end %>
    </.app_shell>
    """
  end
end
