defmodule Samen.Web.Csv.ImportLive do
  @moduledoc """
  Framework CSV IMPORT LiveView (WS-E E3.4; ADR-028; AC-G15-1/3/5). Mounted at
  `/csv/import/:resource` by `Samen.Web.Router.samen_csv_routes/3`.

  ## Import path — the governed chokepoint in a loop

  `allow_upload/3` receives the file; the consumed bytes go straight to
  `Samen.Web.Csv.import/3`, which sends EVERY row through the resource's governed
  create action (`WriteGuard` + `Vault.Change`) under the acting scope. This
  LiveView never builds a changeset and never touches the vault — it renders the
  per-row `%Report{}` honestly: created count, and each failed row with its error.

  A bad column mapping (`org_id`/`id`/unknown) fails the WHOLE file before any
  write (AC-G15-5) and is surfaced as the import error.

  ## Plane posture

  Import affordances are offered on the tenant plane only (same A3 posture as
  files upload). POSTURE only — an operator-plane import would be refused
  row-by-row by the kernel guards regardless.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.Csv
  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount

  @upload_ref :csv_upload
  @max_csv_bytes 5_242_880

  @impl true
  def mount(params, session, socket) do
    socket = Samen.Web.Live.assign_mount(socket, session)
    org_id = CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)

    socket =
      socket
      |> assign(
        org_id: org_id,
        resource_name: nil,
        report: nil,
        import_error: nil,
        return_to: nil
      )
      |> allow_upload(@upload_ref, accept: ~w(.csv text/csv), max_entries: 1, max_file_size: @max_csv_bytes)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, uri, socket) do
    org_id = Map.get(params, "org") || socket.assigns.org_id

    {:noreply,
     assign(socket,
       org_id: org_id,
       resource_name: Map.get(params, "resource"),
       return_to: return_path(uri),
       report: nil,
       import_error: nil
     )}
  end

  # -- events -------------------------------------------------------------------

  @impl true
  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("import", _params, socket) do
    %{samen_mount: mount, org_id: org_id, resource_name: name} = socket.assigns

    with true <- writable?(mount) || {:error, :plane},
         {:ok, resource} <- Csv.resolve_resource(mount, name || "") do
      scope = Mount.scope(mount, org_id)

      result =
        socket
        |> consume_uploaded_entries(@upload_ref, fn %{path: tmp_path}, _entry ->
          {:ok, Elixir.File.read(tmp_path)}
        end)
        |> case do
          [{:ok, binary}] -> Csv.import(resource, scope, csv: binary)
          _ -> {:error, :no_file}
        end

      case result do
        {:ok, report} ->
          {:noreply, assign(socket, report: report, import_error: nil)}

        {:error, {:bad_mapping, cols}} ->
          {:noreply,
           assign(socket,
             report: nil,
             import_error: "rejected: column(s) not importable: #{Enum.join(cols, ", ")}"
           )}

        {:error, reason} ->
          {:noreply, assign(socket, report: nil, import_error: "import failed: #{inspect(reason)}")}
      end
    else
      {:error, :plane} ->
        {:noreply, assign(socket, import_error: "import not permitted on this plane")}

      {:error, :unknown_resource} ->
        {:noreply, assign(socket, import_error: "unknown resource")}
    end
  end

  # -- render -------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div id="csv-import">
      <.app_shell>
        <:sidebar></:sidebar>

        <.topbar title={"Import #{@resource_name} CSV"} crumbs={[CurrentOrg.name(@samen_mount, @org_id), "Import"]}>
          <:actions></:actions>
        </.topbar>

        <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

        <%= if CurrentOrg.no_org?(@samen_mount, nil) and is_nil(@org_id) do %>
          <.no_org_card mount={@samen_mount} />
        <% else %>
          <div class="wrap">
            <div id="csv-import-panel">
              <div class="gtitle">
                <h3>Import {@resource_name} rows</h3>
                <span class="lane">every row through the governed create — bad mappings are rejected whole-file</span>
              </div>

              <%= if writable?(@samen_mount) do %>
                <form id="csv-import-form" phx-submit="import" phx-change="validate">
                  <.live_file_input upload={@uploads.csv_upload} id="csv-import-input" />

                  <.button
                    type="submit"
                    variant="primary"
                    id="csv-import-submit"
                    disabled={Enum.empty?(@uploads.csv_upload.entries)}
                  >
                    Import
                  </.button>
                </form>
              <% else %>
                <p id="csv-import-refused" style="color:var(--muted)">
                  Import is a tenant-plane action.
                </p>
              <% end %>

              <%= if @import_error do %>
                <p id="csv-import-error" style="color:#B91C1C;margin-top:8px">{@import_error}</p>
              <% end %>

              <%= if @report do %>
                <div id="csv-import-report" style="margin-top:12px">
                  <p id="csv-import-created" style="color:#15803D">
                    Imported <strong>{@report.created}</strong> of {@report.total} row(s).
                  </p>
                  <%= if @report.errors != [] do %>
                    <table id="csv-import-errors" class="tbl" style="margin-top:8px">
                      <thead>
                        <tr>
                          <th scope="col" style="width:12%">Row</th>
                          <th scope="col">Error</th>
                        </tr>
                      </thead>
                      <tbody>
                        <tr :for={e <- @report.errors} class="csv-error-row">
                          <td>{e.row}</td>
                          <td style="font-size:12px;color:var(--muted)">{e.error}</td>
                        </tr>
                      </tbody>
                    </table>
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>
      </.app_shell>
    </div>
    """
  end

  # -- private ------------------------------------------------------------------

  defp writable?(%Mount{plane: %{kind: :operator}}), do: false
  defp writable?(_), do: true
end
