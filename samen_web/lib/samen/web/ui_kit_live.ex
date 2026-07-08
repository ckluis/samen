defmodule Samen.Web.UIKitLive do
  @moduledoc """
  The `/ui-kit` living catalog — a single page that renders every `Samen.UI` component so a
  host (or a designer) can eyeball the kit against the CSS. Host-agnostic; no data reads.
  Promoted from driftwood-local `DriftwoodWeb.UIKitLive` (ADR-009 §7.1).
  """
  use Phoenix.LiveView

  import Samen.UI

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div id="ui-kit">
      <.app_shell>
        <:sidebar>
          <.sidebar title="Samen.UI" subtitle="Component catalog" logo="S">
            <.nav_group label="Kit">
              <.nav_item label="Buttons" href="#buttons" active />
              <.nav_item label="Pills" href="#pills" />
              <.nav_item label="Metrics" href="#metrics" />
              <.nav_item label="Table" href="#table" />
              <.nav_item label="Progress" href="#progress" />
              <.nav_item label="Banners" href="#banners" />
            </.nav_group>
          </.sidebar>
        </:sidebar>

        <.topbar title="Samen.UI catalog" crumbs={["Framework", "UI", "Catalog"]} />

        <div class="wrap">
          <div class="gtitle" id="buttons"><h3>Buttons</h3></div>
          <div class="card" style="padding:18px;display:flex;gap:10px">
            <.button>Default</.button>
            <.button variant="primary">Primary</.button>
          </div>

          <div class="gtitle" id="pills"><h3>Pills</h3></div>
          <div class="card" style="padding:18px;display:flex;gap:8px;flex-wrap:wrap">
            <.pill variant="ok">ok</.pill>
            <.pill variant="warn">warn</.pill>
            <.pill variant="bad">bad</.pill>
            <.pill variant="info">info</.pill>
            <.pill variant="mut">mut</.pill>
          </div>

          <div class="gtitle" id="metrics"><h3>Metrics</h3></div>
          <div class="metrics">
            <.metric label="MRR" value="$12,400" delta="+8%" sub="monthly recurring" spark={[40, 52, 48, 63, 58, 71, 80]} />
            <.metric label="Tickets" value={42} />
          </div>

          <div class="gtitle" id="table"><h3>Data table</h3></div>
          <.data_table>
            <:head>
              <th>Name</th>
              <th>Status</th>
            </:head>
            <tr>
              <td>Example row</td>
              <td><.pill variant="ok">active</.pill></td>
            </tr>
          </.data_table>

          <div class="gtitle" id="progress"><h3>Progress</h3></div>
          <div class="card" style="padding:18px">
            <.progress value={68} label="68%" />
          </div>

          <div class="gtitle" id="banners"><h3>Banners</h3></div>
          <.mask_bar chip="TTL 14:32 · reason: support">
            <b>Masked impersonation.</b> Personal data renders •••• by default.
          </.mask_bar>
          <.token_blind_bar chip="no reveal path · k ≥ 5">
            <b>Token-blind aggregate plane.</b> No pii_ column by construction.
          </.token_blind_bar>
        </div>
      </.app_shell>
    </div>
    """
  end
end
