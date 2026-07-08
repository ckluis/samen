defmodule DriftwoodWeb.UIKitLive do
  @moduledoc """
  The Samen UI kit PREVIEW page (`/ui-kit`) — a living catalog that exercises every
  `DriftwoodWeb.UIKit` component so the kit can be eyeballed and asserted against in
  one place (ADR-008).

  It also proves the masking invariant end-to-end: the roster table includes a cell
  and a pill handed a real `%Samen.Masked{}` value. The kit does NOT unmask it — it
  renders through `Phoenix.HTML.Safe` as `••••`. There is no reveal path on this page.
  This is the visible guarantee that the kit is a dumb renderer of already
  plane-resolved values and cannot bypass masking.

  Serves the shared stylesheet at `/assets/samen_ui.css` (via the endpoint's
  `Plug.Static`). No app data is loaded — every value is inline sample content.
  """
  use Phoenix.LiveView

  import DriftwoodWeb.UIKit

  # A real %Masked{} value — the vault field's normal type. The preview renders it
  # through the kit's cells/pills to prove no plaintext-bypass path exists: it shows
  # ••••, never the token. Built with a fake token/label (no vault round-trip needed;
  # %Masked{} carries no plaintext by construction).
  @masked Samen.Masked.new("vault:preview-token", :full_name)

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, masked: @masked)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.app_shell>
      <:sidebar>
        <.sidebar title="Samen UI Kit" subtitle="Component preview">
          <:search>
            <div class="search">
              <svg class="i" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <circle cx="11" cy="11" r="7" /><path d="m21 21-4.3-4.3" />
              </svg>
              Search components…
              <span class="kbd">⌘K</span>
            </div>
          </:search>

          <.nav_group label="Kit">
            <.nav_item label="Overview" active count="12">
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <rect x="3" y="4" width="18" height="16" rx="2" /><path d="M3 9h18" />
                </svg>
              </:icon>
            </.nav_item>
            <.nav_item label="Impersonation" dot>
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M12 3a9 9 0 1 0 9 9" /><path d="M12 7v5l3 2" />
                </svg>
              </:icon>
            </.nav_item>
            <.nav_item label="Aggregate · MRR">
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M4 19V9m6 10V5m6 14v-7" />
                </svg>
              </:icon>
            </.nav_item>
          </.nav_group>

          <.nav_group label="Scopes">
            <.nav_item label="Identity" />
            <.nav_item label="Billing" count="3" />
          </.nav_group>

          <:footer>
            <div class="foot">
              <div class="av">CK</div>
              <div class="m"><b>C. Kluis</b><span>operator · admin role</span></div>
            </div>
          </:footer>
        </.sidebar>
      </:sidebar>

      <.topbar title="Component preview" crumbs={["Samen", "UI Kit", "Preview"]}>
        <:actions>
          <.button>
            <:icon>
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M4 6h16M7 12h10M10 18h4" /></svg>
            </:icon>
            Filter
          </.button>
          <.button variant="primary">
            <:icon>
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M12 3v18M3 12h18" /></svg>
            </:icon>
            New
          </.button>
        </:actions>
      </.topbar>

      <.mask_bar chip="session 27m left · reason: ticket #7781">
        <b>Masked impersonation.</b>
        You're viewing a tenant as an operator — personal data renders <b>••••</b> by default.
        Unmasking needs a second-party reveal grant, is time-boxed, and is audited.
      </.mask_bar>

      <.token_blind_bar chip="no reveal path · k ≥ 5 · l-diversity">
        <b>Token-blind aggregate plane.</b>
        This actor has <b>no pii_ column</b> in its domain by construction — it reads a
        vault-excluded projection. Cohorts below the k-anonymity floor are suppressed.
      </.token_blind_bar>

      <.tabs>
        <.tab label="Roster" active>
          <:icon>
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><circle cx="12" cy="8" r="3.2" /><path d="M5 20c0-3.5 3-6 7-6s7 2.5 7 6" /></svg>
          </:icon>
        </.tab>
        <.tab label="Compliance" />
        <.tab label="Dispatch" />
      </.tabs>

      <div class="wrap">
        <div class="metrics">
          <.metric label="Portfolio MRR" value="$284,900" delta="+6.2%" delta_dir="up" spark={[40, 52, 48, 63, 58, 71, 80]}>
            <:icon>
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M12 2v20M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6" /></svg>
            </:icon>
          </.metric>
          <.metric label="Active tenants" value="42" delta="+3" delta_dir="up" sub="3 new this week" />
          <.metric label="Loads / wk" value="1,418" delta="+11%" delta_dir="up" spark={[30, 44, 52, 49, 66, 70, 84]} />
          <.metric label="Net settlements" value="$1.92M" delta="−1.4%" delta_dir="down" sub="after deductions" />
        </div>

        <div class="gtitle">
          <h3>Driver roster</h3><span class="n">3</span>
          <span class="lane">· masked cells prove the no-bypass invariant</span>
        </div>

        <.data_table>
          <:head>
            <th style="width:28%">Driver</th>
            <th style="width:18%">CDL #</th>
            <th style="width:14%">Med card</th>
            <th style="width:14%">Dispatch</th>
            <th style="width:26%">Settlement · wk</th>
          </:head>

          <tr class="masked-row" id="row-masked">
            <td>
              <div class="drv">
                <div class="av"></div>
                <span class="nm masked">{@masked}</span>
              </div>
            </td>
            <td><span class="mono masked">{@masked}</span></td>
            <td><.pill variant="ok">Valid</.pill></td>
            <td><.pill variant="ok">Eligible</.pill></td>
            <td><.progress value={82} label="$4,494" /></td>
          </tr>

          <tr id="row-warn">
            <td>
              <div class="drv">
                <div class="av"></div>
                <span class="nm">Marcus Vale</span>
              </div>
            </td>
            <td><span class="mono">D4471-8820</span></td>
            <td><.pill variant="warn">Expires 14d</.pill></td>
            <td><.pill variant="info">En route</.pill></td>
            <td><.progress value={48} label="$2,510" color="var(--amber)" /></td>
          </tr>

          <tr id="row-bad">
            <td>
              <div class="drv">
                <div class="av"></div>
                <span class="nm">Dana Whitfield</span>
              </div>
            </td>
            <td><span class="mono">D9920-1104</span></td>
            <td><.pill variant="bad">Expired</.pill></td>
            <td><.pill variant="bad">Blocked</.pill></td>
            <td><.progress value={0} label="$0" color="var(--red)" /></td>
          </tr>

          <tr id="row-mut">
            <td>
              <div class="drv">
                <div class="av"></div>
                <span class="nm">Cole Barrett</span>
              </div>
            </td>
            <td><span class="mono">D2210-5561</span></td>
            <td><.pill variant="mut">On file</.pill></td>
            <td><.pill variant="mut">Off duty</.pill></td>
            <td><.progress value={0} label="$0" color="#D6D6DC" /></td>
          </tr>
        </.data_table>
      </div>
    </.app_shell>
    """
  end
end
