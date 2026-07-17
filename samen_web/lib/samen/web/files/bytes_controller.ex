defmodule Samen.Web.Files.BytesController do
  @moduledoc """
  Framework `/files/:id` byte-serve route (WS-E E2.1; ADR-026 §2 decisions 3+4;
  AC-G14-4/5/7).

  This is the ONLY byte-delivery path. Before serving a single byte it enforces:

    1. **Org-scope** — the file id is looked up through the mount's namespace +
       OrgScope. A cross-org id reads zero rows and returns 404 (no existence oracle).

    2. **Quarantine gate** — `Samen.Files.previewable?/1` must be `true` (`:active`
       only). A `:quarantined`, `:archived`, or `:deleted` file returns 403 and the
       body `"quarantined"`. Serving a quarantined file's bytes would undermine the
       fail-closed scanner posture (RP-FI-3, ADR-026 §2 decision 3).

    3. **Plane gate** — the operator plane is refused (403 + body `"operator-refused"`).
       Bytes have no `%Masked{}` partial-reveal representation; an operator reading a
       tenant's raw bytes without an explicit reveal grant is refused outright (ADR-026
       §2 decision 4 / RP-FI-4). The masking invariant is enforced here independently
       of the PreviewLive UI posture.

    4. **`Samen.Files.fetch_bytes/3`** — reads through the configured storage adapter
       (fail-honest: an unconfigured adapter returns `{:error, :not_configured}`,
       never `{:ok, _}`). A storage error → 500.

  ## Mount / session

  The mount is read from `conn.assigns[:samen_mount]` (populated by the host's
  `live_session` plug chain — the same mount the LiveViews receive). The `org_id` is
  resolved from the session via `Samen.Web.CurrentOrg.resolve/3` so the byte-serve
  route participates in the SAME org-scoping as the LiveViews.

  The route is mounted by `Samen.Web.Router.samen_files_routes/3` as
  `GET /<path>/:id` → `Samen.Web.Files.BytesController, :serve`. A host's
  `:browser` pipeline plug chain (including the session plug) must wrap this route.
  """
  use Phoenix.Controller, formats: [:html]

  import Plug.Conn

  alias Samen.Files
  alias Samen.Web.CurrentOrg
  alias Samen.Web.Files.Reads
  alias Samen.Web.Mount

  @doc """
  Serve the bytes for the file identified by `:id`, enforcing org-scope, quarantine,
  plane, and storage integrity in order.
  """
  def serve(conn, params) do
    file_id = Map.get(params, "id")
    mount = conn.assigns[:samen_mount]
    session = get_session(conn)
    org_id = CurrentOrg.resolve(mount, params, session)

    serve_bytes(conn, mount, org_id, file_id)
  end

  # -- private -----------------------------------------------------------------

  defp serve_bytes(conn, nil, _org_id, _file_id) do
    conn |> put_status(503) |> text("no mount")
  end

  defp serve_bytes(conn, _mount, nil, _file_id) do
    conn |> put_status(404) |> text("no org")
  end

  defp serve_bytes(conn, mount, org_id, file_id) do
    scope = Mount.scope(mount, org_id)

    # Plane gate: bytes have no %Masked{} partial-reveal; operator is refused outright.
    if operator_plane?(mount) do
      conn |> put_status(403) |> text("operator-refused")
    else
      case Reads.get_file(mount, scope, file_id) do
        {:error, :not_found} ->
          conn |> put_status(404) |> text("not found")

        {:ok, file} ->
          # Quarantine gate: refused unless :active (RP-FI-3).
          if not Files.previewable?(file) do
            conn |> put_status(403) |> text("quarantined")
          else
            serve_active_file(conn, mount, scope, file)
          end
      end
    end
  end

  defp serve_active_file(conn, _mount, _scope, file) do
    # Resolve storage opts from host config (same seam as Samen.Files.upload/3).
    storage = files_config(:storage) || Samen.Files.Storage.Local
    storage_config = files_config(:storage_config) || %{}

    case Files.fetch_bytes(%{org_id: file.org_id}, file,
           storage: storage,
           storage_config: storage_config
         ) do
      {:ok, binary} ->
        content_type = content_type(file)

        conn
        |> put_resp_content_type(content_type)
        |> put_resp_header(
          "content-disposition",
          ~s(inline; filename="#{safe_filename(file)}")
        )
        |> send_resp(200, binary)

      {:error, :not_previewable} ->
        # Defensive: quarantine gate above should catch this first.
        conn |> put_status(403) |> text("quarantined")

      {:error, reason} ->
        conn |> put_status(500) |> text("storage error: #{inspect(reason)}")
    end
  end

  defp operator_plane?(%Mount{plane: %{kind: :operator}}), do: true
  defp operator_plane?(_), do: false

  defp content_type(%{content_type: ct}) when is_binary(ct) and ct != "", do: ct
  defp content_type(_), do: "application/octet-stream"

  # Resolve the raw filename for the Content-Disposition header. A %Masked{} here
  # should not happen (we've already confirmed tenant plane), but guard defensively —
  # use a generic name rather than leaking a vault token. A raw binary is used directly.
  defp safe_filename(%{filename: %Samen.Masked{}}), do: "file"
  defp safe_filename(%{filename: name}) when is_binary(name), do: String.replace(name, ~r/[^\w.\-]/, "_")
  defp safe_filename(_), do: "file"

  defp files_config(key), do: Application.get_env(:samen_core, Samen.Files, [])[key]
end
