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

    4. **Audit** — a download is recorded (actor, org, file id, byte size) BEFORE the bytes are sent, and one whose
       line cannot be written is a 503 that sends nothing; refusals (403) are recorded too (`Samen.Web.AccessAudit`).

    5. **`Samen.Files.fetch_bytes/3`** — reads through the configured storage adapter
       (fail-honest: an unconfigured adapter returns `{:error, :not_configured}`,
       never `{:ok, _}`). A storage error → 500.

  ## Mount / session

  The mount is read from `conn.assigns[:samen_mount]`, which the route itself sets
  (`Samen.Web.Router.samen_files_routes/3` emits `assigns: %{samen_mount: mount}`, as the ICS
  route does): no host pipeline sets it, and without it every request is a 503 "no mount". The `org_id` is
  resolved from the session via `Samen.Web.CurrentOrg.resolve/3` so the byte-serve
  route participates in the SAME org-scoping as the LiveViews.

  The route is mounted by `Samen.Web.Router.samen_files_routes/3` as
  `GET /<path>/:id/bytes` → `Samen.Web.Files.BytesController, :serve`. A host's
  `:browser` pipeline plug chain (including the session plug) must wrap this route.
  The route is driven through a real router in `Samen.Web.FilesCsvRouterTest`.
  """
  use Phoenix.Controller, formats: [:html]

  import Plug.Conn

  require Logger

  alias Samen.Files
  alias Samen.Web.AccessAudit
  alias Samen.Web.CurrentOrg
  alias Samen.Web.Files.Reads
  alias Samen.Web.Mount
  alias Samen.Web.TenantActor

  @doc """
  Serve the bytes for the file identified by `:id`, enforcing org-scope, quarantine,
  plane, and storage integrity in order.
  """
  def serve(conn, params) do
    file_id = Map.get(params, "id")
    mount = conn.assigns[:samen_mount]
    session = get_session(conn)
    org_id = CurrentOrg.resolve(mount, params, session)

    # WHO reads: the signed-in person's resolved membership role (`Samen.Web.TenantActor`), not
    # `Mount.scope/2`'s fixed `:member`. Denied -> 403, a failed lookup -> 503; never a default role.
    ref = TenantActor.conn_ref(mount, params, session)
    actor = TenantActor.scope(mount, org_id, ref)

    serve_bytes(conn, mount, org_id, file_id, actor, ref)
  end

  # -- private -----------------------------------------------------------------

  # Only a well-formed id is recorded as the subject (it is client input until a read has found the file).
  defp audit_refusal(mount, org_id, file_id, actor_id, outcome) do
    subject = if match?({:ok, _}, Ecto.UUID.cast(file_id)), do: file_id

    AccessAudit.record_refusal(mount, :file_download, org_id, %{actor_id: actor_id, subject_id: subject, outcome: outcome})
  end

  defp ref_id({kind, id}) when kind in [:credential, :user, :dev] and is_binary(id), do: id
  defp ref_id(_), do: nil

  defp serve_bytes(conn, nil, _org_id, _file_id, _actor, _ref) do
    conn |> put_status(503) |> text("no mount")
  end

  defp serve_bytes(conn, _mount, nil, _file_id, _actor, _ref) do
    conn |> put_status(404) |> text("no org")
  end

  defp serve_bytes(conn, mount, org_id, file_id, :denied, ref) do
    audit_refusal(mount, org_id, file_id, ref_id(ref), :denied)
    conn |> put_status(403) |> text("no access")
  end

  defp serve_bytes(conn, _mount, _org_id, _file_id, {:error, :unavailable}, _ref),
    do: conn |> put_status(503) |> text("unavailable")

  defp serve_bytes(conn, mount, org_id, file_id, {:ok, scope}, _ref) do
    conn = assign(conn, :samen_acting_role, scope.actor.role)

    # Plane gate: bytes have no %Masked{} partial-reveal; operator is refused outright.
    if operator_plane?(mount) do
      audit_refusal(mount, org_id, file_id, scope.actor.id, :operator_refused)
      conn |> put_status(403) |> text("operator-refused")
    else
      case Reads.get_file_result(mount, scope, file_id) do
        {:error, :not_found} ->
          conn |> put_status(404) |> text("not found")

        # A failed read is a 503 (retryable), never a 404.
        {:error, :unavailable} ->
          conn |> put_status(503) |> text("unavailable")

        {:ok, file} ->
          # Quarantine gate: refused unless :active (RP-FI-3).
          if not Files.previewable?(file) do
            audit_refusal(mount, org_id, file_id, scope.actor.id, :quarantined)
            conn |> put_status(403) |> text("quarantined")
          else
            serve_active_file(conn, mount, org_id, scope, file)
          end
      end
    end
  end

  defp serve_active_file(conn, mount, org_id, scope, file) do
    # Resolve storage opts from host config (same seam as Samen.Files.upload/3).
    storage = files_config(:storage) || Samen.Files.Storage.Local
    storage_config = files_config(:storage_config) || %{}

    case Files.fetch_bytes(%{org_id: file.org_id}, file,
           storage: storage,
           storage_config: storage_config
         ) do
      {:ok, binary} ->
        content_type = content_type(file)

        # The delivery is gated on its audit line: bytes whose download could not be recorded are not sent.
        case AccessAudit.record(mount, :file_download, org_id, %{
               actor_id: scope.actor.id,
               subject_id: file.id,
               bytes: byte_size(binary),
               outcome: :ok
             }) do
          :ok ->
            conn
            |> put_resp_content_type(content_type)
            |> put_resp_header("x-content-type-options", "nosniff")
            |> put_disposition(content_type, file)
            |> send_resp(200, binary)

          {:error, :audit_unavailable} ->
            conn |> put_status(503) |> text("unavailable")
        end

      {:error, :not_previewable} ->
        # Defensive: quarantine gate above should catch this first.
        conn |> put_status(403) |> text("quarantined")

      {:error, reason} ->
        # The body is fixed, value-free copy: a storage reason can carry a path, a key or a bucket.
        # The kind (atom / exception module) is logged for the operator; nothing else.
        Logger.error("[Samen.Web.Files] storage read failed kind=#{reason_kind(reason)}")
        conn |> put_status(500) |> text("storage error")
    end
  end

  # The bytes are an UPLOAD: its content type is whatever the host allowed through `Samen.Files.upload/3`, and
  # this route serves it from the app's own origin. So it never sniffs (`nosniff`), and only the types a browser
  # renders without running script (`@inline_types`) are shown inline; everything else (an HTML upload, an SVG)
  # is an attachment under a `sandbox` CSP, so it can neither run as a page on this origin nor be framed.
  # (The sandbox CSP is not put on the inline types: it would stop a browser's PDF viewer.)
  @inline_types ~w(image/png image/jpeg image/gif image/webp application/pdf text/plain)

  defp put_disposition(conn, content_type, file) do
    base = content_type |> String.split(";") |> hd() |> String.trim() |> String.downcase()
    name = safe_filename(file)

    if base in @inline_types do
      put_resp_header(conn, "content-disposition", ~s(inline; filename="#{name}"))
    else
      conn
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{name}"))
      |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
    end
  end

  defp reason_kind(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_kind(%{__struct__: module}), do: inspect(module)
  defp reason_kind(reason) when is_tuple(reason) and tuple_size(reason) > 0 and is_atom(elem(reason, 0)), do: Atom.to_string(elem(reason, 0))
  defp reason_kind(_reason), do: "other"

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
