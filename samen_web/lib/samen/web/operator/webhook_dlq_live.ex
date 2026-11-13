defmodule Samen.Web.Operator.WebhookDlqLive do
  @moduledoc """
  Framework OPERATOR / Webhook DLQ page (ADR-038 §5.5; WS-B / B9) — the dead-letter
  view every vertical inherits at 0 LOC via `samen_operator_routes/2`.

  Lists failed/unprocessable webhook envelopes (`:dead` first, then recent
  `:received`/`:processed`) with operator **replay** + **resolve** actions. Reads the
  kernel `Samen.Webhook.Event` store through the mount's repo.

  ## Token-blind by construction (INV-1 / INV-2)

  This is an operator PII surface, so it is masked-by-default — but here masking is by
  CONSTRUCTION, not by a reveal path: the ingress persists envelopes with the payload
  ALREADY redacted (`redact_payload/1`, ADR-038 §5.4), and `whk_event` carries NO
  vault-routed (🔒) column at all. Every rendered value is a bounded provider name,
  event kind, event id, domain, status, timestamp, attempt count, an error SUMMARY
  (message + digest, never a payload echo), or the already-redacted payload map. There
  is NO `%Masked{}` branch and NO `vt_*` token to leak — proven by the no-plaintext /
  no-`vt_`-token DOM probe in `webhook_security_test.exs` (the ADR-038 §5.5 discipline
  for a fully-redacted store, in place of the `Samen.MaskingCase` three-proof used when
  a 🔒 field renders).

  ## Fail-safe

  A host that has not yet run the `whk_event` migration reads zero rows (the query is
  rescued to `[]`) and sees the honest empty state — never a 500.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Operator.Live

  alias Samen.Web.Mount
  alias Samen.Web.Operator
  alias Samen.Web.Reads.Guard
  alias Samen.Webhook.Event

  @impl true
  def mount(_params, session, socket) do
    socket = assign_mount(socket, session)
    {:ok, load(socket)}
  end

  @doc false
  def load(socket) do
    mount = socket.assigns[:samen_mount]

    case mount && Operator.org_id(mount) do
      nil ->
        assign_new(socket, :action_error, fn -> nil end)
        |> assign(no_org: true, envelopes: [], dead_count: 0, load_error: false)

      _org_id ->
        {envelopes, load_error} =
          case list_envelopes(mount) do
            {:ok, envelopes} -> {envelopes, false}
            # A failed read is NOT an empty queue: "No webhook envelopes — nothing has dead-lettered"
            # over an outage would tell the operator there is nothing to replay.
            {:error, _} -> {[], true}
          end

        socket
        |> assign_new(:action_error, fn -> nil end)
        |> assign(
          no_org: false,
          envelopes: envelopes,
          load_error: load_error,
          dead_count: Enum.count(envelopes, &(&1.status == "dead"))
        )
    end
  end

  # S14 — the operator roles that may MUTATE the webhook store (replay/resolve). The role is
  # ONLY ever read from `:samen_operator_role` — the assign `Samen.Web.Operator.Authz`'s
  # `:require_operator` on_mount derived from the AUTHENTICATED session principal (the T146
  # role-derivation pattern) — never from the mount or a param. `:operator_readonly`'s
  # contract is "read the operator CRM only" (`Samen.OperatorPlane.Actor`): it may render
  # this page, never write through it. `nil`/unknown roles fail closed.
  @write_roles [:operator_admin, :operator_support]

  @impl true
  def handle_event("retry_load", _params, socket), do: {:noreply, load(socket)}

  def handle_event("replay", %{"id" => id}, socket) do
    error =
      with {:ok, repo} <- authorize_write(socket),
           {:ok, row} <- fetch_dead(repo, id),
           # Reset + re-enqueue the processing job in ONE transaction (safe to repeat: processing is
           # idempotent, §5.5): a failed enqueue rolls the reset back, so the envelope stays dead and replayable.
           {:ok, _row} <- Guard.write(:operator_dlq_replay, nil, fn -> Event.replay(repo, row) end) do
        nil
      else
        {:error, reason} -> action_copy(:replay, reason)
        :denied -> action_copy(:replay, :denied)
      end

    {:noreply, socket |> assign(action_error: error) |> load()}
  end

  @impl true
  def handle_event("resolve", %{"id" => id}, socket) do
    error =
      with {:ok, repo} <- authorize_write(socket),
           {:ok, row} <- fetch_dead(repo, id),
           {:ok, _row} <- Guard.write(:operator_dlq_resolve, nil, fn -> Event.mark_processed(repo, row) end) do
        nil
      else
        {:error, reason} -> action_copy(:resolve, reason)
        :denied -> action_copy(:resolve, :denied)
      end

    {:noreply, socket |> assign(action_error: error) |> load()}
  end

  # A malformed id is "not found" (cast before the query: no logged failure); a read that raises
  # is `{:error, :unavailable}`; a row that is no longer dead-lettered is `{:error, :not_found}`.
  defp fetch_dead(repo, id) do
    with {:ok, id} <- cast_id(id),
         {:ok, row} <- Guard.run(:operator_dlq_fetch, nil, fn -> Event.get_dead(repo, id) end) do
      if row, do: {:ok, row}, else: {:error, :not_found}
    end
  end

  defp cast_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end

  # Value-free copy: outage copy only for an outage, denial copy only for a real denial.
  defp action_copy(_action, :denied), do: "Your operator role may not change the webhook queue."
  defp action_copy(_action, :forbidden), do: "Your operator role may not change the webhook queue."
  defp action_copy(_action, :not_found), do: "That envelope is no longer in the dead-letter set — nothing was changed."

  defp action_copy(:replay, reason) when reason in [:unavailable, :enqueue_failed],
    do: "We couldn't replay that envelope right now — nothing was changed and it is still in the dead-letter set. Try again."

  defp action_copy(:replay, :queue_repo_mismatch),
    do: "Replay is unavailable: this host's job queue is not on the webhook database. Nothing was changed."

  defp action_copy(:resolve, :unavailable),
    do: "We couldn't mark that envelope handled right now — nothing was changed. Try again."

  defp action_copy(_action, _other), do: "The webhook queue was not changed."

  # The S14 write gate, three ANDed conjuncts — all strictly narrowing, never widening:
  #   1. ROLE — `:samen_operator_role` ∈ @write_roles (see above; fail closed on nil);
  #   2. ORG  — the mount resolves an operator org, the SAME `no_org` fail-secure guard
  #      `load/1` applies to the read path (an org-less mount renders nothing AND writes
  #      nothing — parity, instead of the old write-path bypass);
  #   3. REPO — a usable repo on the mount.
  # The row fetch itself is `Event.get_dead/2` (bounded to the DLQ's actionable set), so
  # even an authorized operator can only ever touch rows this surface actually exposes.
  defp authorize_write(socket) do
    mount = socket.assigns[:samen_mount]

    with true <- socket.assigns[:samen_operator_role] in @write_roles,
         %Mount{repo: repo} when is_atom(repo) and not is_nil(repo) <- mount,
         org_id when is_binary(org_id) <- Operator.org_id(mount) do
      {:ok, repo}
    else
      _ -> :denied
    end
  end

  # ---------------------------------------------------------------------------

  defp list_envelopes(%Mount{repo: repo}) when is_atom(repo) and not is_nil(repo) do
    Guard.run(:operator_dlq_envelopes, nil, fn -> Event.list_for_operator(repo, limit: 100) end)
  end

  defp list_envelopes(_), do: {:ok, []}

  @impl true
  def render(assigns) do
    ~H"""
    <div id="operator-webhooks">
      <.app_shell>
        <:sidebar>
          <.operator_sidebar mount={@samen_mount} active={:webhooks} />
        </:sidebar>

        <.topbar title="Webhook DLQ" crumbs={["Operator plane", "Webhook DLQ"]} />

        <%= if @no_org do %>
          <div class="wrap">
            <div class="card" id="no-org" style="padding:22px 20px;color:var(--muted)">
              No operator org resolved.
            </div>
          </div>
        <% else %>
          <div class="wrap">
            <.token_blind_bar chip="payloads redacted at ingress · no vault token">
              <b>Token-blind dead-letter view.</b>
              Envelopes are stored with the vendor payload's PII already pruned
              (<span class="mono">redact_payload/1</span>, ADR-038 §5.4) — this surface
              renders only bounded ids, enums, timestamps, an error summary, and the
              already-redacted payload. No vault token, no plaintext email/name, by
              construction.
            </.token_blind_bar>

            <div :if={@action_error} id="dlq-action-error" class="card form-error" role="alert" style="padding:10px 14px;margin-top:14px;font-size:12px">
              {@action_error}
            </div>

            <div id="dlq-envelopes" style="margin-top:14px">
              <div class="gtitle">
                <h3>Webhook envelopes</h3>
                <span class="n">{length(@envelopes)}</span>
                <span class="lane">
                  · {@dead_count} dead · replay is safe (processing is idempotent) · resolve marks handled
                </span>
              </div>

              <.error_state :if={@load_error} class="dlq-error" body={Guard.message()} retry_event="retry_load" />

              <.empty_state
                :if={@envelopes == [] and not @load_error}
                class="dlq-empty"
                icon="✓"
                title="No webhook envelopes."
                body="Failed or unprocessable webhook deliveries land here for operator replay. An empty queue means nothing has dead-lettered."
              />

              <.data_table :if={@envelopes != []}>
                <:head>
                  <th>Status</th>
                  <th>Provider</th>
                  <th>Domain</th>
                  <th>Org</th>
                  <th>Kind</th>
                  <th>Event id</th>
                  <th>Occurred</th>
                  <th>Attempts</th>
                  <th>Error</th>
                  <th>Payload (redacted)</th>
                  <th></th>
                </:head>
                <tr :for={e <- @envelopes} class="dlq-row" id={"dlq-#{e.id}"}>
                  <td class="d-status"><span class={"pill pill-#{e.status}"}>{e.status}</span></td>
                  <td class="d-provider">{e.provider}</td>
                  <td class="d-domain">{e.domain}</td>
                  <td class="d-org">
                    <a :if={e.org_id} href={"/operator/deliverability/#{e.org_id}"} class="mono" style="font-size:11px;color:#3B4CCA">
                      {short_org(e.org_id)}
                    </a>
                    <span :if={!e.org_id} style="color:var(--muted)">—</span>
                  </td>
                  <td class="d-kind">{e.kind}</td>
                  <td class="d-event-id mono">{e.event_id}</td>
                  <td class="d-occurred" style="color:var(--muted)">{ts(e.occurred_at)}</td>
                  <td class="d-attempts">{e.attempt_count}</td>
                  <td class="d-error" style="color:#B42318;max-width:260px">{e.last_error}</td>
                  <td class="d-payload">
                    <pre class="mono" style="max-width:320px;overflow:auto;white-space:pre-wrap">{payload_json(e.payload)}</pre>
                  </td>
                  <td class="d-actions">
                    <button
                      :if={e.status == "dead"}
                      class="btn-replay"
                      phx-click="replay"
                      phx-value-id={e.id}
                    >
                      Replay
                    </button>
                    <button
                      :if={e.status == "dead"}
                      class="btn-resolve"
                      phx-click="resolve"
                      phx-value-id={e.id}
                    >
                      Resolve
                    </button>
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

  # -- helpers -----------------------------------------------------------------

  defp ts(nil), do: "—"
  defp ts(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  defp ts(other), do: to_string(other)

  # T114/R5: the org column was stored but unsurfaced (`whk_event.org_id`, nilable
  # until an envelope is processed). A bounded, non-PII id fragment — never the
  # tenant's PII — cross-links to the per-tenant deliverability drill-down. Only
  # ever called from the `:if={e.org_id}` branch (a nil org_id renders the "—"
  # placeholder directly in the template instead), so there is no `nil` clause here.
  defp short_org(id), do: "#{String.slice(to_string(id), 0, 8)}…"

  # The payload is already redacted at ingress — render it verbatim as pretty JSON.
  defp payload_json(payload) when is_map(payload) do
    case Jason.encode(payload, pretty: true) do
      {:ok, json} -> json
      _ -> "{}"
    end
  end

  defp payload_json(_), do: "{}"
end
