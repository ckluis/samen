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
  alias Samen.Web.TenantActor
  require TenantActor
  import Samen.Web.TenantActor, only: [writable?: 2]
  import Samen.Web.TenantActor.Components, only: [actor_refused: 1]

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
      |> resolve_actor(org_id)
      |> allow_upload(@upload_ref, accept: ~w(.csv text/csv), max_entries: 1, max_file_size: @max_csv_bytes)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, uri, socket) do
    org_id = Samen.Web.CurrentOrg.reresolve(socket, params)

    {:noreply,
     socket
     |> assign(
       org_id: org_id,
       resource_name: Map.get(params, "resource"),
       return_to: return_path(uri),
       report: nil,
       import_error: nil
     )
     |> resolve_actor(org_id)}
  end

  # ADR-045 §4.4 — WHO imports: the signed-in person's resolved membership role (`Samen.Web.TenantActor`), never
  # `Mount.scope/2`'s fixed `:member`: the import is a governed create per row, so the person's role is what each row
  # is judged by. A denial or a failed lookup is a STATE of the page (re-resolved on every `handle_params`): no form,
  # and an `import` event is a no-op. With no org there is nobody to resolve (`acting_scope` nil: refused as well).
  defp resolve_actor(socket, nil), do: assign(socket, acting_scope: nil, actor_state: :ok)

  defp resolve_actor(socket, org_id) do
    {_status, socket} = TenantActor.assign_actor(socket, org_id)
    socket
  end

  # -- events -------------------------------------------------------------------

  @impl true
  TenantActor.refuse_events()

  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("import", _params, socket) do
    binary =
      case consume_uploaded_entries(socket, @upload_ref, fn %{path: tmp_path}, _entry -> {:ok, Elixir.File.read(tmp_path)} end) do
        [{:ok, binary}] -> binary
        _ -> nil
      end

    {:noreply, import_rows(socket, binary)}
  end

  @doc """
  Import the consumed upload's bytes (`nil` when there was no file) through the governed create, as the person the page
  resolved (`acting_scope`), and return the socket with the report or the error assigned. This is what the `import`
  event runs; it is public so the write path is driven directly (a test socket has no upload to consume).
  """
  def import_rows(socket, binary) do
    %{samen_mount: mount, resource_name: name, acting_scope: scope} = socket.assigns

    with true <- not is_nil(scope) || {:error, :plane},
         true <- writable?(mount) || {:error, :plane},
         {:ok, resource} <- Csv.resolve_resource(mount, name || "") do
      result =
        case binary do
          nil -> {:error, :no_file}
          binary -> Csv.import(resource, scope, csv: binary)
        end

      case result do
        {:ok, report} ->
          assign(socket, report: report, import_error: nil)

        {:error, {:bad_mapping, cols}} ->
          assign(socket,
            report: nil,
            import_error: "rejected: column(s) not importable: #{Enum.join(cols, ", ")}"
          )

        {:error, reason} ->
          assign(socket, report: nil, import_error: "import failed: #{inspect(reason)}")
      end
    else
      {:error, :plane} -> assign(socket, import_error: "import not permitted on this plane")
      {:error, :unknown_resource} -> assign(socket, import_error: "unknown resource")
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

        <%= cond do %>
        <% CurrentOrg.no_org?(@samen_mount, nil) and is_nil(@org_id) -> %>
          <.no_org_card mount={@samen_mount} />
        <% @actor_state in [:denied, :unavailable] -> %>
          <.actor_refused state={@actor_state} title="Import" nothing="there is nothing to import into" />
        <% true -> %>
          <div class="wrap">
            <div id="csv-import-panel">
              <div class="gtitle">
                <h3>Import {@resource_name} rows</h3>
                <span class="lane">every row through the governed create — bad mappings are rejected whole-file</span>
              </div>

              <%= if writable?(@samen_mount, @acting_scope) do %>
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
                  <%= if @report.stopped do %>
                    <p id="csv-import-stopped" role="alert" style="color:#B91C1C;margin-top:8px">
                      The import stopped at row {@report.stopped.at_row} because we couldn't save right now.
                      {@report.created} of {@report.total} row(s) were imported before it stopped; row
                      {@report.stopped.at_row} and the rows after it were not attempted. Try again with
                      only those rows — re-uploading the whole file would import the first
                      {@report.created} again.
                    </p>
                  <% end %>
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
