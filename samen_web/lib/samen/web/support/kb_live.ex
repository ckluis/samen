defmodule Samen.Web.Support.KbLive do
  @moduledoc """
  Framework Support / Knowledge Base — the agent-facing KB surface (T78, spec §I5).
  Browse + author articles (the CMS `Post`, reused — no parallel article resource;
  `visibility` distinguishes internal from public). Host-agnostic (ADR-009), same
  shape as `Samen.Web.Flags.SettingsLive`: one page, list + a create/edit modal.

  ## The `:kb_namespace` sibling-mount seam

  The KB article lives in a DIFFERENT scope (CMS) than the Support ticket
  composer. `Samen.Web.Support.KbReads.kb_mount/1` derives the sibling mount
  from the `:kb_namespace` label on THIS (Support) mount — the
  `flags_namespace`/`crm_namespace` seam, generalized. A host that has not
  wired the label sees the honest "knowledge base not set up" empty state
  (never a crash) — the same posture `FlagAdminLive` takes for an unwired
  `flags_namespace`.

  ## Reads/writes

  `articles/2` (agent view: internal + public, any status) is org-scoped —
  ANY member may author/edit a draft (the CMS blueprint's own `:update`
  posture); `:publish` is admin-gated by the kernel (the write affordance is
  offered regardless — POSTURE only, enforcement is the kernel Ash policy, the
  same split every framework LiveView documents). No PII on this scope (CMS
  has no 🔒 mark) — nothing here touches `Samen.Api.PiiResolution`.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Support.Live, only: [assign_mount: 2, support_sidebar: 1, writable?: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount
  alias Samen.Web.Support.KbReads

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    org_id = CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)
    {:ok, load(assign(socket, org_id: org_id), org_id)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    org_id = Map.get(params, "org") || socket.assigns.org_id
    {:noreply, load(assign(socket, org_id: org_id, return_to: return_path(uri)), org_id)}
  end

  @doc false
  def load(socket, nil) do
    socket
    |> ensure_return_to()
    |> assign(no_org: CurrentOrg.no_org?(socket.assigns[:samen_mount], nil), org_id: nil, kb_mount: nil, articles: [])
    |> assign(show_new: false, new_form: nil, edit_id: nil, edit_form: nil, save_error: nil)
  end

  def load(socket, org_id) do
    mount = socket.assigns.samen_mount
    kb_mount = KbReads.kb_mount(mount)
    scope = Mount.scope(mount, org_id)

    socket
    |> ensure_return_to()
    |> assign(no_org: false, org_id: org_id, kb_mount: kb_mount)
    |> assign(articles: kb_articles(kb_mount, scope))
    |> assign_new(:show_new, fn -> false end)
    |> assign_new(:edit_id, fn -> nil end)
    |> assign(new_form: kb_mount && KbReads.new_article_form(kb_mount, scope))
    |> assign(save_error: nil)
    |> refresh_edit()
  end

  defp kb_articles(nil, _scope), do: []
  defp kb_articles(kb_mount, scope), do: KbReads.articles(kb_mount, scope)

  defp refresh_edit(%{assigns: %{edit_id: nil}} = socket), do: assign(socket, edit_form: nil)

  defp refresh_edit(%{assigns: %{edit_id: id, kb_mount: kb_mount, org_id: org_id, samen_mount: mount}} = socket) do
    scope = Mount.scope(mount, org_id)

    case kb_mount && KbReads.get_article(kb_mount, scope, id) do
      nil -> assign(socket, edit_id: nil, edit_form: nil)
      article -> assign(socket, edit_form: KbReads.edit_article_form(kb_mount, scope, article))
    end
  end

  # -- events -------------------------------------------------------------------

  @impl true
  def handle_event("new_article", _params, socket) do
    scope = Mount.scope(socket.assigns.samen_mount, socket.assigns.org_id)
    form = socket.assigns.kb_mount && KbReads.new_article_form(socket.assigns.kb_mount, scope)
    {:noreply, assign(socket, show_new: true, new_form: form)}
  end

  def handle_event("cancel_new", _params, socket), do: {:noreply, assign(socket, show_new: false)}

  def handle_event("validate_new", %{"form" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.new_form, with_org(params, socket))
    {:noreply, assign(socket, new_form: form)}
  end

  def handle_event("save_new", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.new_form, params: with_org(params, socket)) do
      {:ok, _article} -> {:noreply, socket |> assign(show_new: false) |> load(socket.assigns.org_id)}
      {:error, form} -> {:noreply, assign(socket, new_form: form)}
    end
  end

  def handle_event("edit_article", %{"id" => id}, socket) do
    {:noreply, socket |> assign(edit_id: id) |> refresh_edit()}
  end

  def handle_event("cancel_edit", _params, socket), do: {:noreply, assign(socket, edit_id: nil, edit_form: nil)}

  def handle_event("validate_edit", %{"form" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.edit_form, params)
    {:noreply, assign(socket, edit_form: form)}
  end

  def handle_event("save_edit", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.edit_form, params: params) do
      {:ok, _article} -> {:noreply, socket |> assign(edit_id: nil, edit_form: nil) |> load(socket.assigns.org_id)}
      {:error, form} -> {:noreply, assign(socket, edit_form: form)}
    end
  end

  # T78 done-criterion 1 write side: publish (admin-gated by the kernel — the
  # button is offered to any writable? actor, POSTURE only; a non-admin's
  # attempt is refused by the kernel and rendered inline, same split every
  # framework write event documents).
  def handle_event("publish", %{"id" => id}, socket) do
    case KbReads.publish_article(socket.assigns.kb_mount, socket.assigns.org_id, id) do
      {:ok, _} -> {:noreply, load(assign(socket, save_error: nil), socket.assigns.org_id)}
      {:error, _} -> {:noreply, assign(socket, save_error: "Could not publish this article (admin role required).")}
    end
  end

  defp with_org(params, socket), do: Map.put(params, "org_id", socket.assigns.org_id)

  defp ensure_return_to(socket) do
    if Map.has_key?(socket.assigns, :return_to), do: socket, else: assign(socket, return_to: nil)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="support-kb">
      <.app_shell>
        <:sidebar>
          <.support_sidebar mount={@samen_mount} org_id={@org_id} active={:support_kb} return_to={@return_to} />
        </:sidebar>

        <.topbar title="Knowledge base" crumbs={crumbs(@samen_mount, @org_id)}>
          <:actions>
            <.button :if={writable?(@samen_mount) and @kb_mount} variant="primary" phx-click="new_article" id="new-article">
              New article
            </.button>
          </:actions>
        </.topbar>

        <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

        <%= if @no_org do %>
          <.no_org_card mount={@samen_mount} />
        <% else %>
          <span id="org-banner" style="display:none">Support org: {@org_id}</span>

          <%= if @kb_mount == nil do %>
            <div class="wrap">
              <.empty_state
                class="kb-not-adopted"
                icon="📚"
                title="Knowledge base not set up."
                body="Wire the host's CMS namespace on the Support mount via the kb_namespace: label (e.g. kb_namespace: Driftwood.Cms) to enable the knowledge base here."
              />
            </div>
          <% else %>
            <div :if={@save_error} class="wrap" style="margin-bottom:0">
              <div class="card form-error" id="kb-save-error" style="padding:10px 14px;color:var(--bad, #b91c1c);font-size:12px">
                {@save_error}
              </div>
            </div>

            <div class="wrap">
              <div id="kb-articles">
                <div class="gtitle">
                  <h3>Articles</h3>
                  <span class="n">{length(@articles)}</span>
                </div>

                <%= if @articles == [] do %>
                  <.empty_state
                    class="kb-empty"
                    icon="📚"
                    title="No articles yet."
                    body="Author your first knowledge-base article — internal notes for agents, or public self-serve help."
                  >
                    <:actions :if={writable?(@samen_mount)}>
                      <.button variant="primary" phx-click="new_article" id="empty-new-article">New article</.button>
                    </:actions>
                  </.empty_state>
                <% else %>
                  <.data_table>
                    <:head>
                      <th>Title</th>
                      <th>Status</th>
                      <th>Visibility</th>
                      <th :if={writable?(@samen_mount)}><span class="sr-only">Actions</span></th>
                    </:head>
                    <tr :for={a <- @articles} class="kb-article-row" id={"kb-article-#{a.id}"}>
                      <td class="kb-title">
                        <a href="#" phx-click="edit_article" phx-value-id={a.id} style="font-weight:500;color:#3a3b45;text-decoration:none">
                          {a.title}
                        </a>
                      </td>
                      <td class="kb-status"><.pill variant={status_variant(a.status)}>{a.status}</.pill></td>
                      <td class="kb-visibility"><.pill variant={visibility_variant(a.visibility)}>{a.visibility}</.pill></td>
                      <td :if={writable?(@samen_mount)} class="kb-actions">
                        <.button :if={a.status != :published} phx-click="publish" phx-value-id={a.id} class="kb-publish-btn">Publish</.button>
                      </td>
                    </tr>
                  </.data_table>
                <% end %>
              </div>
            </div>

            <.modal :if={@show_new and @new_form != nil and writable?(@samen_mount)} id="new-article-modal" title="New article" on_cancel="cancel_new">
              <.article_form form={@new_form} on_change="validate_new" on_submit="save_new" on_cancel="cancel_new" submit_label="Save article" />
            </.modal>

            <.modal :if={@edit_id != nil and @edit_form != nil and writable?(@samen_mount)} id="edit-article-modal" title="Edit article" on_cancel="cancel_edit">
              <.article_form form={@edit_form} on_change="validate_edit" on_submit="save_edit" on_cancel="cancel_edit" submit_label="Save changes" />
            </.modal>
          <% end %>
        <% end %>
      </.app_shell>
    </div>
    """
  end

  attr :form, :any, required: true
  attr :on_change, :string, required: true
  attr :on_submit, :string, required: true
  attr :on_cancel, :string, required: true
  attr :submit_label, :string, required: true

  defp article_form(assigns) do
    ~H"""
    <.simple_form :let={f} for={@form} id="kb-article-form" phx-change={@on_change} phx-submit={@on_submit}>
      <.form_field field={f[:title]} label="Title" />
      <.form_field field={f[:body]} label="Body" type="textarea" rows="6" />
      <.form_field
        field={f[:visibility]}
        label="Visibility"
        type="select"
        options={[{"Internal (agents only)", "internal"}, {"Public (portal deflection)", "public"}]}
      />
      <:actions>
        <.button variant="primary" type="submit">{@submit_label}</.button>
        <.button type="button" phx-click={@on_cancel}>Cancel</.button>
      </:actions>
    </.simple_form>
    """
  end

  defp crumbs(mount, org_id), do: [CurrentOrg.name(mount, org_id), "Support", "Knowledge base"]

  defp status_variant(:draft), do: "mut"
  defp status_variant(:published), do: "ok"
  defp status_variant(:archived), do: "mut"
  defp status_variant(_), do: "mut"

  defp visibility_variant(:public), do: "info"
  defp visibility_variant(:internal), do: "mut"
  defp visibility_variant(_), do: "mut"
end
