defmodule Samen.Web.Billing.UsageLive do
  @moduledoc """
  Framework Billing / USAGE page (T163; ADR-051 P4) — the tenant usage panel: how much
  of each metered metric the org has used per billing period, host-agnostic (ADR-009).
  Every host that mounts `samen_module_routes(:billing, ...)` inherits it at
  `<billing path>/usage` with no host change.

  Read-ONLY. A lens over `Samen.Web.Billing.Reads.usage/2`, the derived `Usage` tallies
  (`Samen.Billing.UsageTally` recomputes them from the insert-only ledger). Usage is
  captured by `Samen.Billing.Meter.record/3`, never authored here, so the page exposes no
  write affordance on either plane.

  ## Quantities only — never a local price (ADR-051 D2)

  The page shows quantities: how much was used, and how much of that has been sent to
  the billing provider. It shows NO amount, rate or spend estimate. Money is MIRRORED
  from the provider, never computed in samen (`Samen.Billing.Mirror`), so what the org
  is charged is on the provider's invoice, which the page links to instead.

  Non-PII: every column is a bounded metric atom, an integer or a timestamp, so both
  planes render the same values and nothing is masked.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Billing.Live, only: [assign_mount: 2, billing_sidebar: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.Billing.Reads
  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    org_id = CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)
    {:ok, load(assign(socket, org_id: org_id), org_id)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    org_id = CurrentOrg.reresolve(socket, params)
    {:noreply, load(assign(socket, org_id: org_id, return_to: return_path(uri)), org_id)}
  end

  @doc false
  def load(socket, nil) do
    socket
    |> ensure_return_to()
    |> assign(no_org: CurrentOrg.no_org?(socket.assigns[:samen_mount], nil), org_id: nil, rows: [])
  end

  def load(socket, org_id) do
    mount = socket.assigns.samen_mount
    rows = Reads.usage(mount, Mount.scope(mount, org_id))

    socket
    |> ensure_return_to()
    |> assign(no_org: false, org_id: org_id, rows: rows)
  end

  defp ensure_return_to(socket) do
    if Map.has_key?(socket.assigns, :return_to), do: socket, else: assign(socket, return_to: nil)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="billing-usage">
      <.app_shell>
        <:sidebar>
          <.billing_sidebar mount={@samen_mount} org_id={@org_id} active={:billing_usage} return_to={@return_to} />
        </:sidebar>

        <.topbar title="Usage" crumbs={[CurrentOrg.name(@samen_mount, @org_id), "Billing", "Usage"]} />

        <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

        <%= if @no_org do %>
          <.no_org_card mount={@samen_mount} />
        <% else %>
          <div class="wrap">
            <div id="usage">
              <div class="gtitle">
                <h3>Metered usage by period</h3>
                <span class="n">{length(@rows)}</span>
                <span class="lane">· quantities only</span>
              </div>

              <p id="usage-charges-note" style="font-size:12px;color:var(--muted);margin:0 0 12px">
                Charges for this usage appear on your
                <a href={"#{billing_path(@return_to)}/invoices?org=#{@org_id}"} id="usage-invoices-link">invoices</a>
                from your billing provider.
              </p>

              <.empty_state
                :if={@rows == []}
                class="usage-empty"
                icon="∅"
                title="No metered usage yet."
                body="Usage appears here once it is recorded and tallied for a billing period."
              />

              <.data_table :if={@rows != []}>
                <:head>
                  <th style="width:22%">Metric</th>
                  <th style="width:30%">Period</th>
                  <th style="width:16%">Used</th>
                  <th style="width:16%">Sent to provider</th>
                  <th style="width:16%">Status</th>
                </:head>
                <tr :for={row <- @rows} class="usage-row" id={"usage-#{row.id}"}>
                  <td class="u-metric" style="font-weight:500;color:#3a3b45">{metric_label(row.metric)}</td>
                  <td class="u-period" style="color:var(--muted)">{period(row.period_start, row.period_end)}</td>
                  <td class="u-quantity" style="font-weight:500;color:#3a3b45">{count(row.quantity)}</td>
                  <td class="u-reported" style="color:var(--muted)">{count(row.reported_quantity)}</td>
                  <td class="u-status">
                    <.pill variant={status_variant(row)}>{status_label(row)}</.pill>
                  </td>
                </tr>
              </.data_table>
            </div>
          </div>
        <% end %>
      </.app_shell>
    </div>
    """
  end

  # The mount's path prefix, from the current URL (the SettingsLive derivation).
  defp billing_path(nil), do: "/billing"

  defp billing_path(return_to) do
    return_to
    |> String.split("/")
    |> Enum.take(2)
    |> Enum.join("/")
    |> case do
      "" -> "/billing"
      path -> path
    end
  end

  defp metric_label(:api_calls), do: "API calls"
  defp metric_label(:seats), do: "Seats"
  defp metric_label(:storage_gb), do: "Storage (GB)"
  defp metric_label(:events), do: "Events"
  defp metric_label(:messages), do: "Messages"
  defp metric_label(:custom_metric), do: "Custom metric"
  defp metric_label(other), do: to_string(other)

  defp period(%DateTime{} = from, %DateTime{} = to), do: "#{date(from)} – #{date(to)}"
  defp period(%DateTime{} = from, _), do: "from #{date(from)}"
  defp period(_, _), do: "—"

  defp date(%DateTime{} = dt), do: Calendar.strftime(dt, "%b %-d, %Y")

  # Thousands separators, no currency: these are counts.
  defp count(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp count(_), do: "0"

  defp status_label(%{quantity: q, reported_quantity: r}) when is_integer(q) and is_integer(r) and q > r,
    do: "#{count(q - r)} not yet sent"

  defp status_label(_), do: "sent"

  defp status_variant(%{quantity: q, reported_quantity: r}) when is_integer(q) and is_integer(r) and q > r,
    do: "info"

  defp status_variant(_), do: "ok"
end
