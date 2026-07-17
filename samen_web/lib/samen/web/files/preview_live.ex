defmodule Samen.Web.Files.PreviewLive do
  @moduledoc """
  Framework file PREVIEW LiveView (WS-E E2.1; ADR-026 §2 decision 4; AC-G14-5/7).
  Mounted at `/files/:id` by `Samen.Web.Router.samen_files_routes/3`.

  ## Masking — the file preview PII surface (AC-G14-5, RP-FI-4)

  File preview is a new PII render surface on the masking watch-list (ADR-026 §2 d4):

    * `filename` is rendered through `Samen.Api.PiiResolution` on the actor's plane.
      An operator-without-grant sees `••••`; a tenant sees the filename in the clear.
    * **Byte view (image/text inline preview)** is plane-gated and quarantine-gated:
      — a `:quarantined` file: preview REFUSED (`previewable?/1` is false).
      — an `:active` file on the operator plane: byte download REFUSED (an operator
        cannot pull a tenant's raw bytes without a reveal grant — bytes have no partial
        `%Masked{}` representation; the request is refused, not masked).
      — an `:active` file on the tenant plane: byte view is shown inline for images
        and text types (fetched through the `/files/:id/bytes` byte-serve route, which
        enforces the same quarantine + plane gate independently).

  ## Anti-tautology (RP-FI-4)

  Sabotaging the plane check (serving the filename or bytes on the operator plane)
  FAILS the corresponding red-path tests. The masking is BY CONSTRUCTION — the
  `filename` field passes through `PiiResolution`; the byte-view link targets the
  byte-serve route which re-enforces the gate server-side.

  ## Render-only

  This LiveView performs NO writes. It reads the file metadata through `Reads.get_file/3`
  (org-scoped, plane-resolved) and renders. The `/files/:id/bytes` byte-serve route (a separate
  controller) handles byte delivery.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Files.Live, only: [assign_mount: 2, files_sidebar: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, return_path: 1]

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Files.Reads
  alias Samen.Web.Mount

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    org_id = CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)
    file_id = Map.get(params, "id")

    {:ok, assign(socket, org_id: org_id, file_id: file_id, file: nil, not_found: false)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    org_id = Map.get(params, "org") || socket.assigns.org_id
    file_id = Map.get(params, "id")
    mount = socket.assigns.samen_mount
    scope = Mount.scope(mount, org_id)

    socket =
      socket
      |> assign(org_id: org_id, file_id: file_id, return_to: return_path(uri))
      |> load_file(mount, scope, file_id)

    {:noreply, socket}
  end

  @doc false
  def load(socket, org_id, file_id) do
    mount = socket.assigns.samen_mount
    scope = Mount.scope(mount, org_id)
    load_file(assign(socket, org_id: org_id, file_id: file_id), mount, scope, file_id)
  end

  # -- render ------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div id="files-preview">
      <.app_shell>
        <:sidebar>
          <.files_sidebar mount={@samen_mount} org_id={@org_id} active={:files} return_to={@return_to} />
        </:sidebar>

        <.topbar title="File Preview" crumbs={crumbs(@samen_mount, @org_id, @file)}>
          <:actions></:actions>
        </.topbar>

        <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

        <%= if @not_found do %>
          <div id="file-not-found" class="empty-state">
            <p>File not found or not accessible.</p>
          </div>
        <% else %>
          <span id="org-banner" style="display:none">Files org: {@org_id}</span>
          <div class="wrap">
            <div id="file-preview-panel">
              <%= if @file do %>
                <div class="gtitle">
                  <h3 id="file-name">{@file.filename}</h3>
                  <span class="lane">{plane_note(@samen_mount)}</span>
                </div>

                <dl id="file-metadata" style="margin:16px 0">
                  <dt>Status</dt>
                  <dd>
                    <span class={"status-pill status-#{@file.status}"} id="file-status">{@file.status}</span>
                  </dd>
                  <dt>Content type</dt>
                  <dd id="file-content-type">{@file.content_type || "—"}</dd>
                  <dt>Size</dt>
                  <dd id="file-size">{format_bytes(@file.size_bytes)}</dd>
                  <dt>Uploaded</dt>
                  <dd id="file-uploaded">{uploaded_at(@file)}</dd>
                </dl>

                <%= cond do %>
                  <% @file.status == :quarantined -> %>
                    <div id="preview-quarantined" style="border:1px solid #F59E0B;padding:12px;border-radius:6px;margin-top:16px">
                      <strong>Quarantined</strong> — this file is held pending a virus scan.
                      Preview and download are refused until the file is promoted to :active.
                    </div>

                  <% operator_plane?(@samen_mount) -> %>
                    <div id="preview-operator-refused" style="border:1px solid #B91C1C;padding:12px;border-radius:6px;margin-top:16px">
                      Byte download refused on the operator plane — bytes have no partial reveal
                      representation. To view the file, use the tenant plane.
                    </div>

                  <% true -> %>
                    <div id="preview-byte-view" style="margin-top:16px">
                      <%= if previewable_image?(@file) do %>
                        <img
                          src={"/files/#{@file.id}/bytes"}
                          id="preview-image"
                          alt={@file.filename}
                          style="max-width:100%;border-radius:4px"
                        />
                      <% end %>
                      <%= if previewable_text?(@file) do %>
                        <pre id="preview-text-link" style="font-size:12px">
                          <a href={"/files/#{@file.id}/bytes"} target="_blank" id="download-link">
                            Download / view raw text
                          </a>
                        </pre>
                      <% end %>
                      <%= if not previewable_image?(@file) and not previewable_text?(@file) do %>
                        <a href={"/files/#{@file.id}/bytes"} target="_blank" id="download-link">
                          Download file
                        </a>
                      <% end %>
                    </div>
                <% end %>
              <% end %>
            </div>
          </div>
        <% end %>
      </.app_shell>
    </div>
    """
  end

  # -- private -----------------------------------------------------------------

  defp load_file(socket, _mount, _scope, nil), do: assign(socket, file: nil, not_found: true)

  defp load_file(socket, mount, scope, file_id) do
    case Reads.get_file(mount, scope, file_id) do
      {:ok, file} -> assign(socket, file: file, not_found: false)
      {:error, _} -> assign(socket, file: nil, not_found: true)
    end
  end

  defp crumbs(mount, org_id, nil),
    do: [CurrentOrg.name(mount, org_id), "Files", "Preview"]

  defp crumbs(mount, org_id, file) do
    name = if is_struct(file.filename, Samen.Masked), do: "••••", else: (file.filename || "File")
    [CurrentOrg.name(mount, org_id), "Files", name]
  end

  defp plane_note(%Mount{plane: %{kind: :operator}}), do: "operator plane · filename masked"
  defp plane_note(_), do: "your org · filename in the clear"

  defp operator_plane?(%Mount{plane: %{kind: :operator}}), do: true
  defp operator_plane?(_), do: false

  # Byte-view inline preview — only safe on tenant plane AND :active status.
  # The byte-serve route re-enforces the gate; these helpers only control the UI link.
  defp previewable_image?(%{content_type: ct}) when is_binary(ct),
    do: String.starts_with?(ct, "image/")

  defp previewable_image?(_), do: false

  defp previewable_text?(%{content_type: ct}) when is_binary(ct),
    do: String.starts_with?(ct, "text/")

  defp previewable_text?(_), do: false

  defp format_bytes(nil), do: "—"
  defp format_bytes(n) when n < 1_024, do: "#{n} B"
  defp format_bytes(n) when n < 1_048_576, do: "#{div(n, 1_024)} KB"
  defp format_bytes(n), do: "#{div(n, 1_048_576)} MB"

  defp uploaded_at(%{inserted_at: %DateTime{} = at}),
    do: Calendar.strftime(at, "%Y-%m-%d %H:%M")

  defp uploaded_at(_), do: "—"
end
