defmodule Samen.Web.Support.PortalKbLive do
  @moduledoc """
  Framework tenant PORTAL — the UNAUTHENTICATED self-serve knowledge base + ticket
  deflection surface (T78, spec §I5 done-criteria 1/3). Mounted DIRECTLY at a
  host's CMS namespace (`samen_module_routes :kb, Host.Cms, repo: ..., path:
  "/portal"`, in a PUBLIC router scope — no auth pipeline, the `samen_auth_routes`
  posture). `org_id` comes from the URL path (`/portal/:org`), never a session —
  there IS no session for an anonymous visitor.

  ## Two surfaces, one page

    * **Browse** — every `visibility: :public, status: :published` article
      (`Samen.Web.Support.KbReads.public_articles/2`, `Post.read_public` —
      never the default `:read`, so an internal article structurally cannot
      appear here regardless of what this LiveView renders).
    * **Deflect** — a draft-ticket form (subject + description, mirroring
      `Support.Ticket`'s own `subject` shape). As the visitor types, matching
      KB articles surface via the AI plane BEFORE any ticket is ever created
      (`KbReads.suggest_for_portal/3`) — self-serve deflection. This page
      NEVER creates a real ticket: `Support.Ticket`'s `:create` action is
      member-gated by the kernel (an anonymous visitor has no actor at all),
      so filing the actual ticket is intentionally left to the authenticated
      flow (`Samen.Web.Support.TicketsLive`) — the deflection copy says so
      plainly. Building anonymous ticket creation is a distinct, larger
      surface (a new policy carve-out on `Ticket`) out of T78's scope.

  ## Honest states throughout (T78 hard rule)

  No KB namespace wired → the SAME "not set up" honest empty state as
  `Samen.Web.Support.KbLive`. No public articles → an honest empty state, never
  a fabricated list. No AI provider wired → `:not_configured`, `configuration_hint`
  rendered verbatim (never fabricated advice); the keyless `:test`-only
  deterministic ranking is signposted "SIMULATED" (T152's mechanism, mirrored
  onto the embeddings lane by `Samen.AI.Embeddings.embedder_simulated?/1`) —
  never presented as if it were a real semantic match. Deflection metrics are
  NEVER fabricated: this page counts (in-memory, per-render) only "articles
  shown", never a persisted "deflection rate" — no invented denominator.
  """
  use Phoenix.LiveView

  import Samen.UI

  alias Samen.Web.Live, as: SamenLive
  alias Samen.Web.Mount
  alias Samen.Web.Support.KbReads

  @impl true
  def mount(params, session, socket) do
    socket = SamenLive.assign_mount(socket, session)
    {:ok, load(socket, Map.get(params, "org"))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, load(socket, Map.get(params, "org") || socket.assigns[:org_id])}
  end

  @doc false
  def load(socket, nil) do
    assign(socket, org_id: nil, articles: [], deflect_form: blank_deflect_form(), suggestion: nil)
  end

  def load(socket, org_id) do
    kb_mount = kb_mount(socket.assigns[:samen_mount])

    socket
    |> assign(org_id: org_id, kb_mount: kb_mount)
    |> assign(articles: kb_mount && KbReads.public_articles(kb_mount, org_id) |> Kernel.||([]))
    |> assign_new(:deflect_form, fn -> blank_deflect_form() end)
    |> assign_new(:suggestion, fn -> nil end)
  end

  # `:kb`-kind mount = a mount pointed DIRECTLY at the CMS namespace (this page's own
  # `samen_module_routes :kb, Host.Cms, ...` mount) — no `:kb_namespace` label indirection
  # needed here (unlike KbLive, which lives on the SUPPORT mount and must reach a sibling
  # namespace). `nil` when the mount itself failed to resolve (session corruption / cold
  # start) — the same honest "not set up" empty state either way.
  defp kb_mount(%Mount{namespace: ns} = mount) when not is_nil(ns), do: mount
  defp kb_mount(_), do: nil

  defp blank_deflect_form, do: to_form(%{"subject" => "", "description" => ""}, as: :deflect)

  # L3 (Phase-6 T85 gate dogfood) — resolve the sign-in destination through the SAME
  # host-configurable seam every other framework page uses
  # (`Samen.Web.Auth.LoginLive.login_action/1`, `Samen.Web.Operator.Fleet.login_path/1`):
  # `Mount.label(mount, :login_path, "/login")`. A hardcoded `"/login"` literal broke on
  # any host whose login lives elsewhere (or under a path prefix); `nil` when the mount
  # itself failed to resolve falls back to the same neutral default.
  defp login_href(%Mount{} = mount), do: Mount.label(mount, :login_path, "/login")
  defp login_href(_), do: "/login"

  # -- events -------------------------------------------------------------------

  @impl true
  def handle_event("deflect", %{"deflect" => params}, socket) do
    form = to_form(params, as: :deflect)
    query = deflect_query(params)

    suggestion =
      if String.trim(query) == "" do
        nil
      else
        KbReads.suggest_for_portal(socket.assigns.kb_mount, socket.assigns.org_id, query)
      end

    {:noreply, assign(socket, deflect_form: form, suggestion: suggestion)}
  end

  defp deflect_query(%{"subject" => s, "description" => d}), do: String.trim("#{s} #{d}")
  defp deflect_query(_), do: ""

  @impl true
  def render(assigns) do
    ~H"""
    <div id="portal-kb" class="wrap" style="max-width:760px;margin:0 auto;padding:32px 20px">
      <div class="gtitle" style="margin-bottom:20px">
        <h1 style="font-size:22px;margin:0">Help center</h1>
      </div>

      <%= cond do %>
        <% @org_id == nil -> %>
          <.empty_state icon="🔎" title="No organization specified." body="This help center link is missing its organization." />
        <% @kb_mount == nil -> %>
          <.empty_state
            class="kb-portal-not-adopted"
            icon="📚"
            title="Knowledge base not set up."
            body="This organization has not enabled the self-serve help center yet."
          />
        <% true -> %>
          <div class="card" id="deflection-panel" style="padding:20px;margin-bottom:24px">
            <div class="gtitle" style="margin-bottom:12px"><h3>Need help? Describe your issue</h3></div>
            <p style="font-size:12px;color:var(--muted);margin:0 0 12px">
              We'll show matching help articles as you type — no need to wait for a reply if one already answers your question.
            </p>
            <.simple_form :let={f} for={@deflect_form} id="deflect-form" phx-change="deflect">
              <.form_field field={f[:subject]} label="Subject" placeholder="What's the issue?" />
              <.form_field field={f[:description]} label="Description" type="textarea" rows="3" placeholder="Tell us more…" />
            </.simple_form>

            {render_suggestion(@suggestion)}

            <p style="font-size:12px;color:var(--muted);margin-top:14px">
              Still need help? <a href={login_href(@samen_mount)} id="portal-sign-in-link">Sign in</a> to open a support ticket.
            </p>
          </div>

          <div id="portal-articles">
            <div class="gtitle" style="margin-bottom:12px">
              <h3>Browse help articles</h3>
              <span class="n">{length(@articles)}</span>
            </div>

            <%= if @articles == [] do %>
              <.empty_state class="kb-portal-empty" icon="📚" title="No help articles published yet." body="Check back soon." />
            <% else %>
              <div :for={a <- @articles} class="card portal-article" id={"portal-article-#{a.id}"} style="padding:16px 18px;margin-bottom:10px">
                <div style="font-weight:600;font-size:14px;color:#2a2b35">{a.title}</div>
                <div style="font-size:13px;color:var(--muted);margin-top:6px;white-space:pre-wrap">{excerpt(a.body)}</div>
              </div>
            <% end %>
          </div>
      <% end %>
    </div>
    """
  end

  # -- suggestion panel -----------------------------------------------------------

  defp render_suggestion(nil), do: Phoenix.HTML.raw("")

  defp render_suggestion(%{state: :ok, simulated: simulated, hits: hits}) do
    assigns = %{hits: hits, simulated: simulated}

    ~H"""
    <div id="deflect-suggestions" class="card" style="padding:12px 14px;margin-top:12px;background:var(--surface-2, #F9FAFB)">
      <div style="font-size:12px;color:var(--muted);margin-bottom:8px">
        Related articles
        <span :if={@simulated} id="deflect-simulated-badge" class="pill mut" style="margin-left:6px">SIMULATED ranking (keyless test embedder)</span>
      </div>
      <div :for={hit <- @hits} class="deflect-hit" id={"deflect-hit-#{hit.article.id}"} style="padding:8px 0;border-top:1px solid var(--border)">
        <div style="font-weight:500;font-size:13px">{hit.article.title}</div>
        <div :if={hit.snippet} style="font-size:12px;color:var(--muted)">{hit.snippet}</div>
      </div>
    </div>
    """
  end

  defp render_suggestion(%{state: :empty}) do
    assigns = %{}

    ~H"""
    <div id="deflect-suggestions" class="card" style="padding:10px 14px;margin-top:12px;color:var(--muted);font-size:12px">
      No matching help articles found — you may still want to open a ticket.
    </div>
    """
  end

  defp render_suggestion(%{state: :not_configured, configuration_hint: hint}) do
    assigns = %{hint: hint}

    ~H"""
    <div id="deflect-suggestions" class="card" style="padding:10px 14px;margin-top:12px;color:var(--muted);font-size:12px">
      <div id="deflect-not-configured">Article suggestions are not configured for this help center.</div>
      <div style="margin-top:4px;font-size:11px">{@hint}</div>
    </div>
    """
  end

  defp render_suggestion(%{state: state}) when state in [:error, :no_kb_namespace] do
    assigns = %{}

    ~H"""
    <div id="deflect-suggestions" class="card" style="padding:10px 14px;margin-top:12px;color:var(--muted);font-size:12px">
      Article suggestions are unavailable right now.
    </div>
    """
  end

  defp excerpt(nil), do: ""
  defp excerpt(body) when is_binary(body), do: body |> String.slice(0, 220)
  defp excerpt(_), do: ""
end
