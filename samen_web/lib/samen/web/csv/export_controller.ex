defmodule Samen.Web.Csv.ExportController do
  @moduledoc """
  Framework `/csv/export/:resource` download route (WS-E E3.4; ADR-028; AC-G15-1).

  The ONLY CSV byte-delivery path. Before serving:

    1. **Resource allowlist (deny-by-default)** — `:resource` resolves through
       `Samen.Web.Csv.resolve_resource/2`: the name must be a resource OF the
       mounted namespace's domain. Anything else is 404 — no module minting, no
       existence oracle.

    2. **Org-scope** — the org comes from the session (`Samen.Web.CurrentOrg`),
       the scope from the mount's plane. Rows are read org-scoped and keyset-
       bounded (`Csv.export/3` → `Reads.page!/3`; AC-G15-4).

    3. **Masking (AC-G15-2)** — there is NO plane gate here and none is needed:
       export is safe on EVERY plane because each cell is resolved through
       `PiiResolution` on the acting plane. An operator downloads a CSV whose
       vaulted cells are `••••` — the same pixels the UI shows. Refusing the
       download would be posture; masking the cells is the guarantee.

  Mount/session posture mirrors `Samen.Web.Files.BytesController`: mount from
  `conn.assigns[:samen_mount]` (set by the route: `samen_csv_routes/3` emits `assigns: %{samen_mount: mount}`),
  org via `CurrentOrg.resolve/3`.

    4. **Audit** — a delivered export is recorded (actor, org, resource, row count) BEFORE it is sent, and an export
       whose line cannot be written is a 503 that delivers nothing; refusals (403, 413, 422) are recorded too
       (`Samen.Web.AccessAudit`).

    5. **Row limit** — an export is built in memory, so `Csv.export/3` refuses an org above
       `Csv.max_export_rows/0` rows: 413, never a truncated file.
  """
  use Phoenix.Controller, formats: [:html]

  import Plug.Conn

  alias Samen.Web.AccessAudit
  alias Samen.Web.Csv
  alias Samen.Web.CurrentOrg
  alias Samen.Web.TenantActor

  def export(conn, params) do
    mount = conn.assigns[:samen_mount]
    session = get_session(conn)
    org_id = CurrentOrg.resolve(mount, params, session)

    # WHO exports: the signed-in person's resolved membership role (`Samen.Web.TenantActor`), not
    # `Mount.scope/2`'s fixed `:member`. Denied -> 403, a failed lookup -> 503; never a default role.
    ref = TenantActor.conn_ref(mount, params, session)
    actor = TenantActor.scope(mount, org_id, ref)

    do_export(conn, mount, org_id, Map.get(params, "resource"), actor, ref)
  end

  defp do_export(conn, nil, _org_id, _name, _actor, _ref), do: conn |> put_status(503) |> text("no mount")
  defp do_export(conn, _mount, nil, _name, _actor, _ref), do: conn |> put_status(404) |> text("no org")

  defp do_export(conn, mount, org_id, name, :denied, ref) do
    audit_refusal(mount, org_id, name, ref_id(ref), :denied)
    conn |> put_status(403) |> text("no access")
  end

  defp do_export(conn, _mount, _org_id, _name, {:error, :unavailable}, _ref), do: conn |> put_status(503) |> text("unavailable")

  defp do_export(conn, mount, org_id, name, {:ok, scope}, _ref) do
    case Csv.resolve_resource(mount, name) do
      {:error, :unknown_resource} ->
        conn |> put_status(404) |> text("unknown resource")

      {:ok, resource} ->
        case Csv.export_counted(resource, scope, repo: mount.repo) do
          {:ok, csv, rows} ->
            # The delivery is gated on its audit line: a copy of the org's data that could not be recorded is not sent.
            case AccessAudit.record(mount, :csv_export, org_id, %{
                   actor_id: scope.actor.id,
                   resource: resource_name(resource),
                   rows: rows,
                   outcome: :ok
                 }) do
              :ok ->
                conn
                |> assign(:samen_acting_role, scope.actor.role)
                |> put_resp_content_type("text/csv")
                |> put_resp_header(
                  "content-disposition",
                  ~s(attachment; filename="#{String.downcase(name)}.csv")
                )
                |> send_resp(200, csv)

              {:error, :audit_unavailable} ->
                conn |> put_status(503) |> text("unavailable")
            end

          # Fixed, value-free copy: the reason is for the log, never the body.
          {:error, {:too_many_rows, max}} ->
            audit_refusal(mount, org_id, name, scope.actor.id, :too_large, limit: max)
            conn |> put_status(413) |> text("export too large")

          {:error, _reason} ->
            audit_refusal(mount, org_id, name, scope.actor.id, :failed)
            conn |> put_status(422) |> text("export failed")
        end
    end
  end

  defp audit_refusal(mount, org_id, name, actor_id, outcome, extra \\ []) do
    resource =
      case Csv.resolve_resource(mount, name) do
        {:ok, resource} -> resource_name(resource)
        _ -> nil
      end

    AccessAudit.record_refusal(
      mount,
      :csv_export,
      org_id,
      Map.merge(%{actor_id: actor_id, resource: resource, outcome: outcome}, Map.new(extra))
    )
  end

  defp resource_name(resource), do: resource |> Module.split() |> List.last()

  defp ref_id({kind, id}) when kind in [:credential, :user, :dev] and is_binary(id), do: id
  defp ref_id(_), do: nil
end
