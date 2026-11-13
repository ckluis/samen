defmodule Samen.Web.Marketing.CampaignLive do
  @moduledoc """
  Framework Marketing / Campaign compose + send (`/marketing/campaigns/:id`) — ADR-011 §7.2.
  THE load-bearing outreach surface.

  Pick a **template** and a **segment**, then "Send to segment" enqueues one Oban-backed send
  per subscriber via `Samen.Web.Marketing.Reads.enqueue_send/3` — which ENFORCES consent /
  suppression: a send to a suppressed or unsubscribed subscriber is REFUSED (no send row, no
  Oban job), and the UI surfaces the refusal as a per-recipient "suppressed — skipped" line.

  ## PII / plane posture

  The recipient list resolves `Subscriber.email` through `Samen.Api.PiiResolution`: TENANT
  plane shows the org's own subscriber emails in the CLEAR; OPERATOR / impersonation plane
  shows `••••`. The SEND ITSELF never carries the email (only the opaque `subscriber_id`), and
  the "Send to segment" action is TENANT-plane only (an operator does not dispatch a tenant's
  outreach). On the operator plane the send controls are hidden.

  ## MASKING INVARIANT

  This LiveView never calls `Samen.Vault.reveal/3`, never unwraps a `%Masked{}`, and has no
  "show plaintext" branch. A `%Masked{}` recipient email renders `••••` verbatim.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Marketing.Live, only: [assign_mount: 2, marketing_sidebar: 1, marketing_path: 1, marketing_plane_note: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount

  alias Samen.Web.Marketing.Reads
  alias Samen.Web.Reads.Guard

  @display_limit 200

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    org_id = CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)
    campaign_id = Map.get(params, "id")

    {:ok,
     load(
       assign(socket, org_id: org_id, campaign_id: campaign_id, send_results: nil, notice: nil, return_to: nil),
       org_id,
       campaign_id
     )}
  end

  @impl true
  def handle_params(params, uri, socket) do
    org_id = Samen.Web.CurrentOrg.reresolve(socket, params)
    campaign_id = Map.get(params, "id") || socket.assigns.campaign_id
    {:noreply, load(assign(socket, org_id: org_id, campaign_id: campaign_id, return_to: return_path(uri)), org_id, campaign_id)}
  end

  # Send-to-segment (tenant plane only — the composer is hidden on the operator plane, so this
  # handler only runs there). Consent/suppression enforced by Reads.enqueue_send.
  @impl true
  def handle_event("retry_load", _params, socket),
    do: {:noreply, load(socket, socket.assigns.org_id, socket.assigns.campaign_id)}

  def handle_event("send_campaign", %{"send" => params}, socket) do
    %{samen_mount: mount, org_id: org_id, campaign: campaign} = socket.assigns
    scope = Mount.scope(mount, org_id)
    template_id = nz(params["template_id"])
    segment_id = nz(params["segment_id"])

    if is_nil(template_id) or is_nil(segment_id) or is_nil(campaign) do
      {:noreply,
       assign(socket,
         send_results: nil,
         notice: "Choose a template and a segment before sending."
       )}
    else
      {results, notice} = run_send(mount, scope, campaign, segment_id, template_id, org_id)

      {:noreply,
       assign(socket,
         # Display is bounded; the notice carries the full counts.
         send_results: results && Enum.take(results, @display_limit),
         notice: notice,
         sends: Reads.sends_for_campaign(mount, scope, campaign.id),
         event_counts: Reads.event_counts(mount, scope, campaign.id)
       )
       |> assign_delivery_errors(mount, scope, campaign.id)}
    end
  end

  defp run_send(mount, scope, campaign, segment_id, template_id, org_id) do
    with {:ok, segment} <- Reads.get_segment_result(mount, scope, segment_id),
         {:ok, results} <-
           Reads.send_campaign_to_segment(mount, scope, campaign, segment, template_id, org_id) do
      queued = Enum.count(results, &match?(%{result: {:ok, _}}, &1))
      already = Enum.count(results, &match?(%{result: {:error, :already_sent}}, &1))
      refused = length(results) - queued - already

      notice =
        if results == [] do
          "No eligible recipients in this segment."
        else
          "Enqueued #{queued} send(s); #{already} already sent; #{refused} refused (suppressed / unsubscribed / undeliverable)." <>
            if(length(results) > @display_limit,
              do: " Showing the first #{@display_limit}.",
              else: ""
            )
        end

      {results, notice}
    else
      {:error, :not_found} -> {nil, "Send failed: the segment was not found."}
      {:error, :unavailable} -> {nil, "Send failed: the segment could not be read. Nothing was sent — try again."}
      {:error, reason} -> {nil, "Send failed: #{describe_failure(reason)}"}
    end
  end

  defp describe_failure(:template_required), do: "choose a template."
  defp describe_failure(:campaign_required), do: "campaign not found."
  # Never the exception (its message can interpolate ids and query values): a value-free reason.
  defp describe_failure(:audience_unavailable),
    do:
      "the audience could not be read, so the send may not have finished. Recipients already queued are skipped when you try again."


  @doc false
  def load(socket, nil, _campaign_id) do
    socket
    |> ensure_return_to()
    |> assign(
      no_org: CurrentOrg.no_org?(socket.assigns[:samen_mount], nil),
      org_id: nil,
      campaign_id: nil,
      campaign: nil,
      load_error: nil,
      section_errors: [],
      templates: [],
      segments: [],
      audience: [],
      sends: [],
      event_counts: %{},
      send_results: Map.get(socket.assigns, :send_results),
      notice: Map.get(socket.assigns, :notice)
    )
  end

  def load(socket, org_id, campaign_id) do
    mount = socket.assigns.samen_mount
    scope = Mount.scope(mount, org_id)

    # A FAILED campaign read is the error state (retry), never "Campaign not found."; each
    # secondary read fails on its own (`section_errors`) and blanks only its own pane.
    {campaign, load_error} =
      if campaign_id do
        case Reads.get_campaign_result(mount, scope, campaign_id) do
          {:ok, c} -> {c, nil}
          {:error, :not_found} -> {nil, nil}
          {:error, :unavailable} -> {nil, Guard.message()}
        end
      else
        {nil, nil}
      end

    segments_result = Reads.segments_result(mount, scope)
    templates_result = Reads.templates_result(mount, scope)
    segments = Guard.value(segments_result, [])

    audience_result =
      case segments do
        [first | _] -> Reads.segment_audience_result(mount, scope, first)
        [] -> {:ok, []}
      end

    socket
    |> ensure_return_to()
    |> assign(
      no_org: false,
      org_id: org_id,
      campaign_id: campaign_id,
      campaign: campaign,
      load_error: load_error,
      templates: Guard.value(templates_result, []),
      segments: segments,
      audience: Guard.value(audience_result, []),
      sends: [],
      event_counts: %{},
      send_results: Map.get(socket.assigns, :send_results),
      notice: Map.get(socket.assigns, :notice)
    )
    |> assign(
      section_errors:
        for(
          {key, result} <- [templates: templates_result, segments: segments_result, audience: audience_result],
          Guard.unavailable?(result),
          do: key
        )
    )
    |> then(fn socket ->
      if campaign, do: assign_delivery_errors(socket, mount, scope, campaign.id), else: socket
    end)
  end

  # The delivery pane (sends + events) reads on its own; a failure is its own error, not
  # "No sends yet." Keeps any template/segment/audience errors already recorded.
  defp assign_delivery_errors(socket, mount, scope, campaign_id) do
    sends = Reads.sends_for_campaign_result(mount, scope, campaign_id)
    counts = Reads.event_counts_result(mount, scope, campaign_id)

    failed =
      if Guard.unavailable?(sends) or Guard.unavailable?(counts), do: [:delivery], else: []

    kept = Enum.reject(socket.assigns[:section_errors] || [], &(&1 == :delivery))

    assign(socket,
      sends: Guard.value(sends, []),
      event_counts: Guard.value(counts, %{}),
      section_errors: kept ++ failed
    )
  end

  defp ensure_return_to(socket) do
    if Map.has_key?(socket.assigns, :return_to), do: socket, else: assign(socket, return_to: nil)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="mkt-campaign">
      <.app_shell>
        <:sidebar>
          <.marketing_sidebar mount={@samen_mount} org_id={@org_id} active={:marketing_campaigns} return_to={@return_to} />
        </:sidebar>

        <.topbar title={campaign_title(@campaign)} crumbs={crumbs(@samen_mount, @org_id, campaign_title(@campaign))}>
          <:actions>
            <a href={campaigns_path(@samen_mount, @org_id)} class="btn" style="text-decoration:none">Back to campaigns</a>
          </:actions>
        </.topbar>

        <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

        <%= if @no_org do %>
          <.no_org_card mount={@samen_mount} />
        <% else %>
          <span id="org-banner" style="display:none">Marketing org: {@org_id}</span>

          <%= if @campaign == nil do %>
            <div :if={@load_error} class="wrap">
              <.error_state class="campaign-error" body={@load_error} retry_event="retry_load" />
            </div>
            <div :if={is_nil(@load_error)} class="wrap">
              <div class="card" style="padding:22px 20px;color:var(--muted)">Campaign not found.</div>
            </div>
          <% else %>
            <div class="wrap" style="margin-bottom:0">
              <div class="card" id="campaign-header" style="padding:18px 20px">
                <div style="display:flex;align-items:center;gap:12px;flex-wrap:wrap">
                  <h1 style="font-weight:600;font-size:18px;color:#2a2b35;margin:0">{@campaign.name}</h1>
                  <.pill variant={status_variant(@campaign.status)}>{@campaign.status}</.pill>
                </div>
                <div :if={@campaign.description} style="font-size:12px;color:var(--muted);margin-top:4px">{@campaign.description}</div>
                <div style="font-size:11px;color:var(--muted);margin-top:6px">· consent + suppression enforced on every send · {marketing_plane_note(@samen_mount)}</div>
              </div>
            </div>

            <%= if composer?(@samen_mount) do %>
              <div class="wrap" id="compose-pane" style="margin-bottom:0;padding-top:8px">
                <.error_state :if={:templates in @section_errors or :segments in @section_errors} class="compose-error" body={Guard.message()} retry_event="retry_load" />
                <div class="card" style="padding:18px 20px">
                  <div class="gtitle" style="margin-bottom:12px"><h3>Compose &amp; send</h3></div>
                  <form id="send-campaign-form" phx-submit="send_campaign" style="display:flex;flex-direction:column;gap:10px">
                    <label style="font-size:12px;color:var(--muted)">Template
                      <select name="send[template_id]" style="display:block;margin-top:4px;padding:7px 10px;border:1px solid var(--border);border-radius:6px;font-size:13px;min-width:280px">
                        <option value="">— select a template —</option>
                        <option :for={t <- @templates} value={t.id}>{t.name} — {t.subject_line}</option>
                      </select>
                    </label>
                    <label style="font-size:12px;color:var(--muted)">Segment (audience)
                      <select name="send[segment_id]" style="display:block;margin-top:4px;padding:7px 10px;border:1px solid var(--border);border-radius:6px;font-size:13px;min-width:280px">
                        <option value="">— select a segment —</option>
                        <option :for={s <- @segments} value={s.id}>{s.name} ({s.subscriber_count} subscribers)</option>
                      </select>
                    </label>
                    <div>
                      <.button variant="primary" type="submit" phx-disable-with="Sending…">Send to segment</.button>
                    </div>
                  </form>
                </div>
              </div>
            <% end %>

            <div :if={@notice} class="wrap" style="margin-bottom:0;padding-top:8px">
              <div class="card send-notice" style="padding:12px 16px;font-size:13px;color:#2a2b35">{@notice}</div>
            </div>

            <div :if={@send_results not in [nil, []]} class="wrap" id="send-results" style="margin-bottom:0;padding-top:8px">
              <div class="card" style="padding:8px 4px 12px">
                <div class="gtitle" style="margin-bottom:8px;padding:6px 16px 0"><h3>Send results</h3></div>
                <.data_table>
                  <:head>
                    <th style="width:60%">Subscriber</th>
                    <th style="width:40%">Result</th>
                  </:head>
                  <tr :for={r <- @send_results} class="send-result-row" id={"send-result-#{r.subscriber_id}"}>
                    <td style="font-size:12px;color:var(--muted)">{short_id(r.subscriber_id)}</td>
                    <td>{result_pill(r.result)}</td>
                  </tr>
                </.data_table>
              </div>
            </div>

            <div class="wrap" id="audience-pane" style="margin-bottom:0;padding-top:8px">
              <div class="gtitle"><h3>Recipients (first segment)</h3><span class="n">{length(@audience)}</span>
                <span class="lane">· email via PiiResolution · {marketing_plane_note(@samen_mount)}</span>
              </div>
              <%= if :audience in @section_errors or :segments in @section_errors do %>
                <.error_state class="audience-error" body={Guard.message()} retry_event="retry_load" />
              <% else %>
              <%= if @audience == [] do %>
                <.empty_state
                  class="recipients-empty"
                  icon="◔"
                  title="No subscribers in the first segment yet."
                  body="Add subscribers to the campaign's segment and they appear here as recipients."
                />
              <% else %>
                <.data_table>
                  <:head>
                    <th style="width:50%">Email</th>
                    <th style="width:25%">Status</th>
                    <th style="width:25%">Source</th>
                  </:head>
                  <tr :for={s <- @audience} class="recipient-row" id={"recipient-#{s.id}"}>
                    <td class="recipient-email" style="font-size:12px;color:var(--muted)">{s.email}</td>
                    <td><.pill variant={sub_status_variant(s.status)}>{s.status}</.pill></td>
                    <td style="font-size:12px;color:var(--muted)">{s.source || "—"}</td>
                  </tr>
                </.data_table>
              <% end %>
              <% end %>
            </div>

            <div class="wrap" id="events-pane" style="padding-top:8px">
              <div class="gtitle"><h3>Delivery events</h3></div>
              <.error_state :if={:delivery in @section_errors} class="delivery-error" body={Guard.message()} retry_event="retry_load" />
              <div :if={:delivery not in @section_errors} class="card" style="padding:14px 16px;display:flex;gap:8px;flex-wrap:wrap">
                <%= if @event_counts == %{} and @sends == [] do %>
                  <span style="color:var(--muted);font-size:13px">No sends yet.</span>
                <% else %>
                  <.pill variant="info">queued {Enum.count(@sends, &(&1.status == :queued))}</.pill>
                  <.pill :for={{type, count} <- @event_counts} variant={event_variant(type)}>{type} {count}</.pill>
                <% end %>
              </div>
            </div>
          <% end %>
        <% end %>
      </.app_shell>
    </div>
    """
  end

  # The send controls are tenant-plane only (an operator does not dispatch a tenant's outreach).
  defp composer?(%Mount{plane: %{kind: :operator}}), do: false
  defp composer?(_), do: true

  defp crumbs(mount, org_id, leaf), do: [CurrentOrg.name(mount, org_id), "Marketing", "Campaigns", leaf]

  defp campaigns_path(mount, org_id), do: "#{marketing_path(mount)}/campaigns?org=#{org_id}"

  defp campaign_title(nil), do: "Campaign"
  defp campaign_title(%{name: name}) when is_binary(name), do: name
  defp campaign_title(_), do: "Campaign"

  # Per-recipient result → a pill. The refusal is VISIBLE (suppressed/unsubscribed shown red).
  defp result_pill({:ok, _}), do: pilled("ok", "queued")
  defp result_pill({:error, :already_sent}), do: pilled("mut", "already sent — skipped")
  defp result_pill({:error, :suppressed}), do: pilled("bad", "suppressed — skipped")
  defp result_pill({:error, :unsubscribed}), do: pilled("bad", "unsubscribed — skipped")
  defp result_pill({:error, :bounced}), do: pilled("bad", "bounced — skipped")
  defp result_pill({:error, :complained}), do: pilled("bad", "complained — skipped")
  defp result_pill({:error, reason}), do: pilled("warn", "skipped (#{inspect(reason)})")

  defp pilled(variant, label) do
    assigns = %{variant: variant, label: label}

    ~H"""
    <.pill variant={@variant}>{@label}</.pill>
    """
  end

  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8) <> "…"
  defp short_id(_), do: "—"

  defp status_variant(:draft), do: "mut"
  defp status_variant(:scheduled), do: "info"
  defp status_variant(:sending), do: "warn"
  defp status_variant(:sent), do: "ok"
  defp status_variant(:cancelled), do: "bad"
  defp status_variant(_), do: "mut"

  defp sub_status_variant(:active), do: "ok"
  defp sub_status_variant(:unsubscribed), do: "bad"
  defp sub_status_variant(:bounced), do: "warn"
  defp sub_status_variant(:complained), do: "bad"
  defp sub_status_variant(_), do: "mut"

  defp event_variant(:delivered), do: "ok"
  defp event_variant(:opened), do: "info"
  defp event_variant(:clicked), do: "info"
  defp event_variant(:bounced), do: "bad"
  defp event_variant(:unsubscribed), do: "warn"
  defp event_variant(:complained), do: "bad"
  defp event_variant(_), do: "mut"

  defp nz(nil), do: nil
  defp nz(""), do: nil
  defp nz(s) when is_binary(s), do: s
end
