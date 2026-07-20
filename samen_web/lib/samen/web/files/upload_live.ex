defmodule Samen.Web.Files.UploadLive do
  @moduledoc """
  Framework file UPLOAD LiveView (WS-E E2.1; ADR-026 §2 decision 2; AC-G14-1/7).
  Mounted at `/files` by `Samen.Web.Router.samen_files_routes/3`.

  ## Upload path — the ONLY governed create path

  `allow_upload/3` registers the LiveView upload entry; `consume_uploaded_entry/3`
  reads the consumed bytes and hands them (with filename + content_type) directly to
  `Samen.Files.upload/3` — the ONE governed chokepoint. The LiveView NEVER writes a
  `storage_key` directly; it never touches an Ash changeset for the `File` resource.

  This makes the following invariants structural rather than conventional:

    * Size/type limits (deny-by-default) run BEFORE `Storage.put/3` — the LiveView
      surfaces the resulting error honestly in the UI.
    * A fresh file lands `:quarantined` (the resource default; this LiveView never
      overrides it to `:active`).
    * The `file.uploaded` audit event is written by the chokepoint (token-only: status
      enum + ids, never filename or key).

  ## Error surfacing

  `{:error, {:content_type_not_allowed, _ct}}` → an inline validation error ("file
  type not permitted"). `{:error, {:too_large, _, max}}` → an inline size-exceeded
  error. All other `{:error, reason}` → a generic upload-failed flash. Errors are
  HONEST: a bad file is refused before any byte is stored; an upload that did not land
  is never reported as success.

  ## PII posture — write surface (not a preview surface)

  No PII is rendered here: the upload form shows no filename from storage. A subsequent
  visit to `PreviewLive` renders the filename through `PiiResolution` (ADR-026 §2
  decision 4). There is no masking invariant on the write surface itself — the filename
  a user types is their own plaintext input.

  ## Plane posture

  Upload affordances are offered on the tenant plane only (`Files.Live.writable?/1`).
  POSTURE only — the kernel's `ChokepointGuard` + governed create action enforce
  regardless of plane.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Files.Live, only: [assign_mount: 2, files_sidebar: 1, writable?: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount

  use Samen.Web.ListLive,
    resource: File,
    reads: &Samen.Web.Files.Reads.files_page/3,
    sortable: [:inserted_at, :status, :content_type],
    filter_fields: [:status, :content_type],
    default_sort: {:inserted_at, :desc}

  # Maximum allowed upload entries in a single request (the LiveView accept/size are
  # a UI hint; the hard enforcement is in Samen.Files.upload/3). Keep in sync with
  # the allowed_content_types in the host's config.
  @upload_ref :file_upload
  @max_file_size_bytes 26_214_400

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    org_id = CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)

    socket =
      socket
      # `upload_ref` is a CONSTANT the render reads (`@uploads[@upload_ref]`); assign it in
      # mount so the DISCONNECTED dead render (a JS-less host — the generated app ships no
      # asset pipeline, ADR-022) resolves it instead of raising `key :upload_ref not found`.
      # `@uploads` itself is supplied by `allow_upload/3` below on both the dead + live renders.
      |> assign(org_id: org_id, upload_result: nil, upload_error: nil, upload_ref: @upload_ref)
      |> allow_upload(@upload_ref,
        accept: :any,
        max_entries: 1,
        max_file_size: @max_file_size_bytes
      )
      |> load(org_id)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, uri, socket) do
    org_id = Map.get(params, "org") || socket.assigns.org_id

    socket =
      socket
      |> assign(org_id: org_id, return_to: return_path(uri), upload_result: nil, upload_error: nil)
      |> load(org_id)

    {:noreply, socket}
  end

  @doc false
  def load(socket, nil) do
    socket
    |> assign(no_org: no_org?(socket))
    |> assign(page: %Samen.Web.Page{}, list_state: %Samen.Web.ListState{})
  end

  def load(socket, org_id) do
    mount = socket.assigns.samen_mount
    scope = Mount.scope(mount, org_id)

    socket
    |> assign(no_org: false)
    |> init_list(mount, scope)
  end

  # -- events -------------------------------------------------------------------

  @impl true
  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("upload", _params, socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns

    if not writable?(mount) do
      {:noreply, assign(socket, upload_error: "upload not permitted on this plane")}
    else
      scope = Mount.scope(mount, org_id)
      # Resolve file_module + opts from the mount's host config. The chokepoint opts
      # win over config; we pass scope-derived values and let the engine read the rest
      # from config (file_module, storage, etc.). scope carries org_id for the create.
      upload_opts = [
        repo: mount.repo,
        # The host's file_module is wired in app config by the operator; the engine
        # reads it from config. Passing it explicitly here would hardcode a module —
        # let the engine's opt/config resolution do its job.
      ]

      results =
        consume_uploaded_entries(socket, @upload_ref, fn %{path: tmp_path}, entry ->
          case Elixir.File.read(tmp_path) do
            {:ok, binary} ->
              payload = %{
                filename: entry.client_name,
                content_type: entry.client_type,
                binary: binary
              }

              Samen.Files.upload(scope, payload, upload_opts)

            {:error, reason} ->
              {:error, reason}
          end
        end)

      case results do
        [{:ok, file}] ->
          {:noreply,
           socket
           |> assign(upload_result: file, upload_error: nil)
           |> load(org_id)}

        [{:error, {:content_type_not_allowed, ct}}] ->
          {:noreply, assign(socket, upload_error: "file type not permitted: #{ct}", upload_result: nil)}

        [{:error, {:too_large, _size, max}}] ->
          max_mb = div(max, 1_048_576)
          {:noreply, assign(socket, upload_error: "file exceeds the #{max_mb} MB size limit", upload_result: nil)}

        [{:error, reason}] ->
          {:noreply, assign(socket, upload_error: "upload failed: #{inspect(reason)}", upload_result: nil)}

        _ ->
          {:noreply, assign(socket, upload_error: "no file selected", upload_result: nil)}
      end
    end
  end

  # -- render -------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div id="files-upload">
      <.app_shell>
        <:sidebar>
          <.files_sidebar mount={@samen_mount} org_id={@org_id} active={:files} return_to={@return_to} />
        </:sidebar>

        <.topbar title="Files" crumbs={crumbs(@samen_mount, @org_id)}>
          <:actions></:actions>
        </.topbar>

        <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

        <%= if @no_org do %>
          <.no_org_card mount={@samen_mount} />
        <% else %>
          <span id="org-banner" style="display:none">Files org: {@org_id}</span>

          <div class="wrap">
            <div id="files-upload-panel">
              <div class="gtitle">
                <h3>Upload a file</h3>
                <span class="lane">files are held in quarantine until scanned</span>
              </div>

              <%= if writable?(@samen_mount) do %>
                <form id="upload-form" phx-submit="upload" phx-change="validate">
                  <.live_file_input upload={@uploads[@upload_ref]} id="upload-input" />

                  <.button
                    type="submit"
                    variant="primary"
                    id="upload-submit"
                    disabled={Enum.empty?(@uploads[@upload_ref].entries)}
                  >
                    Upload
                  </.button>
                </form>

                <%= if @upload_error do %>
                  <p id="upload-error" style="color:#B91C1C;margin-top:8px">{@upload_error}</p>
                <% end %>

                <%= if @upload_result do %>
                  <p id="upload-success" style="color:#15803D;margin-top:8px">
                    Uploaded — file is <strong>quarantined</strong> pending scan (id: {@upload_result.id}).
                  </p>
                <% end %>
              <% end %>
            </div>

            <div id="files-list-panel" style="margin-top:24px">
              <div class="gtitle">
                <h3>Files</h3>
                <span class="lane">status · via PiiResolution · {plane_note(@samen_mount)}</span>
              </div>
              <.list_view
                id="files"
                page={@page}
                state={@list_state}
                row_class="file-row"
                filter_placeholder="Filter by status or content type…"
                empty_text="No files yet."
                empty_icon="⊡"
                empty_body="Upload a file above. All new files are quarantined until a scanner promotes them."
              >
                <:head>
                  <th scope="col" style="width:36%">Filename</th>
                  <th scope="col" style="width:16%">Type</th>
                  <.sort_header field={:status} label="Status" sort={@list_state.sort} width="12%" />
                  <th scope="col" style="width:12%">Size</th>
                  <.sort_header field={:inserted_at} label="Uploaded" sort={@list_state.sort} width="16%" />
                  <th scope="col" style="width:8%"><span class="sr-only">Actions</span></th>
                </:head>
                <:row :let={f}>
                  <td class="f-name">{f.filename || "—"}</td>
                  <td class="f-type" style="font-size:12px;color:var(--muted)">{f.content_type || "—"}</td>
                  <td class="f-status">
                    <span class={"status-pill status-#{f.status}"}>{f.status}</span>
                  </td>
                  <td class="f-size" style="font-size:12px;color:var(--muted)">{format_bytes(f.size_bytes)}</td>
                  <td class="f-uploaded" style="font-size:12px;color:var(--muted)">{uploaded_at(f)}</td>
                  <td class="f-actions">
                    <.link :if={f.status == :active} navigate={"/files/#{f.id}"} id={"preview-#{f.id}"}>
                      Preview
                    </.link>
                  </td>
                </:row>
              </.list_view>
            </div>
          </div>
        <% end %>
      </.app_shell>
    </div>
    """
  end

  # -- private ------------------------------------------------------------------

  defp no_org?(socket), do: CurrentOrg.no_org?(socket.assigns[:samen_mount], nil)

  defp crumbs(mount, org_id), do: [CurrentOrg.name(mount, org_id), "Files"]

  defp plane_note(%Mount{plane: %{kind: :operator}}), do: "operator plane · masked"
  defp plane_note(_), do: "your org in the clear"

  defp format_bytes(nil), do: "—"
  defp format_bytes(n) when n < 1_024, do: "#{n} B"
  defp format_bytes(n) when n < 1_048_576, do: "#{div(n, 1_024)} KB"
  defp format_bytes(n), do: "#{div(n, 1_048_576)} MB"

  defp uploaded_at(%{inserted_at: %DateTime{} = at}),
    do: Calendar.strftime(at, "%Y-%m-%d %H:%M")

  defp uploaded_at(_), do: "—"
end
