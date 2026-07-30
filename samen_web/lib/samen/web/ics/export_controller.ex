defmodule Samen.Web.Ics.ExportController do
  @moduledoc """
  Framework `.ics` download route (F2; spec §F2/§F8 c8) — the ONLY `.ics`
  byte-delivery path. Mirrors `Samen.Web.Csv.ExportController` exactly in
  shape (Mount/session posture, org-scoping, masking rationale):

    1. **Org-scope** — the org comes from the session (`Samen.Web.CurrentOrg`),
       the scope from the mount's plane. Rows are read org-scoped and keyset-
       bounded (`Ics.export/2` → `Reads.page!/3`).

    2. **Masking (INV-1)** — there is NO plane gate here and none is needed:
       export is safe on EVERY plane because every row is resolved through
       `PiiResolution` on the acting plane before serialization. An operator
       downloads a `.ics` whose attendee lines are masked — the same pixels
       the UI would show.

  Mount/session posture mirrors `Samen.Web.Csv.ExportController`: mount from
  `conn.assigns[:samen_mount]`, org via `CurrentOrg.resolve/3`.
  """
  use Phoenix.Controller, formats: [:html]

  import Plug.Conn

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Ics
  alias Samen.Web.Mount

  def export(conn, params) do
    mount = conn.assigns[:samen_mount]
    session = get_session(conn)
    org_id = CurrentOrg.resolve(mount, params, session)

    do_export(conn, mount, org_id)
  end

  defp do_export(conn, nil, _org_id), do: conn |> put_status(503) |> text("no mount")
  defp do_export(conn, _mount, nil), do: conn |> put_status(404) |> text("no org")

  defp do_export(conn, mount, org_id) do
    scope = Mount.scope(mount, org_id)
    # The ADR-004 naming convention (see Mount moduledoc): the Calendar
    # scope's blueprint always materializes its one resource at
    # `Module.concat(namespace, Event)` — no separate `:resource` route
    # param needed (unlike CSV, which serves ANY resource of a domain).
    resource = Mount.resource(mount, Event)

    # Ics.export/3 has no failure return (bounded keyset read + per-plane
    # resolution, both total functions) — unlike Csv.export/3 there is no
    # :columns validation step that can reject the call.
    {:ok, ics} = Ics.export(resource, scope, repo: mount.repo)

    conn
    |> put_resp_content_type("text/calendar")
    |> put_resp_header("content-disposition", ~s(attachment; filename="calendar.ics"))
    |> send_resp(200, ics)
  end
end
