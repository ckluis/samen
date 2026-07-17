defmodule Driftwood.GateE3CsvE2ETest do
  @moduledoc """
  GATE PROBE (WS-E E3.5) — end-to-end CSV lifecycle on a REAL host (Driftwood):
  seed vaulted Person → tenant export (clear) → operator export (masked, SAME
  route) → import back through the governed chokepoint → vault-routed at rest.

  Exercises the full stack the `samen_csv_routes` macro mounts, on a real
  vertical's CRM domain + repo. A gate artifact, not part of the shipped suites.
  """
  use Driftwood.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Samen.Factory
  alias Samen.Masked
  alias Samen.Web.Csv
  alias Samen.Web.Csv.ExportController
  alias Samen.Web.Csv.Report
  alias Samen.Web.Plane

  alias Driftwood.Crm.Person

  @secret_first "GateDriverFirst"
  @secret_last "Gate-CDL-Secret"

  defp export_conn(org_id, plane_opts) do
    mount = driftwood_mount(:csv, plane_opts)

    sopts =
      Plug.Session.init(
        store: :cookie,
        key: "_e3",
        signing_salt: "salt_e3",
        encryption_salt: "enc_e3"
      )

    conn(:get, "/csv/export/ignored")
    |> Map.put(:secret_key_base, String.duplicate("y", 64))
    |> Plug.Session.call(sopts)
    |> fetch_session()
    |> put_session(Samen.Web.CurrentOrg.session_key(), org_id)
    |> Map.put(:assigns, %{samen_mount: mount})
  end

  test "FULL LIFECYCLE: seed → tenant export clear → operator export masked → governed re-import (AC-G15-1/2/3/4)" do
    org_a = Ash.UUID.generate()
    org_b = Ash.UUID.generate()

    # 1. SEED a vaulted person on the real vertical (governed create, vault-routed).
    Factory.create!(
      Person,
      Map.merge(Factory.person(@secret_first, @secret_last), %{
        display_name: "Gate Driver",
        org_id: org_a
      }),
      Plane.scope(Plane.tenant(), org_a)
    )

    # 2. TENANT export via the mounted route — 200, CSV attachment, PII clear.
    t_conn = export_conn(org_a, []) |> ExportController.export(%{"resource" => "Person"})
    assert t_conn.status == 200
    assert get_resp_header(t_conn, "content-type") |> Enum.join() =~ "text/csv"
    assert t_conn.resp_body =~ @secret_first
    refute t_conn.resp_body =~ "vt_"

    # 3. OPERATOR export — the SAME route, cells masked •••• , zero plaintext,
    #    zero vault tokens (AC-G15-2 on a real host).
    o_conn =
      export_conn(org_a, plane: :operator, target_org_id: org_a)
      |> ExportController.export(%{"resource" => "Person"})

    assert o_conn.status == 200
    assert o_conn.resp_body =~ "••••"
    refute o_conn.resp_body =~ @secret_first
    refute o_conn.resp_body =~ @secret_last
    refute o_conn.resp_body =~ "vt_"

    # 4. DENY-BY-DEFAULT: a non-CRM resource name is 404 on this mount.
    bad = export_conn(org_a, []) |> ExportController.export(%{"resource" => "File"})
    assert bad.status == 404

    # 5. RE-IMPORT the tenant CSV into a second org through the governed chokepoint.
    {:ok, %Report{created: 1, errors: []}} =
      Csv.import(Person, Plane.scope(Plane.tenant(), org_b), csv: t_conn.resp_body)

    [imported] =
      Person
      |> Ash.Query.ensure_selected([:full_name, :display_name])
      |> Ash.read!(scope: Plane.scope(Plane.tenant(), org_b))

    # Vault-routed at rest on the real vertical: token wrapper, never plaintext.
    assert %Masked{token: "vt_" <> _} = imported.full_name
    assert imported.display_name == "Gate Driver"
  end
end
