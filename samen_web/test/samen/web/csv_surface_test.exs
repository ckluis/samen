defmodule Samen.Web.CsvSurfaceTest do
  @moduledoc """
  WS-E E3.4 — the CSV ROUTE surface: `ExportController` (the download path) and
  `ImportLive` (render posture + report rendering). The export/import ENGINE
  semantics live in `csv_test.exs`; the per-plane export masking red-path in
  `csv_masking_test.exs`. Here we prove the mounted surface:

    * export download: tenant plane → 200 `text/csv` attachment with the org's
      rows; OPERATOR plane → the SAME route serves the masked CSV (`••••`, no
      plaintext, no `vt_*`) — masking, not refusal, is the export guarantee.
    * deny-by-default resource resolution: an unknown/unmounted resource is 404.
    * ImportLive: tenant plane offers the form; operator plane does not (posture);
      a `%Report{}` renders created count + per-row errors honestly.
  """
  use Samen.WebTest.DataCase, async: false
  use Samen.MaskingCase

  import Plug.Test
  import Plug.Conn

  alias Samen.Factory
  alias Samen.Web.Csv.ExportController
  alias Samen.Web.Csv.ImportLive
  alias Samen.Web.Csv.Report
  alias Samen.Web.Plane

  alias Samen.WebTest.Crm.Person

  @secret_first "SurfaceSecretFirst"
  @secret_last "Surface-Export-Secret"

  defp seed_person!(org_id) do
    Factory.create!(
      Person,
      Map.merge(Factory.person(@secret_first, @secret_last), %{
        display_name: "Surface Row",
        org_id: org_id
      }),
      Plane.scope(Plane.tenant(), org_id)
    )
  end

  defp csv_conn(org_id, plane_opts) do
    mount = build_mount(:csv, plane_opts)

    opts =
      Plug.Session.init(
        store: :cookie,
        key: "_csv_test",
        signing_salt: "csv_salt",
        encryption_salt: "csv_enc_salt"
      )

    conn(:get, "/csv/export/ignored")
    |> Map.put(:secret_key_base, String.duplicate("c", 64))
    |> Plug.Session.call(opts)
    |> fetch_session()
    |> put_session(Samen.Web.CurrentOrg.session_key(), org_id)
    |> Map.put(:assigns, %{samen_mount: mount})
  end

  defp import_socket(org_id, plane_opts, extra \\ []) do
    base =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(:samen_mount, build_mount(:csv, plane_opts))
      |> Phoenix.Component.assign(:samen_acting_as, false)
      |> Phoenix.Component.assign(:return_to, nil)
      |> Phoenix.Component.assign(:org_id, org_id)
      |> Phoenix.Component.assign(:resource_name, "Person")
      |> Phoenix.Component.assign(:report, Keyword.get(extra, :report))
      |> Phoenix.Component.assign(:import_error, Keyword.get(extra, :import_error))

    uploads = %{
      csv_upload: %Phoenix.LiveView.UploadConfig{
        ref: "csv_upload",
        name: :csv_upload,
        entries: [],
        errors: []
      }
    }

    %{base | assigns: Map.put(base.assigns, :uploads, uploads)}
  end

  describe "ExportController — the download route" do
    test "TENANT plane: 200 text/csv attachment carrying the org's rows in the clear" do
      org_id = Ash.UUID.generate()
      seed_person!(org_id)

      conn = csv_conn(org_id, []) |> ExportController.export(%{"resource" => "Person"})

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> Enum.join() =~ "text/csv"
      assert get_resp_header(conn, "content-disposition") |> Enum.join() =~ ~s(attachment; filename="person.csv")
      assert conn.resp_body =~ @secret_first
      refute conn.resp_body =~ "vt_"
    end

    test "OPERATOR plane: the SAME route serves the MASKED CSV — •••• cells, zero plaintext (AC-G15-2)" do
      org_id = Ash.UUID.generate()
      seed_person!(org_id)

      conn =
        csv_conn(org_id, plane: :operator, target_org_id: org_id)
        |> ExportController.export(%{"resource" => "Person"})

      # Masking, not refusal: the download succeeds and the cells are the UI's ••••.
      assert conn.status == 200
      assert_masked_dom!(conn.resp_body, [@secret_first, @secret_last])
      # Non-PII columns still present — the CSV is real, only vaulted cells mask.
      assert conn.resp_body =~ "Surface Row"
    end

    test "deny-by-default: an unknown resource name is 404 (no module minting, no oracle)" do
      org_id = Ash.UUID.generate()

      for name <- ["Bogus", "Vault", "../etc", "person_x"] do
        conn = csv_conn(org_id, []) |> ExportController.export(%{"resource" => name})
        assert conn.status == 404, "expected 404 for #{inspect(name)}"
        assert conn.resp_body == "unknown resource"
      end
    end

    test "no org in session → 404, nothing served" do
      conn = csv_conn(nil, []) |> ExportController.export(%{"resource" => "Person"})
      assert conn.status == 404
    end
  end

  describe "ImportLive — render posture + honest report" do
    test "TENANT plane offers the import form" do
      html = render_html(ImportLive, import_socket(Ash.UUID.generate(), []).assigns)

      assert html =~ ~s(id="csv-import-form")
      assert html =~ ~s(id="csv-import-submit")
      refute html =~ ~s(id="csv-import-refused")
    end

    test "OPERATOR plane: the form is NOT offered (write posture gate)" do
      org_id = Ash.UUID.generate()

      html =
        render_html(
          ImportLive,
          import_socket(org_id, plane: :operator, target_org_id: org_id).assigns
        )

      refute html =~ ~s(id="csv-import-form")
      assert html =~ ~s(id="csv-import-refused")
    end

    test "a report renders created count AND each failed row honestly" do
      report = %Report{total: 3, created: 1, errors: [%{row: 2, error: "forbidden"}, %{row: 3, error: "invalid"}]}

      html =
        render_html(
          ImportLive,
          import_socket(Ash.UUID.generate(), [], report: report).assigns
        )

      assert html =~ ~s(id="csv-import-report")
      assert html =~ "Imported <strong>1</strong> of 3 row(s)."
      assert html =~ ~s(id="csv-import-errors")
      assert html =~ "forbidden"
      assert html =~ "invalid"
    end

    test "a whole-file mapping rejection renders as the import error" do
      html =
        render_html(
          ImportLive,
          import_socket(Ash.UUID.generate(), [],
            import_error: "rejected: column(s) not importable: org_id"
          ).assigns
        )

      assert html =~ ~s(id="csv-import-error")
      assert html =~ "org_id"
    end
  end
end
