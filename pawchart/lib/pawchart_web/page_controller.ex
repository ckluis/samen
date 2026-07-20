defmodule PawChartWeb.PageController do
  @moduledoc """
  The PawChart landing + health endpoints.

  `/` renders a plain HTML index linking the CRM/Billing/Support inherited modules
  and the clinical vertical pages. `/healthz` returns `ok` (the LIVENESS probe).
  `/readyz` is the READINESS probe (WS-F1 / F1.2) — 200 only when Postgres, the KMS
  wrapped-DEK store, and Oban all answer (`Samen.Web.Readiness`), else 503.
  """
  use Phoenix.Controller, formats: [:html]

  import Plug.Conn

  def index(conn, _params) do
    html(conn, """
    <!DOCTYPE html>
    <html><head><title>PawChart — vet clinic SaaS on Samen</title>
    <style>body{font-family:system-ui;max-width:640px;margin:40px auto;padding:0 20px}
    h1{margin-bottom:4px}p{color:#666;margin-top:0}ul{margin-top:20px}
    li{margin:8px 0}a{color:#0e7c5a;text-decoration:none}a:hover{text-decoration:underline}
    .note{font-size:13px;color:#888;margin-top:24px;border-top:1px solid #eee;padding-top:16px}</style>
    </head>
    <body>
      <h1>PawChart</h1>
      <p>Vet-clinic SaaS — Phase-6 second-vertical thin slice on the Samen substrate.</p>
      <ul>
        <li><strong>Inherited (samen_web mounts — 3 lines):</strong></li>
        <li><a href="/crm/companies?org=#{PawChart.Seeds.clinic_org_id()}">CRM → Companies</a></li>
        <li><a href="/crm/contacts?org=#{PawChart.Seeds.clinic_org_id()}">CRM → Contacts</a></li>
        <li><a href="/crm/pipeline?org=#{PawChart.Seeds.clinic_org_id()}">CRM → Pipeline</a></li>
        <li><a href="/billing?org=#{PawChart.Seeds.clinic_org_id()}">Billing → Overview</a></li>
        <li><a href="/billing/invoices?org=#{PawChart.Seeds.clinic_org_id()}">Billing → Invoices</a></li>
        <li><a href="/support?org=#{PawChart.Seeds.clinic_org_id()}">Support → Tickets</a></li>
        <li><a href="/healthz">Health check</a></li>
      </ul>
      <div class="note">
        Mount reuse: 3 <code>samen_module_routes</code> calls in the router mount
        CRM (3 pages), Billing (3 pages) and Support (2 pages) — 8 pages, 0 PawChart
        LiveView code. Seed org: <code>#{PawChart.Seeds.clinic_org_id()}</code>.
      </div>
    </body></html>
    """)
  end

  def healthz(conn, _params) do
    send_resp(conn, 200, "ok")
  end

  def readyz(conn, _params) do
    case Samen.Web.Readiness.check(repo: PawChart.Repo) do
      {:ok, _checks} ->
        send_resp(conn, 200, "ready")

      {:error, checks} ->
        body =
          Enum.map_join(checks, "\n", fn
            {component, :ok} -> "#{component}: ok"
            {component, {:error, _reason}} -> "#{component}: FAIL"
          end)

        send_resp(conn, 503, "not ready\n" <> body)
    end
  end
end
